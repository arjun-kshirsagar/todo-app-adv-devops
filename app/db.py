import logging
import time

from sqlalchemy import create_engine, text
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.config import database_url

log = logging.getLogger("app.db")

DATABASE_URL = database_url()
IS_SQLITE = str(DATABASE_URL).startswith("sqlite")

if IS_SQLITE:
    engine = create_engine(DATABASE_URL, connect_args={"check_same_thread": False})
else:
    engine = create_engine(
        DATABASE_URL,
        # Fail fast instead of hanging requests when the database is unreachable.
        connect_args={"connect_timeout": 3},
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=5,
        pool_timeout=5,
    )
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)

# Arbitrary constant used as a Postgres advisory-lock key so that only one
# replica creates the schema when several pods start at the same time.
SCHEMA_LOCK_KEY = 8152026


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def ping() -> None:
    """Raise if the database is unreachable. Used by the readiness probe."""
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))


def init_schema(attempts: int = 30, delay: float = 2.0) -> None:
    """Create tables, retrying while the database comes up.

    Retrying here (instead of crashing) avoids CrashLoopBackOff during the
    window where Postgres is still starting after a fresh install.
    """
    from app import models  # noqa: F401  (registers tables on Base.metadata)

    for attempt in range(1, attempts + 1):
        try:
            with engine.begin() as conn:
                if not IS_SQLITE:
                    conn.execute(text("SELECT pg_advisory_xact_lock(:k)"), {"k": SCHEMA_LOCK_KEY})
                Base.metadata.create_all(bind=conn)
            log.info("database schema ready", extra={"attempt": attempt})
            return
        except Exception as exc:  # noqa: BLE001 - any connection error is retryable here
            log.warning(
                "database not ready, retrying",
                extra={"attempt": attempt, "error": type(exc).__name__},
            )
            if attempt == attempts:
                raise
            time.sleep(delay)
