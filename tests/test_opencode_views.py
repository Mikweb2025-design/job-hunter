"""opencode letters (fake CLI, never the real one), workflow views, Postausgang rows."""
import json
import os
import stat
import sys
import time

import pytest
from fastapi.testclient import TestClient

from jobhunter import actions, letters
from jobhunter.config import LLMConfig, SendConfig, load_settings
from jobhunter.db import Database
from jobhunter.llm import (LLMClient, LLMError, LetterRejected, OPENCODE_ORIGIN, build_letter_prompt,
                           clean_letter_output, opencode_command, run_opencode, text_from_json_events)
from jobhunter.models import JobPosting
from jobhunter.views import annotate, classify, filter_view, real_sent_ids, view_counts

AUTH = ("u", "p")
GOOD = ("Als Cloud Support Engineer bei Acme GmbH möchte ich meine Erfahrung aus dem technischen Support "
        "einer Nextcloud-Plattform einbringen, die ich bei IONOS/STRATO seit Jahren betreue.\n\n"
        "Dort löse ich im Second- und Third-Level-Support komplexe Linux- und Python-Fälle, analysiere Störungen bis zur Ursache "
        "und schreibe FAQ-Artikel, damit Kolleginnen und Kollegen wiederkehrende Anfragen selbst lösen können. "
        "Eigene Werkzeuge mit Python und Docker nutze ich, um Abläufe im Team zu vereinfachen.\n\n"
        "Ihre Anzeige betont den direkten Kontakt mit Geschäftskunden und stabile Cloud-Dienste. In den ersten "
        "90 Tagen würde ich Ihre Ticket-Abläufe kennenlernen, die häufigsten Anfragen auswerten und daraus "
        "Dokumentation für das Team ableiten.\n\n"
        "Ich freue mich auf ein persönliches Gespräch.")

FAKE = """#!{python}
import json, os, sys, time
args = sys.argv[1:]
if os.environ.get("FAKE_OC_ARGS"):
    open(os.environ["FAKE_OC_ARGS"], "w").write(json.dumps({{"args": args, "cwd": os.getcwd()}}))
mode = os.environ.get("FAKE_OC_MODE", "json")
letter = os.environ.get("FAKE_OC_LETTER", "")
if mode == "sleep":
    time.sleep(30)
if mode == "fail":
    sys.stderr.write("\\x1b[31mError: model not found\\x1b[0m\\n")
    sys.exit(3)
if mode == "plain":
    print("\\x1b[0m> build · big-pickle\\x1b[0m")
    print("Hier ist das Anschreiben:")
    print("Sehr geehrte Damen und Herren,")
    print(letter)
    print("Mit freundlichen Grüßen")
    print("Daniele")
else:
    print(json.dumps({{"type": "step_start", "part": {{}}}}))
    print(json.dumps({{"type": "text", "part": {{"text": "Ich schaue mir das an."}}}}))
    print(json.dumps({{"type": "tool_use", "part": {{"tool": "read"}}}}))
    print(json.dumps({{"type": "text", "part": {{"text": letter}}}}))
    print(json.dumps({{"type": "step_finish", "part": {{}}}}))
"""


