"""Tracker: status history, new tracker fields, /api/v1/tracker, history, bulk, follow-ups, /tracker page."""
import sqlite3
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from jobhunter import tracker
from jobhunter.config import SendConfig
from jobhunter.db import Database
from jobhunter.export import to_csv
from jobhunter.views import annotate, real_sent_ids
from jobhunter.web import create_app

from .test_opencode_views import add_job

AUTH = ("u", "p")


@pytest.fixture
def ctx(settings):
    settings.dashboard_user, settings.dashboard_password = AUTH
    settings.send = SendConfig()
    db = Database(settings.db_path)
    c = TestClient(create_app(settings, db=db))
    c.auth = AUTH
    return c, settings, db


def days_ago(n):
    return (date.today() - timedelta(days=n)).isoformat()


# ---- status history -------------------------------------------------------------------

def test_status_change_is_recorded(ctx):
    c, _, db = ctx
    j = add_job(db)  # add_job sets status neu → no change, no history
    assert db.status_history(j["id"]) == []
    r = c.patch(f"/api/v1/jobs/{j['id']}", json={"status": "interessant"})
    assert r.status_code == 200
    c.patch(f"/api/v1/jobs/{j['id']}", json={"status": "beworben"})
    c.patch(f"/api/v1/jobs/{j['id']}", json={"notes": "nur Notiz"})  # no status change → no entry
    h = db.status_history(j["id"])
    assert [(x["old_status"], x["new_status"], x["source"]) for x in h] == [
        ("neu", "interessant", "tracker"), ("interessant", "beworben", "tracker")]


def test_pipeline_style_update_is_recorded_as_system(ctx):
    _, _, db = ctx
    j = add_job(db)
    db.update_job(j["id"], status="zu_weit")
    assert db.status_history(j["id"])[-1]["source"] == "system"


def test_backfill_on_first_start(tmp_path):
    path = tmp_path / "old.db"
    db = Database(path)
    a = add_job(db, title="A", company="X")
    b = add_job(db, title="B", company="Y")
    db.update_job(b["id"], status="gespraech", applied_date=days_ago(10), status_updated_at=days_ago(2) + "T09:00:00+00:00")
    con = sqlite3.connect(path)
    con.execute("DROP TABLE job_status_history")  # simulate a database from before the table existed
    con.commit(); con.close()
    db2 = Database(path)
    hist = db2.status_history()
    assert [h["job_id"] for h in hist if h["job_id"] == a["id"]] == []  # still "neu": nothing to backfill
    hb = [h for h in hist if h["job_id"] == b["id"]]
    assert [(h["old_status"], h["new_status"], h["source"]) for h in hb] == [
        (None, "beworben", "backfill"), ("beworben", "gespraech", "backfill")]
    # second start: no duplicates
    assert len(Database(path).status_history()) == len(hist)


# ---- PATCH: interview / follow-up / close reason ----------------------------------------

def test_patch_tracker_fields_and_validation(ctx):
    c, _, db = ctx
    j = add_job(db)
    r = c.patch(f"/api/v1/jobs/{j['id']}", json={"status": "gespraech", "interview_at": "2026-10-20T10:30",
                                                "follow_up_at": "2026-10-25"})
    assert r.status_code == 200
    body = r.json()
    assert body["interview_at"] == "2026-10-20T10:30" and body["follow_up_at"] == "2026-10-25"
    assert body["status"] == "gespraech" and "notes" in body
    for bad in ({"interview_at": "morgen"}, {"interview_at": "2026-10-20"}, {"follow_up_at": "25.10.2026"},
                {"close_reason": "weil"}, {"unknown": 1}):
        assert c.patch(f"/api/v1/jobs/{j['id']}", json=bad).status_code == 422, bad
    # clear
    r = c.patch(f"/api/v1/jobs/{j['id']}", json={"interview_at": None, "follow_up_at": None})
    assert r.json()["interview_at"] is None and r.json()["follow_up_at"] is None
    # close reason only stays with absage
    r = c.patch(f"/api/v1/jobs/{j['id']}", json={"status": "absage", "close_reason": "duplikat"})
    assert r.json()["close_reason"] == "duplikat"
    r = c.patch(f"/api/v1/jobs/{j['id']}", json={"status": "interessant"})
    assert r.json()["close_reason"] is None


