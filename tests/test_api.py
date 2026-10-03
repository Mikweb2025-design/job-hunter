from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from jobhunter import pipeline
from jobhunter.db import Database
from jobhunter.llm import LLMError
from jobhunter.pipeline import run_cycle
from jobhunter.web import create_app

from .test_pipeline_web import _sources

AUTH = ("api-user", "api-pass")


@pytest.fixture
def ctx(settings):
    settings.dashboard_user, settings.dashboard_password = AUTH
    settings.llm.threshold = 0
    db = Database(settings.db_path)
    run_cycle(settings, db=db, sources=_sources()[:2], notify=False)
    client = TestClient(create_app(settings, db=db))
    client.auth = AUTH
    return client, db, settings


def test_api_requires_basic_auth(ctx):
    client, _, _ = ctx
    anon = TestClient(client.app)
    for path in ("/api/v1/health", "/api/v1/jobs", "/api/v1/stats", "/api/v1/jobs/1"):
        assert anon.get(path).status_code == 401
    assert anon.get("/api/v1/jobs", auth=("api-user", "nope")).status_code == 401
    assert anon.post("/api/v1/run", json={}).status_code == 401
    assert anon.patch("/api/v1/jobs/1", json={"status": "absage"}).status_code == 401


def test_health(ctx):
    client, _, _ = ctx
    r = client.get("/api/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True and body["api_version"] == 1 and body["running"] is False
    assert body["llm_enabled"] is False


def test_list_jobs_sorted_and_shape(ctx):
    client, db, _ = ctx
    r = client.get("/api/v1/jobs")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] == len(body["items"]) == 5
    scores = [j["score"] for j in body["items"]]
    assert scores == sorted(scores, reverse=True)
    item = body["items"][0]
    for key in ("id", "title", "company", "location", "url", "source", "score", "status",
                "remote", "also_seen_on", "fetched_at", "has_letter"):
        assert key in item
    assert isinstance(item["remote"], bool) and isinstance(item["also_seen_on"], list)
    assert "description" not in item and "letter" not in item  # list stays light


def test_list_jobs_filters(ctx):
    client, db, _ = ctx
    top = db.list_jobs()[0]
    assert all(j["score"] >= 50 for j in client.get("/api/v1/jobs?min_score=50").json()["items"])
    adz = client.get("/api/v1/jobs?source=adzuna").json()["items"]
    # Virtimo was first seen on BA but also on Adzuna -> included via also_seen_on
    assert adz and all(j["source"] == "adzuna" or "adzuna" in j["also_seen_on"] for j in adz)
    client.patch(f"/api/v1/jobs/{top['id']}", json={"status": "interessant"})
    st = client.get("/api/v1/jobs?status=interessant").json()
    assert st["count"] == 1 and st["items"][0]["id"] == top["id"]
    assert client.get("/api/v1/jobs?status=bogus").status_code == 422
    assert client.get("/api/v1/jobs?since=1").json()["count"] == 5
    future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    assert client.get("/api/v1/jobs", params={"since": future}).json()["count"] == 0
    past = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert client.get("/api/v1/jobs", params={"since": past}).json()["count"] == 5
    assert client.get("/api/v1/jobs?since=yesterday").status_code == 422


def test_job_detail(ctx):
    client, db, _ = ctx
    job = db.list_jobs()[0]
    r = client.get(f"/api/v1/jobs/{job['id']}")
    assert r.status_code == 200
    d = r.json()
    assert d["title"] == job["title"] and d["url"] == job["url"]
    assert d["description"] and d["letter"]
    bd = d["score_breakdown"]
    for key in ("keywords", "matched", "title", "location", "salary", "penalty", "excluded"):
        assert key in bd
    assert "reason" in d and "notes" in d
    assert client.get("/api/v1/jobs/999999").status_code == 404


def test_update_status_notes_applied_date(ctx):
    client, db, _ = ctx
    jid = db.list_jobs()[0]["id"]
    r = client.patch(f"/api/v1/jobs/{jid}", json={"status": "beworben", "notes": "Portal"})
    assert r.status_code == 200
    d = r.json()
    assert d["status"] == "beworben" and d["notes"] == "Portal" and d["applied_date"]
    # partial update keeps the other fields
    r = client.patch(f"/api/v1/jobs/{jid}", json={"applied_date": "2026-09-30"})
    d = r.json()
    assert d["status"] == "beworben" and d["notes"] == "Portal" and d["applied_date"] == "2026-09-30"
    r = client.patch(f"/api/v1/jobs/{jid}", json={"status": "gespraech", "notes": ""})
    assert r.json()["notes"] == "" and r.json()["applied_date"] == "2026-09-30"
    assert client.patch(f"/api/v1/jobs/{jid}", json={"status": "hacked"}).status_code == 422
    assert client.patch(f"/api/v1/jobs/{jid}", json={"applied_date": "30.09.2026"}).status_code == 422
    assert client.patch(f"/api/v1/jobs/{jid}", json={"unknown": 1}).status_code == 422
    assert client.patch("/api/v1/jobs/999999", json={"status": "neu"}).status_code == 404
    assert db.get_job(jid)["status"] == "gespraech"