@pytest.fixture
def fake_oc(tmp_path, monkeypatch):
    path = tmp_path / "bin" / "opencode"
    path.parent.mkdir()
    path.write_text(FAKE.format(python=sys.executable), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    args_file = tmp_path / "args.json"
    monkeypatch.setenv("FAKE_OC_ARGS", str(args_file))
    monkeypatch.setenv("FAKE_OC_LETTER", GOOD)
    monkeypatch.setenv("FAKE_OC_MODE", "json")
    return str(path), args_file


def oc_cfg(binary, **kw):
    return LLMConfig(provider="opencode", model="opencode/big-pickle", opencode_bin=binary,
                     timeout_s=kw.pop("timeout_s", 20), **kw)


def add_job(db, title="Cloud Support Engineer", company="Acme GmbH", email="jobs@acme.de", score=70,
            letter=None, origin=None, status="neu", location="10115 Berlin"):
    desc = (f"Bewerbung an {email}. " if email else "Bewerbung nur über das Portal. ") + "Linux, Python, Nextcloud."
    desc += " Wir suchen Verstärkung für unser Support-Team in Berlin." * 6  # >= 300 chars: KI letters allowed
    jid = db.insert_job(JobPosting(source="test", source_id=title + company, title=title, company=company,
                                   location=location, description=desc, url="https://example.org/job"), score, {})
    db.update_job(jid, score=score, letter=letter, letter_origin=origin, status=status)
    return db.get_job(jid)


# ---- command + output cleaning -------------------------------------------------

def test_command_building():
    assert opencode_command("/x/opencode", "opencode/big-pickle", "P") == [
        "/x/opencode", "run", "-m", "opencode/big-pickle", "--format", "json", "P"]


def test_run_opencode_passes_model_and_prompt(fake_oc, tmp_path):
    binary, args_file = fake_oc
    out = run_opencode(binary, "opencode/big-pickle", "Mein Prompt", 20, workdir=tmp_path / "wd")
    seen = json.loads(args_file.read_text())
    assert seen["args"] == ["run", "-m", "opencode/big-pickle", "--format", "json", "Mein Prompt"]
    assert seen["cwd"].endswith("wd")
    assert text_from_json_events(out) == GOOD


def test_run_opencode_errors(fake_oc, monkeypatch):
    binary, _ = fake_oc
    with pytest.raises(LLMError, match="nicht gefunden"):
        run_opencode("/nonexistent/opencode", "m/x", "p", 5)
    monkeypatch.setenv("FAKE_OC_MODE", "fail")
    with pytest.raises(LLMError, match=r"Exit 3\): Error: model not found"):
        run_opencode(binary, "m/x", "p", 20)
    monkeypatch.setenv("FAKE_OC_MODE", "sleep")
    t0 = time.monotonic()
    with pytest.raises(LLMError, match="nicht geantwortet"):
        run_opencode(binary, "m/x", "p", 1)
    assert time.monotonic() - t0 < 10


def test_clean_json_events_takes_last_text():
    raw = "\n".join(json.dumps(e) for e in [
        {"type": "text", "part": {"text": "Vorbemerkung"}}, {"type": "tool_use", "part": {}},
        {"type": "text", "part": {"text": GOOD}}])
    assert clean_letter_output(raw) == GOOD


def test_clean_plain_text_strips_ansi_noise_salutation_closing():
    raw = ("\x1b[0m> build · big-pickle\x1b[0m\n```\nHier ist das Anschreiben:\n"
           "Sehr geehrte Damen und Herren,\n\n" + "\x1b[1m" + GOOD + "\x1b[0m\n\nMit freundlichen Grüßen\nDaniele\n```")
    assert clean_letter_output(raw) == GOOD
    assert clean_letter_output(f'"{GOOD}"') == GOOD
    assert clean_letter_output("**" + GOOD + "**") == GOOD


@pytest.mark.parametrize("raw, match", [
    ("", "keinen Text"),
    ("Zu kurz. Bitte um Gespräch.", "zu kurz"),
    (GOOD + " [Firmenname ergänzen]", "Platzhalter"),
])
def test_clean_rejects(raw, match):
    with pytest.raises(LetterRejected, match=match):
        clean_letter_output(raw)


def test_clean_fixes_glued_numbers():
    from jobhunter.llm import fix_glued_numbers
    assert fix_glued_numbers("Seit2018 bearbeite ich rund200 Tickets und ca.150.000 Instanzen") == \
        "Seit 2018 bearbeite ich rund 200 Tickets und ca. 150.000 Instanzen"
    assert fix_glued_numbers("200Tickets pro Woche") == "200 Tickets pro Woche"
    for keep in ("S3-Objektspeicher", "L2- und L3-Incidents", "2nd/3rd Level", "IPv6", "Python3", "M365", "1980er"):
        assert fix_glued_numbers(keep) == keep


def test_clean_rejects_invented_numbers():
    letter = GOOD.replace("seit Jahren", "seit 17 Jahren")
    with pytest.raises(LetterRejected, match="17"):
        clean_letter_output(letter, sources=["Profil ohne Zahl", "Anzeige"])
    assert clean_letter_output(letter, sources=["17 Jahre Erfahrung"]) == letter


def test_letter_prompt_rules_and_profile():
    p = build_letter_prompt("# CV\n<!-- Hinweis -->\nNextcloud", {"title": "Support", "description": "Linux"}, 44000)
    assert "3 bis 4 kurze Absätze" in p and "Keine Platzhalter" in p and "Hinweis" not in p
    assert "<profil>" in p and "Titel: Support" in p and "Mindestgehalt 44000" in p


# ---- config ------------------------------------------------------------------

def test_config_opencode(tmp_path, monkeypatch, fake_oc):
    binary, _ = fake_oc
    cfg = tmp_path / "c.yaml"
    cfg.write_text("llm:\n  provider: opencode\n  model: claude-sonnet-5-5\n", encoding="utf-8")
    monkeypatch.setenv("OPENCODE_BIN", binary)
    monkeypatch.delenv("LLM_PROVIDER", raising=False)
    monkeypatch.delenv("LLM_MODEL", raising=False)
    s = load_settings(cfg)
    assert s.llm.provider == "opencode" and s.llm.model == "opencode/big-pickle"
    assert s.llm.timeout_s == 180 and s.llm.max_per_run == 20 and s.llm.enabled
    monkeypatch.setenv("OPENCODE_BIN", str(tmp_path / "missing"))
    assert not load_settings(cfg).llm.enabled
    monkeypatch.setenv("LLM_PROVIDER", "anthropic")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "k")
    cfg.write_text("llm:\n  provider: opencode\n  model: opencode/big-pickle\n", encoding="utf-8")
    assert load_settings(cfg).llm.model == "claude-sonnet-5-5"


