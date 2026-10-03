"""E-mail applications: address extraction, gating rules, API and dashboard."""
from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from jobhunter import actions
from jobhunter.apply_email import apply_fields, find_apply_email
from jobhunter.config import SendConfig, load_settings
from jobhunter.db import Database
from jobhunter.models import JobPosting
from jobhunter.outbox import Gate, clean_title, has_placeholder, is_blocked_company, render_email, status_summary
from jobhunter.web import create_app

LETTER = ("Ich betreue seit Jahren Kunden einer großen Hosting-Plattform. Ihre Anzeige nennt Linux und Python. "
          "In den ersten 90 Tagen würde ich die Tickets auswerten. Ich freue mich auf ein Gespräch.")
NOW = datetime(2026, 10, 3, 10, 0, tzinfo=timezone.utc)


# ---- extraction --------------------------------------------------------------

@pytest.mark.parametrize("text, expected", [
    ("Dann sende uns deinen Lebenslauf an:\n\npersonal@digatus.com\n\nWir freuen uns", "personal@digatus.com"),
    ("Bitte senden Sie Ihre Bewerbung per E-Mail an bewerbung@firma.de.", "bewerbung@firma.de"),
    ("Ihre Bewerbungsunterlagen an [karriere@beispiel.de](mailto:karriere@beispiel.de)", "karriere@beispiel.de"),
    ("Send your CV to talent@startup.io and we will get back to you.", "talent@startup.io"),
    ("Kontakt\nPuro GmbH\nTel. 0172 123\njobs@puro-personal.de\nwww.puro.de", "jobs@puro-personal.de"),
    ("Haben wir Ihr Interesse geweckt? Dann freuen wir uns auf Ihre aussagekräftige Bewerbung.\n\n"
     "Firma GmbH\nFrau Muster\n[m.muster@firma.de](mailto:m.muster@firma.de)", "m.muster@firma.de"),
    ("Bewerbung an: MAILTO:Jobs@Example.ORG", "jobs@example.org"),
])
def test_extracts_application_address(text, expected):
    assert find_apply_email(text).email == expected


@pytest.mark.parametrize("text", [
    "Bei Fragen zum Datenschutz: datenschutz@firma.de",
    "Bitte nicht antworten: noreply@firma.de. Bewerbung über unser Portal.",
    "just let us know with an email to our Inclusion Officer at inclusion@deliveryhero.com.",
    "HOW TO REACH US\n * Viktoria Pohl (Talent Acquisition), viktoria.pohl@basf.com, Tel: +49 30",
    "Solltest du Fragen oder Probleme haben, kannst du dich per E-Mail (bewerbung@contipark.de) an uns wenden.",
    "Bitte bewerben Sie sich ausschließlich über unser Online-Portal. Fragen: jobs@firma.de",
    "Keine Adresse hier, nur ein Link: https://firma.de/jobs",
    "",
    None,
])
def test_ignores_non_application_addresses(text):
    assert find_apply_email(text) is None


def test_apply_fields():
    assert apply_fields("Bewerbung an jobs@x.de") == {"apply_email": "jobs@x.de", "apply_method": "email",
                                                     "apply_email_source": "phrase"}
    assert apply_fields("nichts") == {"apply_email": None, "apply_method": "manual", "apply_email_source": None}


# ---- fixtures ------------------------------------------------------------------

@pytest.fixture
def env(settings):
    settings.send = SendConfig(mode="auto", dry_run=False)
    db = Database(settings.db_path)
    return settings, db


def add_job(db, title="Support Engineer (m/w/d)", company="Acme GmbH", email="jobs@acme.de", score=85,
            letter=LETTER, origin="anthropic", status="neu", **extra):
    desc = f"Bewerbung an {email}" if email else "Bewerbung über das Portal."
    jid = db.insert_job(JobPosting(source="test", source_id=title + company, title=title, company=company,
                                   description=desc), score, {})
    db.update_job(jid, score=score, letter=letter, letter_origin=origin, status=status, **extra)
    return db.get_job(jid)


def gate(settings, db, now=NOW):
    return Gate(settings, db, now=now)


def blockers(settings, db, job, now=NOW):
    return gate(settings, db, now).evaluate(db.get_job(job["id"])).blockers


def auto_blockers(settings, db, job, now=NOW):
    return gate(settings, db, now).evaluate(db.get_job(job["id"])).auto_blockers


def log_send(db, job, when=NOW, dry_run=False):
    db.add_sent(job, job["apply_email"], "s", "b", when.isoformat(), dry_run, None, "auto")


