# Todo App

A small todo list: FastAPI backend, PostgreSQL (SQLite fallback for local dev), and a single-page HTML frontend.

## Run locally

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
uvicorn app.main:app --reload
```

Open http://localhost:8000. API docs are at http://localhost:8000/docs.

To use Postgres instead of SQLite:

```bash
export DATABASE_URL="postgresql+psycopg://user:password@localhost:5432/todos"
```

## Tests

```bash
pytest -q
```

## API

| Method | Path | Description |
|---|---|---|
| GET | `/api/todos` | List todos |
| POST | `/api/todos` | Create `{ "title": "..." }` |
| PATCH | `/api/todos/{id}` | Update `{ "title"?: "...", "done"?: true }` |
| DELETE | `/api/todos/{id}` | Delete |