def test_repo_config_send_values_unchanged():
    # Deployment choice (operator-managed): automatic sending is ON for real,
    # but ONLY for the home region / 100% remote – the relocation filter must stay on.
    s = load_settings("config.yaml")
    assert (s.send.mode, s.send.dry_run, s.send.location_filter) == ("auto", False, True)


# ---- client + actions --------------------------------------------------------

def test_client_write_letter_opencode(fake_oc, cv_text):
    binary, args_file = fake_oc
    r = LLMClient(oc_cfg(binary)).write_letter(cv_text, {"title": "Support", "company": "Acme",
                                                         "description": "Linux"}, 44000)
    assert (r.score, r.letter, r.origin) == (None, GOOD, OPENCODE_ORIGIN)
    prompt = json.loads(args_file.read_text())["args"][-1]
    assert "3 bis 4 kurze Absätze" in prompt and "Titel: Support" in prompt


def test_action_write_letter_sets_origin(settings, fake_oc):
    binary, _ = fake_oc
    settings.llm = oc_cfg(binary)
    db = Database(settings.db_path)
    j = add_job(db, letter="Vorlage [x]", origin="vorlage")
    j = actions.write_letter(settings, db, j)
    assert j["letter"] == GOOD and j["letter_origin"] == "KI (opencode)" and j["llm_score"] is None


def test_action_write_letter_rejected_keeps_old_letter(settings, fake_oc, monkeypatch):
    binary, _ = fake_oc
    settings.llm = oc_cfg(binary)
    monkeypatch.setenv("FAKE_OC_LETTER", "Viel zu kurz.")
    db = Database(settings.db_path)
    j = add_job(db, letter="Alt", origin="manuell")
    with pytest.raises(LetterRejected):
        actions.write_letter(settings, db, j)
    assert db.get_job(j["id"])["letter"] == "Alt"


