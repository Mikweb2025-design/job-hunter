import pytest
from fastapi.testclient import TestClient

from jobhunter.db import Database
from jobhunter.web import create_app

AUTH = ("u", "p")


@pytest.fixture
def db(settings):
    return Database(settings.db_path)


def _client(settings, db):
    settings.dashboard_user, settings.dashboard_password = AUTH
    c = TestClient(create_app(settings, db=db))
    c.auth = AUTH
    return c


def test_auto_min_score_editable_and_persisted(settings, db):
    c = _client(settings, db)
    base = c.get("/api/v1/send-settings").json()
    assert base["auto_min_score_info"]["overridden"] is False
    r = c.put("/api/v1/send-settings/auto-min-score", json={"auto_min_score": 70})
    assert r.status_code == 200 and r.json()["auto_min_score"] == 70
    assert settings.send.auto_min_score == 70
    # survives a restart (new app on the same DB)
    settings.send.auto_min_score = base["auto_min_score"]
    c2 = _client(settings, db)
    assert c2.get("/api/v1/send-settings").json()["auto_min_score"] == 70
    # reset to config.yaml
    r = c2.put("/api/v1/send-settings/auto-min-score", json={"auto_min_score": None})
    assert r.json()["auto_min_score"] == base["auto_min_score"]
    assert r.json()["auto_min_score_info"]["overridden"] is False


def test_auto_min_score_validation(settings, db):
    c = _client(settings, db)
    assert c.put("/api/v1/send-settings/auto-min-score", json={"auto_min_score": 20}).status_code == 422
    assert c.put("/api/v1/send-settings/auto-min-score", json={"auto_min_score": 101}).status_code == 422


def test_web_form(settings, db):
    c = _client(settings, db)
    assert "Mindest-Score für automatischen Versand" in c.get("/outbox").text
    r = c.post("/outbox/auto-min-score", data={"auto_min_score": "75"}, follow_redirects=False,
               headers={"Origin": "http://testserver"})
    assert r.status_code == 303
    assert settings.send.auto_min_score == 75