# ---- gating rules --------------------------------------------------------------

def test_insert_detects_address(env):
    _, db = env
    j = add_job(db)
    assert j["apply_email"] == "jobs@acme.de" and j["apply_method"] == "email"
    assert add_job(db, title="Other", email=None)["apply_method"] == "manual"


def test_eligible_job_is_in_outbox(env):
    settings, db = env
    j = add_job(db)
    items = gate(settings, db).outbox()
    assert [i["job_id"] for i in items] == [j["id"]]
    assert items[0]["reason"] == "auto"
    assert items[0]["email"]["to"] == "jobs@acme.de"
    assert items[0]["email"]["subject"] == "Bewerbung als Support Engineer"


def test_kill_switch_blocks_everything(env):
    settings, db = env
    j = add_job(db)
    db.update_job(j["id"], send_approved_at=NOW.isoformat())
    settings.send.kill_switch = True
    assert "kill_switch" in blockers(settings, db, j)
    assert gate(settings, db).outbox() == []


def test_mode_off_blocks_everything(env):
    settings, db = env
    j = add_job(db)
    settings.send.mode = "off"
    assert "mode_off" in blockers(settings, db, j)
    assert gate(settings, db).outbox() == []


def test_approve_mode_needs_approval(env):
    settings, db = env
    settings.send.mode = "approve"
    j = add_job(db)
    assert gate(settings, db).outbox() == []
    assert "not_approved" in auto_blockers(settings, db, j)
    actions.approve(settings, db, j)
    items = gate(settings, db).outbox()
    assert [i["reason"] for i in items] == ["approved"]


def test_dedup_never_twice_per_job(env):
    settings, db = env
    j = add_job(db)
    log_send(db, j, NOW - timedelta(days=200))
    assert "already_sent" in blockers(settings, db, j)
    assert gate(settings, db).outbox() == []


def test_dry_run_sends_do_not_count(env):
    settings, db = env
    j = add_job(db)
    for _ in range(10):
        log_send(db, j, dry_run=True)
    g = gate(settings, db)
    assert g.evaluate(db.get_job(j["id"])).blockers == []
    c = g.counters()
    assert c.sent_today == 0 and c.dry_run_total == 10 and c.remaining_today == 5


def test_company_cooldown_from_sent_log(env):
    settings, db = env
    a = add_job(db, title="Support Engineer", company="Acme GmbH")
    b = add_job(db, title="Cloud Engineer", company="ACME AG", email="karriere@acme.de")
    log_send(db, a, NOW - timedelta(days=89))
    assert "cooldown" in blockers(settings, db, b)
    assert "cooldown" not in blockers(settings, db, b, now=NOW + timedelta(days=2))


def test_company_cooldown_from_manual_application(env):
    settings, db = env
    add_job(db, title="Old", company="Acme", status="beworben",
            applied_date=(NOW.date() - timedelta(days=30)).isoformat())
    b = add_job(db, title="New", company="Acme GmbH")
    assert "cooldown" in blockers(settings, db, b)


def test_outbox_one_per_company(env):
    settings, db = env
    add_job(db, title="A", company="Acme", score=90)
    add_job(db, title="B", company="Acme GmbH", score=88, email="karriere@acme.de")
    assert len(gate(settings, db).outbox()) == 1


def test_daily_cap_counts_real_sends_today_only(env):
    settings, db = env
    settings.send.daily_cap = 2
    for i in range(2):
        other = add_job(db, title=f"Old {i}", company=f"Old{i}")
        log_send(db, other, NOW - timedelta(days=1))  # yesterday: does not count
    jobs = [add_job(db, title=f"T{i}", company=f"C{i}", score=90 - i) for i in range(4)]
    assert len(gate(settings, db).outbox()) == 2  # cap limits the outbox
    log_send(db, jobs[0])
    log_send(db, jobs[1])
    g = gate(settings, db)
    assert g.counters().sent_today == 2 and g.counters().remaining_today == 0
    assert "daily_cap" in g.evaluate(db.get_job(jobs[2]["id"])).blockers
    assert g.outbox() == []
    # next day (Berlin time) the budget is back
    assert len(gate(settings, db, NOW + timedelta(days=1)).outbox()) == 2


def test_daily_cap_uses_berlin_day(env):
    settings, db = env
    settings.send.daily_cap = 1
    j = add_job(db, title="X", company="X")
    # 23:30 UTC on Oct 2 = 01:30 Oct 3 in Berlin -> counts for "today" at NOW
    log_send(db, j, datetime(2026, 10, 2, 23, 30, tzinfo=timezone.utc))
    assert gate(settings, db).counters().sent_today == 1