def test_action_write_letter_without_llm(settings):
    db = Database(settings.db_path)
    with pytest.raises(actions.LLMNotConfigured):
        actions.write_letter(settings, db, add_job(db))


# ---- views -------------------------------------------------------------------

def test_classify_views(settings):
    settings.send = SendConfig()
    db = Database(settings.db_path)
    auto = add_job(db, title="A", company="Acme")
    manual = add_job(db, title="M", company="Beta", email=None, score=90)
    blocked = add_job(db, title="B", company="IONOS SE", email="jobs@ionos.de")
    applied = add_job(db, title="Ap", company="C", status="gespraech")
    later = add_job(db, title="L", company="D", status="absage")
    sent = add_job(db, title="S", company="E")
    db.add_sent(sent, "jobs@acme.de", "s", "b", "2026-10-01T10:00:00+00:00", False, None, "auto")
    test_only = add_job(db, title="T", company="F")
    db.add_sent(test_only, "jobs@acme.de", "s", "b", "2026-10-01T10:00:00+00:00", True, None, "auto")
    ids = real_sent_ids(db)
    bl = settings.send.blocklist
    got = {j["title"]: classify(j, ids, bl) for j in db.list_jobs()}
    assert got == {"A": "auto", "M": "manual", "B": "manual", "Ap": "applied", "L": "later", "S": "applied",
                   "T": "auto"}
    c = view_counts(db, bl)
    assert (c["auto"], c["manual"], c["applied"], c["later"], c["today"], c["total"]) == (2, 2, 2, 1, 2, 7)
    jobs = annotate(db.list_jobs(), ids, bl)
    today = filter_view(jobs, "today")
    assert [j["title"] for j in today] == ["M", "B"]  # best score first
    assert today[0]["apply_label"] == "MANUELL – über Portal bewerben"
    assert next(j for j in jobs if j["title"] == "A")["apply_label"] == "Automatisch (E-Mail an jobs@acme.de)"


def test_today_limit_10(settings):
    db = Database(settings.db_path)
    for i in range(14):
        add_job(db, title=f"Job {i}", company=f"Firma {i}", email=None, score=50 + i)
    jobs = annotate(db.list_jobs(), set(), [])
    today = filter_view(jobs, "today")
    assert len(today) == 10 and today[0]["score"] == 63


# ---- API + dashboard -----------------------------------------------------------

@pytest.fixture
def client(settings):
    settings.dashboard_user, settings.dashboard_password = AUTH
    settings.send = SendConfig()
    db = Database(settings.db_path)
    c = TestClient(create_app_(settings, db))
    c.auth = AUTH
    return c, settings, db


def create_app_(settings, db):
    from jobhunter.web import create_app
    return create_app(settings, db=db)


def _wait_letters(timeout=20):
    t0 = time.monotonic()
    while letters.is_running() and time.monotonic() - t0 < timeout:
        time.sleep(0.05)
    assert not letters.is_running()


def test_api_views_and_filter(client):
    c, _, db = client
    add_job(db, title="A")
    add_job(db, title="M", company="Beta", email=None)
    v = c.get("/api/v1/views").json()
    assert v["counts"]["auto"] == 1 and v["counts"]["manual"] == 1 and v["counts"]["today"] == 1
    assert v["labels"]["auto"] == "✉ Automatisch per E-Mail" and v["order"][0] == "today"
    items = c.get("/api/v1/jobs?view=manual").json()["items"]
    assert [i["title"] for i in items] == ["M"] and items[0]["view"] == "manual"
    assert items[0]["apply_label"] == "MANUELL – über Portal bewerben"
    assert c.get("/api/v1/jobs?view=today").json()["count"] == 1
    assert c.get("/api/v1/jobs?view=nope").status_code == 422
    assert c.get("/api/v1/jobs").json()["items"][0]["view"] in ("auto", "manual")


