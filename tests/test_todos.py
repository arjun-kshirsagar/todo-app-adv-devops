import os

os.environ["DATABASE_URL"] = "sqlite:///./test.db"

import pytest
from fastapi.testclient import TestClient

from app.db import Base, engine
from app.main import app


@pytest.fixture(autouse=True)
def clean_db():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    yield


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def test_create_and_list(client):
    r = client.post("/api/todos", json={"title": "write tests"})
    assert r.status_code == 201
    assert r.json()["done"] is False
    r = client.get("/api/todos")
    assert [t["title"] for t in r.json()] == ["write tests"]


def test_update(client):
    tid = client.post("/api/todos", json={"title": "x"}).json()["id"]
    r = client.patch(f"/api/todos/{tid}", json={"done": True})
    assert r.status_code == 200
    assert r.json()["done"] is True


def test_delete(client):
    tid = client.post("/api/todos", json={"title": "x"}).json()["id"]
    assert client.delete(f"/api/todos/{tid}").status_code == 204
    assert client.get("/api/todos").json() == []


def test_not_found(client):
    assert client.patch("/api/todos/999", json={"done": True}).status_code == 404
    assert client.delete("/api/todos/999").status_code == 404


def test_validation(client):
    assert client.post("/api/todos", json={"title": ""}).status_code == 422