def test_list_items_carry_tracker_fields(ctx):
    c, _, db = ctx
    j = add_job(db)
    db.update_job(j["id"], notes="Ansprechpartnerin Frau X", interview_at="2026-11-02T09:00")
    item = next(i for i in c.get("/api/v1/jobs").json()["items"] if i["id"] == j["id"])
    assert item["notes"] == "Ansprechpartnerin Frau X" and item["interview_at"] == "2026-11-02T09:00"
    assert "follow_up_at" in item and "close_reason" in item


# ---- history API -------------------------------------------------------------------------

def test_history_endpoint(ctx):
    c, settings, db = ctx
    j = add_job(db)
    c.patch(f"/api/v1/jobs/{j['id']}", json={"status": "interessant"})
    db.add_sent(db.get_job(j["id"]), "jobs@acme.de", "Bewerbung", "Text", "2030-01-01T10:00:00+00:00",
                dry_run=False, message_id=None, trigger="manual")
    ev = c.get(f"/api/v1/jobs/{j['id']}/history").json()["events"]
    kinds = [e["kind"] for e in ev]
    assert kinds[0] == "found" and "status" in kinds and kinds[-1] == "sent"
    st = next(e for e in ev if e["kind"] == "status")
    assert st["from"] == "neu" and st["to"] == "interessant" and st["label"] == "Neu → Interessant"
    assert c.get("/api/v1/jobs/99999/history").status_code == 404


# ---- tracker payload ------------------------------------------------------------------------

def _build(db, today=None):
    jobs = annotate(db.list_jobs(limit=10000), real_sent_ids(db), [])
    return tracker.build(db, jobs, "Daniele Michelin", today=today)


def test_tracker_columns_kpis_followups_interviews(ctx):
    _, _, db = ctx
    today = date.today()
    new = add_job(db, title="Neu A", company="A")
    far = add_job(db, title="Weit", company="W", status="zu_weit")
    waiting = add_job(db, title="Wartet", company="B")
    db.update_job(waiting["id"], status="beworben", applied_date=days_ago(20))
    fresh = add_job(db, title="Frisch", company="C")
    db.update_job(fresh["id"], status="beworben", applied_date=days_ago(2))
    talk = add_job(db, title="Gespräch", company="D")
    db.update_job(talk["id"], status="beworben", applied_date=days_ago(10),
                  status_updated_at=days_ago(10) + "T10:00:00+00:00")
    db.update_job(talk["id"], status="gespraech", status_updated_at=days_ago(4) + "T10:00:00+00:00",
                  interview_at=(today + timedelta(days=3)).isoformat() + "T10:00")
    no = add_job(db, title="Absage", company="E")
    db.update_job(no["id"], status="absage", applied_date=days_ago(8), status_updated_at=days_ago(2) + "T08:00:00+00:00")
    dup = add_job(db, title="Dublette", company="F")
    db.update_job(dup["id"], status="absage", close_reason="duplikat")
    mail = add_job(db, title="Per Mail", company="G")
    db.add_sent(db.get_job(mail["id"]), "jobs@g.de", "Bewerbung", "Text", today.isoformat() + "T08:00:00+00:00",
                dry_run=False, message_id=None, trigger="auto")
    db.update_job(mail["id"], status="beworben", applied_date=today.isoformat())

    t = _build(db)
    cols = {c["status"]: c for c in t["columns"]}
    assert list(cols) == ["neu", "interessant", "beworben", "gespraech", "angebot", "absage", "zu_weit"]
    assert cols["neu"]["count"] == 1 and cols["zu_weit"]["count"] == 1 and cols["absage"]["count"] == 2
    assert cols["beworben"]["count"] == 3 and cols["angebot"]["count"] == 0
    k = t["kpis"]
    assert k["applied"] == 5  # waiting, fresh, talk, absage(applied), mail – not the duplicate
    assert k["by_channel"] == {"email": 1, "manual": 4}
    assert k["responses"] == 2 and k["response_rate"] == 40
    assert k["interviews"] == 1 and k["offers"] == 0 and k["waiting"] == 3
    assert k["avg_days_to_answer"] == 6.0  # talk: 10-4 = 6, absage: 8-2 = 6
    assert [f["id"] for f in t["follow_ups"]] == [waiting["id"]]
    draft = t["follow_ups"][0]["draft"]
    assert draft["subject"] == "Nachfrage zu meiner Bewerbung als Wartet"
    assert "Daniele Michelin" in draft["body"] and "beworben" in draft["body"]
    assert [i["id"] for i in t["interviews"]] == [talk["id"]]
    mail_card = next(c for c in cols["beworben"]["cards"] if c["id"] == mail["id"])
    assert mail_card["channel"]["kind"] == "email" and mail_card["channel"]["label"].startswith("✉ E-Mail gesendet am")
    wait_card = next(c for c in cols["beworben"]["cards"] if c["id"] == waiting["id"])
    assert wait_card["follow_up_due"] and wait_card["next_step"].startswith("Nachfassen") and wait_card["days_since_applied"] == 20
    assert wait_card["channel"]["kind"] == "manual"
    assert sum(w["applications"] for w in t["weekly"]) >= 4 and len(t["weekly"]) == 12
    assert t["by_source"][0]["applications"] == 5
    assert next(c for c in cols["absage"]["cards"] if c["id"] == dup["id"])["close_reason_label"] == "Duplikat"
    assert t["funnel"][0]["value"] == 8 and new["id"] and far["id"]