def test_api_write_letter_not_configured(client):
    c, _, db = client
    j = add_job(db)
    assert c.post(f"/api/v1/jobs/{j['id']}/write-letter", json={}).status_code == 503
    assert c.post("/api/v1/letters/write-all", json={}).status_code == 503


def test_api_write_letter_and_write_all(client, fake_oc):
    c, settings, db = client
    binary, _ = fake_oc
    settings.llm = oc_cfg(binary, max_per_run=2)
    j = add_job(db, title="A", score=60)
    r = c.post(f"/api/v1/jobs/{j['id']}/write-letter", json={})
    assert r.status_code == 200, r.text
    assert r.json()["letter"] == GOOD and r.json()["letter_origin"] == "KI (opencode)"
    # write-all: only open jobs with template / no letter, best first, capped at max_per_run
    for i, score in enumerate((90, 80, 70)):
        add_job(db, title=f"T{i}", company=f"F{i}", score=score, letter="Vorlage", origin="vorlage")
    add_job(db, title="Done", company="G", score=99, letter="Eigener Text", origin="manuell")
    add_job(db, title="Closed", company="H", score=98, status="absage")
    r = c.post("/api/v1/letters/write-all", json={})
    assert r.status_code == 202 and r.json()["started"] and r.json()["queued"] == 2
    _wait_letters()
    st = c.get("/api/v1/letters/status").json()
    assert (st["done"], st["failed"], st["total"], st["running"]) == (2, 0, 2, False)
    by_title = {x["title"]: x for x in db.list_jobs()}
    assert by_title["T0"]["letter_origin"] == by_title["T1"]["letter_origin"] == "KI (opencode)"
    assert by_title["T2"]["letter_origin"] == "vorlage" and by_title["Done"]["letter"] == "Eigener Text"
    # background single job (wait=false)
    r = c.post(f"/api/v1/jobs/{by_title['T2']['id']}/write-letter?wait=false", json={})
    assert r.status_code == 202
    _wait_letters()
    assert db.get_job(by_title["T2"]["id"])["letter_origin"] == "KI (opencode)"


def test_api_write_letter_failure_is_502(client, fake_oc, monkeypatch):
    c, settings, db = client
    binary, _ = fake_oc
    settings.llm = oc_cfg(binary)
    monkeypatch.setenv("FAKE_OC_LETTER", "[Platzhalter]" + "x" * 300)
    j = add_job(db)
    r = c.post(f"/api/v1/jobs/{j['id']}/write-letter", json={})
    assert r.status_code == 502 and "Platzhalter" in r.json()["detail"]


def test_api_put_letter_origin(client):
    c, _, db = client
    j = add_job(db)
    r = c.put(f"/api/v1/jobs/{j['id']}/letter", json={"letter": GOOD, "origin": "KI (opencode)"})
    assert r.json()["letter_origin"] == "KI (opencode)"
    assert c.put(f"/api/v1/jobs/{j['id']}/letter", json={"letter": "x"}).json()["letter_origin"] == "manuell"
    assert c.put(f"/api/v1/jobs/{j['id']}/letter", json={"letter": "x", "origin": "vorlage"}).status_code == 422