@pytest.mark.parametrize("company", ["IONOS SE", "Strato AG", "1&1 Telecom GmbH", "United Internet AG", "ionos"])
def test_blocklist(env, company):
    settings, db = env
    j = add_job(db, company=company)
    assert "blocklist" in blockers(settings, db, j)


def test_blocklist_matches_recipient_domain():
    assert is_blocked_company("Personalberatung XY", "jobs@ionos.de", ["IONOS"])
    assert not is_blocked_company("Acme", "jobs@acme.de", ["IONOS", "STRATO", "1&1"])


def test_min_score_for_auto(env):
    settings, db = env
    j = add_job(db, score=79)
    assert "score" in auto_blockers(settings, db, j)
    assert blockers(settings, db, j) == []  # still sendable after an explicit approval
    assert gate(settings, db).outbox() == []
    actions.approve(settings, db, j)
    assert [i["reason"] for i in gate(settings, db).outbox()] == ["approved"]


def test_template_letter_never_sent_even_if_approved(env):
    settings, db = env
    j = add_job(db, origin="vorlage", letter=LETTER)
    assert "template_letter" in blockers(settings, db, j)  # hard blocker: only KI/manual letters are e-mailed
    import pytest
    with pytest.raises(actions.SendBlocked):
        actions.approve(settings, db, j)
    assert gate(settings, db).outbox() == []


def test_ki_letter_is_sendable(env):
    settings, db = env
    j = add_job(db, origin="KI (opencode)", letter=LETTER)
    assert "template_letter" not in blockers(settings, db, j)


def test_placeholder_never_sent(env):
    settings, db = env
    j = add_job(db, letter=LETTER + " [konkreten Bezug zur Anzeige ergänzen]", origin="manuell")
    assert "placeholder" in blockers(settings, db, j)
    with pytest.raises(actions.SendBlocked):
        actions.approve(settings, db, j)


def test_require_letter(env):
    settings, db = env
    j = add_job(db, letter=None, origin=None)
    assert "no_letter" in blockers(settings, db, j)


def test_no_email_and_status(env):
    settings, db = env
    assert "no_email" in blockers(settings, db, add_job(db, title="A", email=None))
    assert "status" in blockers(settings, db, add_job(db, title="B", company="B", status="absage"))


def test_placeholder_detection():
    assert has_placeholder("weil [konkreter Bezug].")
    assert not has_placeholder("Ein ganz normaler Brief.")


def test_render_email():
    cfg = SendConfig()
    e = render_email({"title": "Cloud Support Engineer (m/w/d)", "company": "Acme", "apply_email": "j@a.de",
                      "letter": LETTER}, cfg)
    assert e["subject"] == "Bewerbung als Cloud Support Engineer"
    assert e["body"].startswith("Sehr geehrte Damen und Herren,\n\n" + LETTER)
    assert "Mit freundlichen Grüßen\nDaniele Michelin" in e["body"]
    assert e["sender"] == "Daniele Michelin <info@daniele-michelin.com>"
    own = render_email({"title": "X", "apply_email": "j@a.de",
                        "letter": "Sehr geehrte Frau Muster,\n\nText.\n\nViele Grüße\nD."}, cfg)
    assert own["body"].count("Sehr geehrte") == 1 and "Mit freundlichen" not in own["body"]
    assert clean_title("Support Engineer (w/m/d) - Berlin") == "Support Engineer - Berlin"


def test_record_real_send_marks_applied(env):
    settings, db = env
    j = add_job(db)
    actions.approve(settings, db, j)
    rec = actions.record_sent(settings, db, db.get_job(j["id"]), dry_run=False,
                              sent_at="2026-10-02T23:30:00Z", message_id="<abc@mail>")
    job = db.get_job(j["id"])
    assert job["status"] == "beworben" and job["applied_date"] == "2026-10-03"  # Berlin day
    assert job["send_approved_at"] is None
    assert rec["to_addr"] == "jobs@acme.de" and rec["message_id"] == "<abc@mail>" and not rec["dry_run"]


def test_record_dry_run_changes_nothing(env):
    settings, db = env
    j = add_job(db)
    actions.record_sent(settings, db, j, dry_run=True)
    job = db.get_job(j["id"])
    assert job["status"] == "neu" and job["applied_date"] is None