def test_writes_require_json_content_type(ctx):
    client, db, _ = ctx
    jid = db.list_jobs()[0]["id"]
    r = client.patch(f"/api/v1/jobs/{jid}", content="status=absage",
                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    assert r.status_code == 415
    r = client.post("/api/v1/run", headers={"Content-Type": "text/plain"}, content="x")
    assert r.status_code == 415
    r = client.patch(f"/api/v1/jobs/{jid}", json={"status": "absage"},
                     headers={"Origin": "https://evil.example"})
    assert r.status_code == 403
    assert db.get_job(jid)["status"] == "neu"


def test_update_letter_and_regenerate(ctx):
    client, db, _ = ctx
    jid = db.list_jobs()[0]["id"]
    r = client.put(f"/api/v1/jobs/{jid}/letter", json={"letter": "Sehr geehrte Damen und Herren, ..."})
    assert r.status_code == 200
    assert r.json()["letter"].startswith("Sehr geehrte") and r.json()["letter_origin"] == "manuell"
    assert client.put(f"/api/v1/jobs/{jid}/letter", json={}).status_code == 422
    r = client.post(f"/api/v1/jobs/{jid}/regenerate", json={})
    assert r.status_code == 200 and r.json()["letter_origin"] == "vorlage"
    assert not r.json()["letter"].startswith("Sehr geehrte")
    assert client.post("/api/v1/jobs/999999/regenerate", json={}).status_code == 404


def test_regenerate_llm_error_is_502(ctx, monkeypatch):
    client, db, _ = ctx
    jid = db.list_jobs()[0]["id"]

    def boom(settings, db, job):
        raise LLMError("timeout")

    monkeypatch.setattr("jobhunter.actions.regenerate_letter", boom)
    r = client.post(f"/api/v1/jobs/{jid}/regenerate", json={})
    assert r.status_code == 502 and "timeout" in r.json()["detail"]


def test_trigger_run(ctx, monkeypatch):
    client, _, _ = ctx
    calls = []
    monkeypatch.setattr("jobhunter.actions.start_run", lambda s: calls.append(s) or True)
    r = client.post("/api/v1/run", json={})
    assert r.status_code == 202 and r.json()["started"] is True and len(calls) == 1
    monkeypatch.setattr("jobhunter.actions.start_run", lambda s: False)
    assert client.post("/api/v1/run", json={}).json()["started"] is False


def test_stats(ctx):
    client, db, settings = ctx
    jid = db.list_jobs()[0]["id"]
    client.patch(f"/api/v1/jobs/{jid}", json={"status": "beworben"})
    s = client.get("/api/v1/stats").json()
    assert s["total"] == 5
    assert s["by_status"]["beworben"] == 1 and s["by_status"]["neu"] == 4
    assert set(s["by_status"]) == set(pipeline_statuses())
    assert s["new_since_last_run"] == 5 and s["last_run"]["new_jobs"] == 5
    assert sorted(s["sources"]) == ["adzuna", "arbeitsagentur"]
    assert s["running"] is False
    s0 = client.get("/api/v1/stats?min_score=0").json()
    assert s0["new_since_last_run_above_threshold"] == 5 and s0["threshold"] == 0
    s100 = client.get("/api/v1/stats?min_score=100").json()
    assert s100["new_since_last_run_above_threshold"] <= 5
    # a second run without new postings resets "new since last run"
    run_cycle(settings, db=db, sources=_sources()[:2], notify=False)
    assert client.get("/api/v1/stats").json()["new_since_last_run"] == 0


def test_statuses_labels(ctx):
    client, _, _ = ctx
    body = client.get("/api/v1/statuses").json()
    assert [s["id"] for s in body] == pipeline_statuses()
    assert {"id": "gespraech", "label": "Gespräch"} in body


def pipeline_statuses():
    from jobhunter.models import STATUSES
    return list(STATUSES)


def test_server_never_sends_mail_itself(ctx):
    # The server only decides and logs; sending is done by the macOS app via Apple Mail.
    from pathlib import Path
    import jobhunter
    src = "\n".join(p.read_text(encoding="utf-8") for p in Path(jobhunter.__file__).parent.rglob("*.py"))
    for forbidden in ("smtplib", "osascript", "sendmail", "NSAppleScript"):
        assert forbidden not in src
    assert pipeline.is_running() is False