def test_dashboard_views_today_and_mark_applied(client, fake_oc):
    c, settings, db = client
    binary, _ = fake_oc
    settings.llm = oc_cfg(binary)
    a = add_job(db, title="Auto Job")
    m = add_job(db, title="Portal Job", company="Beta", email=None, letter=GOOD, origin="manuell")
    m["notes"] = "wichtig"
    db.update_job(m["id"], notes="wichtig")
    html = c.get("/").text
    # Navigation: Heute, Neu, Automatisch, Manuell, Tracker, Postausgang, Profil (+ Beworben/Später/Zu weit)
    for href in ('/today"', "?view=recent", "?view=auto", "?view=manual", '/tracker"', '/outbox"', '/profile"',
                 "?view=applied", "?view=later", "?view=far"):
        assert href in html
    assert "Automatisch (E-Mail an jobs@acme.de)" in html and "MANUELL – über Portal bewerben" in html
    assert "Alle Vorlagen schreiben (max 10)" in html
    manual_html = c.get("/?view=manual").text
    assert "Portal Job" in manual_html and "Auto Job" not in manual_html
    today = c.get("/today").text
    assert "Jetzt manuell bewerben" in today and "Anschreiben kopieren" in today
    assert "Als beworben markieren" in today and "Anschreiben mit KI schreiben" in today
    r = c.post(f"/jobs/{m['id']}/mark-applied", data={"back": "today"}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"].startswith("/today")
    j = db.get_job(m["id"])
    assert j["status"] == "beworben" and j["applied_date"] and j["notes"] == "wichtig"
    assert "Heute erledigt (1)" in c.get("/today").text
    # KI button on the detail page starts a background write
    assert "Anschreiben mit KI schreiben" in c.get(f"/jobs/{a['id']}").text
    r = c.post(f"/jobs/{a['id']}/write-letter", follow_redirects=False)
    assert r.status_code == 303 and "letter_started" in r.headers["location"]
    _wait_letters()
    assert db.get_job(a["id"])["letter_origin"] == "KI (opencode)"
    r = c.post("/letters/write-all", data={"view": "manual"}, follow_redirects=False)
    assert r.status_code == 303 and "letters_none" in r.headers["location"]


def test_outbox_rows_states(client):
    c, settings, db = client
    settings.send = SendConfig(mode="approve", dry_run=True, daily_cap=5)
    letter = GOOD
    w = add_job(db, title="Wait", company="W1", letter=letter, origin="manuell")
    actions.approve(settings, db, w)
    e = add_job(db, title="Err", company="E1", letter=letter, origin="manuell")
    actions.approve(settings, db, e)
    db.update_job(e["id"], letter="Mit [Platzhalter]")
    s = add_job(db, title="Sent", company="S1", letter=letter, origin="manuell")
    actions.record_sent(settings, db, s, dry_run=False)
    t = add_job(db, title="Test", company="T1", letter=letter, origin="manuell")
    actions.record_sent(settings, db, t, dry_run=True)
    data = c.get("/api/v1/outbox/log").json()
    states = {r["title"]: r["state"] for r in data["rows"]}
    assert states == {"Wait": "waiting", "Err": "error", "Sent": "sent", "Test": "test"}
    err = next(r for r in data["rows"] if r["state"] == "error")
    assert "Platzhalter" in err["detail"] and err["to"] == "jobs@acme.de" and err["date"]
    sm = data["summary"]
    assert (sm["sent_today"], sm["daily_cap"], sm["sent_total"], sm["test_total"], sm["waiting"], sm["errors"]) == \
        (1, 5, 1, 1, 1, 1)
    html = c.get("/outbox").text
    for label in ("Gesendet ✅", "Test 🧪", "Wartet ⏳", "Fehler ❌", "heute gesendet", "von 5"):
        assert label in html


def test_pipeline_uses_opencode_for_letters(settings, fake_oc, monkeypatch):
    from jobhunter import alerts
    monkeypatch.setattr(alerts, "MIN_DESCRIPTION_FOR_KI", 0)  # fixture snippets are short
    from jobhunter.pipeline import run_cycle
    from jobhunter.sources.adzuna import parse_response as adzuna_parse

    from .conftest import load_json
    from .test_pipeline_web import FixtureSource
    binary, _ = fake_oc
    settings.llm = oc_cfg(binary, threshold=0, max_per_run=1)
    db = Database(settings.db_path)
    run_cycle(settings, db=db, sources=[FixtureSource("adzuna", adzuna_parse(load_json("adzuna_search.json")))],
              notify=False)
    origins = [j["letter_origin"] for j in db.list_jobs()]
    assert origins.count("KI (opencode)") == 1
    assert all(j["llm_score"] is None for j in db.list_jobs())