def test_config_defaults_and_yaml(tmp_path):
    cfg = SendConfig()
    assert (cfg.mode, cfg.dry_run, cfg.auto_min_score, cfg.daily_cap, cfg.company_cooldown_days) == \
        ("approve", True, 80, 5, 90)
    assert cfg.require_letter and not cfg.kill_switch and cfg.from_address == "info@daniele-michelin.com"
    (tmp_path / "c.yaml").write_text("send:\n  mode: auto\n  dry_run: false\n  daily_cap: 3\n", encoding="utf-8")
    s = load_settings(tmp_path / "c.yaml")
    assert s.send.mode == "auto" and s.send.dry_run is False and s.send.daily_cap == 3
    assert "IONOS" in s.send.blocklist
    with pytest.raises(ValueError):
        SendConfig(mode="yolo")


def test_status_summary_kinds(env):
    settings, db = env
    settings.send.dry_run = True
    assert status_summary(settings, gate(settings, db))["kind"] == "test"
    settings.send.dry_run = False
    assert status_summary(settings, gate(settings, db))["kind"] == "approve"  # app toggle unknown
    db.set_client_state("macos", {"auto_send_enabled": True})
    s = status_summary(settings, gate(settings, db), db.client_states())
    assert s["kind"] == "auto" and "AUTOMATISCHER VERSAND AKTIV" in s["headline"] and s["app_auto_send"]
    settings.send.mode = "off"
    assert status_summary(settings, gate(settings, db))["kind"] == "off"
    settings.send.kill_switch = True
    assert status_summary(settings, gate(settings, db))["kind"] == "kill"


def test_migration_backfills_existing_db(tmp_path):
    import sqlite3
    path = tmp_path / "old.db"
    c = sqlite3.connect(path)
    c.executescript("""CREATE TABLE jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, dedup_key TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL, source_id TEXT, title TEXT NOT NULL, company TEXT, location TEXT, remote INTEGER DEFAULT 0,
        url TEXT, description TEXT, salary_min REAL, salary_max REAL, salary_predicted INTEGER DEFAULT 0, published TEXT,
        fetched_at TEXT NOT NULL, rule_score INTEGER, score_breakdown TEXT, llm_score INTEGER, llm_reason TEXT,
        letter TEXT, letter_origin TEXT, letter_updated_at TEXT, score INTEGER DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'neu', status_updated_at TEXT, applied_date TEXT, notes TEXT,
        notified INTEGER DEFAULT 0, also_seen_on TEXT);
        INSERT INTO jobs (dedup_key, source, title, description, fetched_at)
        VALUES ('a|b', 'x', 'A', 'Lebenslauf an bewerbung@b.de', '2026-10-01');""")
    c.commit(); c.close()
    db = Database(path)
    assert db.get_job(1)["apply_email"] == "bewerbung@b.de"


# ---- API + dashboard -----------------------------------------------------------

AUTH = ("api-user", "api-pass")


@pytest.fixture
def client(env):
    settings, db = env
    settings.dashboard_user, settings.dashboard_password = AUTH
    c = TestClient(create_app(settings, db=db))
    c.auth = AUTH
    return c, settings, db


def test_api_send_settings_outbox_preview(client):
    c, settings, db = client
    j = add_job(db)
    s = c.get("/api/v1/send-settings").json()
    assert s["mode"] == "auto" and s["dry_run"] is False and s["daily_cap"] == 5 and s["remaining_today"] == 5
    ob = c.get("/api/v1/outbox").json()
    assert ob["count"] == 1 and ob["items"][0]["email"]["to"] == "jobs@acme.de"
    assert ob["items"][0]["email"]["sender"] == "Daniele Michelin <info@daniele-michelin.com>"
    p = c.get(f"/api/v1/jobs/{j['id']}/email-preview").json()
    assert p["can_send"] and p["auto_eligible"] and p["in_outbox"] and p["send_state"]["state"] == "ready"
    lst = c.get("/api/v1/jobs").json()["items"][0]
    assert lst["apply_email"] == "jobs@acme.de" and lst["apply_method"] == "email"
    assert lst["send_state"]["state"] == "email"


