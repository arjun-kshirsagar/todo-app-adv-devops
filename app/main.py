import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Response
from fastapi.responses import FileResponse, JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy.orm import Session

from app import config, models
from app.db import engine, get_db, init_schema, ping
from app.observability import (
    DB_UP,
    TODO_OPERATIONS,
    RequestMiddleware,
    setup_logging,
    setup_tracing,
)
from app.schemas import TodoCreate, TodoOut, TodoUpdate

STATIC_DIR = Path(__file__).parent / "static"

setup_logging()
log = logging.getLogger("app")


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_schema()
    log.info("startup complete", extra={"git_sha": config.GIT_SHA})
    yield
    log.info("shutting down")


app = FastAPI(title="Todo API", version=config.APP_VERSION, lifespan=lifespan)
app.add_middleware(RequestMiddleware)
TRACING_ENABLED = setup_tracing(app, engine)


# ---------------------------------------------------------------- operational endpoints


@app.get("/healthz", include_in_schema=False)
def healthz():
    """Liveness: the process is up and serving. Deliberately does NOT check
    the database, so a database outage does not make Kubernetes restart
    every healthy app pod."""
    return {"status": "ok"}


@app.get("/readyz", include_in_schema=False)
def readyz():
    """Readiness: can this pod serve real requests right now? Requires the
    database, so pods that cannot reach it are removed from the Service."""
    try:
        ping()
    except Exception as exc:  # noqa: BLE001
        DB_UP.set(0)
        log.warning("readiness check failed", extra={"error": type(exc).__name__})
        return JSONResponse(status_code=503, content={"status": "unavailable", "database": "down"})
    DB_UP.set(1)
    return {"status": "ready", "database": "up"}


@app.get("/version")
def version():
    """Lets anyone confirm exactly which build is serving traffic."""
    return {
        "version": config.APP_VERSION,
        "git_sha": config.GIT_SHA,
        "build_date": config.BUILD_DATE,
        "tracing": TRACING_ENABLED,
    }


@app.get("/metrics", include_in_schema=False)
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


# ---------------------------------------------------------------- application


@app.get("/", include_in_schema=False)
def index():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/todos", response_model=list[TodoOut])
def list_todos(db: Session = Depends(get_db)):
    return db.query(models.Todo).order_by(models.Todo.id).all()


@app.post("/api/todos", response_model=TodoOut, status_code=201)
def create_todo(payload: TodoCreate, db: Session = Depends(get_db)):
    todo = models.Todo(title=payload.title.strip())
    db.add(todo)
    db.commit()
    db.refresh(todo)
    TODO_OPERATIONS.labels("create", "success").inc()
    return todo


@app.patch("/api/todos/{todo_id}", response_model=TodoOut)
def update_todo(todo_id: int, payload: TodoUpdate, db: Session = Depends(get_db)):
    todo = db.get(models.Todo, todo_id)
    if todo is None:
        TODO_OPERATIONS.labels("update", "not_found").inc()
        raise HTTPException(status_code=404, detail="Todo not found")
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(todo, field, value)
    db.commit()
    db.refresh(todo)
    TODO_OPERATIONS.labels("update", "success").inc()
    return todo


@app.delete("/api/todos/{todo_id}", status_code=204)
def delete_todo(todo_id: int, db: Session = Depends(get_db)):
    todo = db.get(models.Todo, todo_id)
    if todo is None:
        TODO_OPERATIONS.labels("delete", "not_found").inc()
        raise HTTPException(status_code=404, detail="Todo not found")
    db.delete(todo)
    db.commit()
    TODO_OPERATIONS.labels("delete", "success").inc()