def test_follow_up_date_overrides_14_days(ctx):
    _, _, db = ctx
    j = add_job(db)
    db.update_job(j["id"], status="beworben", applied_date=days_ago(30), follow_up_at=(date.today() + timedelta(days=3)).isoformat())
    assert _build(db)["follow_ups"] == []
    db.update_job(j["id"], follow_up_at=days_ago(0))
    assert len(_build(db)["follow_ups"]) == 1


def test_tracker_api(ctx):
    c, _, db = ctx
    add_job(db, title="Eins")
    r = c.get("/api/v1/tracker")
    assert r.status_code == 200
    body = r.json()
    for key in ("columns", "kpis", "funnel", "weekly", "by_source", "follow_ups", "interviews", "labels"):
        assert key in body
    assert body["labels"]["zu_weit"] == "Zu weit"
    assert c.get("/api/v1/tracker?q=gibtsnicht").json()["columns"][0]["count"] == 0


# ---- bulk ---------------------------------------------------------------------------------

def test_bulk_status_duplicate_and_validation(ctx):
    c, _, db = ctx
    a, b = add_job(db, title="A", company="A"), add_job(db, title="B", company="B")
    r = c.post("/api/v1/jobs/bulk", json={"ids": [a["id"], b["id"], 999], "status": "zu_weit"})
    assert r.status_code == 200 and r.json()["updated"] == 2 and r.json()["missing"] == 1
    assert db.get_job(a["id"])["status"] == "zu_weit"
    assert db.status_history(a["id"])[-1]["source"] == "bulk"
    r = c.post("/api/v1/jobs/bulk", json={"ids": [a["id"]], "status": "absage", "close_reason": "duplikat"})
    assert db.get_job(a["id"])["close_reason"] == "duplikat"
    assert c.post("/api/v1/jobs/bulk", json={"ids": [a["id"]]}).status_code == 422
    assert c.post("/api/v1/jobs/bulk", json={"ids": [a["id"]], "status": "weg"}).status_code == 422
    assert c.post("/api/v1/jobs/bulk", json={"ids": [], "status": "neu"}).status_code == 422
    # KI letters without LLM: nothing starts, hint explains
    r = c.post("/api/v1/jobs/bulk", json={"ids": [b["id"]], "write_letters": True})
    assert r.json()["letters_started"] is False and "KI" in r.json()["hint"]
    # form-encoded / cross-origin writes are refused
    assert c.post("/api/v1/jobs/bulk", data={"ids": "1"}).status_code == 415
    assert c.post("/api/v1/jobs/bulk", json={"ids": [a["id"]], "status": "neu"},
                  headers={"Origin": "https://evil.example"}).status_code == 403


