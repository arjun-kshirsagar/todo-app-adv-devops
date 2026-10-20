from app import config


def test_database_url_precedence(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("DB_HOST", raising=False)
    assert config.database_url() == "sqlite:///./todos.db"

    monkeypatch.setenv("DB_HOST", "postgres")
    monkeypatch.setenv("DB_USER", "todo")
    monkeypatch.setenv("DB_PASSWORD", "p@ss/word:#")
    url = config.database_url()
    assert url.host == "postgres"
    assert url.password == "p@ss/word:#"
    # Special characters must be escaped when rendered, never leak raw.
    assert "p@ss/word" not in url.render_as_string(hide_password=True)

    monkeypatch.setenv("DATABASE_URL", "sqlite:///./x.db")
    assert config.database_url() == "sqlite:///./x.db"