def test_api_approve_sent_flow(client):
    c, settings, db = client
    settings.send.mode = "approve"
    j = add_job(db, score=50)
    assert c.post(f"/api/v1/jobs/{j['id']}/approve", json={}).json()["approved"] is True
    assert c.get("/api/v1/outbox").json()["items"][0]["reason"] == "approved"
    assert c.delete(f"/api/v1/jobs/{j['id']}/approve").json()["approved"] is False
    r = c.post(f"/api/v1/jobs/{j['id']}/sent", json={"dry_run": True, "trigger": "manual"})
    assert r.status_code == 200 and r.json()["sent"]["dry_run"] is True
    assert r.json()["job"]["status"] == "neu"
    assert r.json()["job"]["send_state"]["state"] == "test"
    r = c.post(f"/api/v1/jobs/{j['id']}/sent", json={"dry_run": False, "message_id": "<m@x>"})
    d = r.json()["job"]
    assert d["status"] == "beworben" and d["send_state"]["state"] == "sent"
    sent = c.get("/api/v1/sent").json()
    assert sent["count"] == 2 and sent["sent_total"] == 1 and sent["dry_run_total"] == 1
    # dedup: approving again is refused with the reason
    r = c.post(f"/api/v1/jobs/{j['id']}/approve", json={})
    assert r.status_code == 409 and "already_sent" in r.json()["blockers"]
    sid = sent["items"][0]["id"]
    assert c.patch(f"/api/v1/sent/{sid}", json={"message_id": "<z@x>"}).json()["message_id"] == "<z@x>"


def test_api_set_apply_email_and_client_state(client):
    c, settings, db = client
    j = add_job(db, email=None)
    r = c.patch(f"/api/v1/jobs/{j['id']}", json={"apply_email": "HR@Firma.de"})
    assert r.json()["apply_email"] == "hr@firma.de" and r.json()["apply_email_source"] == "manuell"
    assert c.patch(f"/api/v1/jobs/{j['id']}", json={"apply_email": "kaputt"}).status_code == 422
    db.backfill_apply_email()  # manual entry survives re-detection
    assert db.get_job(j["id"])["apply_email"] == "hr@firma.de"
    assert c.post("/api/v1/client-state", json={"auto_send_enabled": True, "app_version": "1.1"}).json()["ok"]
    assert db.client_states()[0]["auto_send_enabled"] is True


def test_api_send_endpoints_need_auth_and_json(client):
    c, _, db = client
    j = add_job(db)
    anon = TestClient(c.app)
    for path in ("/api/v1/outbox", "/api/v1/send-settings", "/api/v1/sent", f"/api/v1/jobs/{j['id']}/email-preview"):
        assert anon.get(path).status_code == 401
    assert c.post(f"/api/v1/jobs/{j['id']}/sent", content="dry_run=1",
                  headers={"content-type": "application/x-www-form-urlencoded"}).status_code == 415


def test_dashboard_banner_badges_and_outbox(client):
    c, settings, db = client
    settings.send.dry_run = True
    j = add_job(db)
    m = add_job(db, title="Manual", company="M", email=None)
    html = c.get("/").text
    assert "TESTMODUS – es werden keine E-Mails versendet" in html
    assert "Heute gesendet: 0 · Insgesamt gesendet: 0 · Im Testmodus vorbereitet: 0" in html
    assert "Nur manuell (keine E-Mail-Adresse)" in html
    detail = c.get(f"/jobs/{j['id']}").text
    assert "E-Mail-Bewerbung" in detail and "Bewerbung als Support Engineer" in detail
    assert "Bereit zum Senden" in detail
    actions.record_sent(settings, db, db.get_job(j["id"]), dry_run=True)
    assert "Test – nicht gesendet" in c.get(f"/jobs/{j['id']}").text
    settings.send.dry_run = False
    actions.record_sent(settings, db, db.get_job(j["id"]), dry_run=False)
    html = c.get("/").text
    assert "Gesendet am" in html and "jobs@acme.de" in html
    assert "Heute gesendet: 1 · Insgesamt gesendet: 1 · Im Testmodus vorbereitet: 1" in html
    ob = c.get("/outbox").text
    assert "Echt gesendet" in ob and "Test – nicht gesendet" in ob
    assert "Gesendet ✅" in ob and "Test 🧪" in ob and "heute gesendet" in ob
    # approve / unapprove / set address via the dashboard forms
    assert c.post(f"/jobs/{m['id']}/apply-email", data={"apply_email": "jobs@m.de"},
                  follow_redirects=False).status_code == 303
    assert db.get_job(m["id"])["apply_email"] == "jobs@m.de"
    c.post(f"/jobs/{m['id']}/approve", follow_redirects=False)
    assert db.get_job(m["id"])["send_approved_at"]
    c.post(f"/jobs/{m['id']}/unapprove", follow_redirects=False)
    assert db.get_job(m["id"])["send_approved_at"] is None