# ---- dashboard -------------------------------------------------------------------------------

def test_tracker_page_and_followup_actions(ctx):
    c, _, db = ctx
    j = add_job(db, title="Nachfass-Job")
    db.update_job(j["id"], status="beworben", applied_date=days_ago(15))
    add_job(db, title="Weit weg", company="Z", status="zu_weit")
    html = c.get("/tracker").text
    for label in ("Neu", "Interessant", "Beworben", "Gespräch", "Angebot", "Absage", "Zu weit"):
        assert f"<span>{label}</span>" in html
    assert "Nachfass-Job" in html and "mailto:" in html and "Entwurf öffnen" in html
    r = c.post(f"/jobs/{j['id']}/follow-up", data={"action": "done"}, follow_redirects=False)
    assert r.status_code == 303 and "/tracker" in r.headers["location"]
    job = db.get_job(j["id"])
    assert "Nachgefasst am" in job["notes"] and job["follow_up_at"] == (date.today() + timedelta(days=14)).isoformat()
    c.post(f"/jobs/{j['id']}/follow-up", data={"action": "snooze", "days": "7"})
    assert db.get_job(j["id"])["follow_up_at"] == (date.today() + timedelta(days=7)).isoformat()


def test_detail_page_tracker_form_and_timeline(ctx):
    c, _, db = ctx
    j = add_job(db)
    r = c.post(f"/jobs/{j['id']}/status", data={"status": "gespraech", "interview_at": "2026-11-05T14:00",
                                               "follow_up_at": "", "notes": "Teams-Call"}, follow_redirects=False)
    assert r.status_code == 303 and "#tracker" in r.headers["location"]
    job = db.get_job(j["id"])
    assert job["interview_at"] == "2026-11-05T14:00" and job["notes"] == "Teams-Call"
    html = c.get(f"/jobs/{j['id']}").text
    assert "Verlauf" in html and "Neu → Gespräch" in html and "05.11.2026 14:00" in html
    assert 'id="status-select"' in html and "Nächster Schritt" in html
    r = c.post(f"/jobs/{j['id']}/status", data={"status": "neu", "interview_at": "quatsch"}, follow_redirects=False)
    assert "err=" in r.headers["location"]


def test_recent_view_and_nav(ctx):
    c, _, db = ctx
    add_job(db, title="Ganz neu")
    html = c.get("/?view=recent").text
    assert "Neu – letzte 3 Tage" in html and "Ganz neu" in html
    assert 'class="bulk-cb"' in html and 'class="quick-status"' in html


def test_export_has_status_labels_and_channel(ctx):
    _, _, db = ctx
    j = add_job(db)
    db.update_job(j["id"], status="zu_weit")
    job = db.get_job(j["id"])
    job["channel_label"] = None
    out = to_csv([job])
    header = out.splitlines()[0]
    assert "Kanal" in header and "Gespräch am" in header and "Abschlussgrund" in header
    assert ";Zu weit;" in out


def test_relative_day():
    today = date(2026, 10, 8)
    assert tracker.relative_day("2026-10-08T05:00:00+00:00", today) == "heute"
    assert tracker.relative_day("2026-10-07", today) == "gestern"
    assert tracker.relative_day("2026-10-05", today) == "vor 3 Tagen"
    assert tracker.relative_day("2026-09-17", today) == "vor 3 Wochen"
    assert tracker.relative_day("2026-10-10", today) == "in 2 Tagen"
    assert tracker.relative_day(None, today) == ""
