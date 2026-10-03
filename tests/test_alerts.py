"""Job-alert e-mail import (LinkedIn/StepStone/Indeed via the macOS app), paste posting text,
no automatic KI letter without posting text."""
import pytest
from fastapi.testclient import TestClient

from jobhunter import alerts, letters
from jobhunter.db import Database
from jobhunter.models import JobPosting
from jobhunter.web import create_app

AUTH = ("api-user", "api-pass")

POSTING = ("Wir suchen einen Cloud Support Engineer (m/w/d) für unser Team in Berlin. Du betreust Kunden "
           "im 2nd-Level-Support, analysierst Probleme auf Linux-Servern, arbeitest mit Docker und "
           "Kubernetes und automatisierst wiederkehrende Aufgaben mit Python. Tickets bearbeitest du "
           "eigenständig, SQL-Kenntnisse sind von Vorteil. Bewerbung an jobs@acme.de bis Ende Oktober.")


def item(**kw):
    base = {"source": "linkedin-alert", "external_id": "4416593964", "title": "Cloud Support Engineer (m/w/d)",
            "company": "Acme GmbH", "location": "Berlin, Berlin, Deutschland",
            "url": "https://www.linkedin.com/comm/jobs/view/4416593964?alertAction=markasviewed&trk=eml",
            "received_at": "2026-10-02T23:34:03Z"}
    base.update(kw)
    return base


@pytest.fixture
def ctx(settings):
    settings.dashboard_user, settings.dashboard_password = AUTH
    db = Database(settings.db_path)
    client = TestClient(create_app(settings, db=db))
    client.auth = AUTH
    return client, db, settings


def test_canonical_urls():
    assert alerts.canonical_url("linkedin-alert", "https://www.linkedin.com/comm/jobs/view/4416593964?x=1&otpToken=s") \
        == "https://www.linkedin.com/jobs/view/4416593964/"
    assert alerts.canonical_url("linkedin-alert", "https://de.linkedin.com/jobs/view/support-engineer-at-acme-4416593964?trk=a") \
        == "https://www.linkedin.com/jobs/view/4416593964/"
    assert alerts.canonical_url("linkedin-alert", "https://evil.example/jobs/view/4416593964", "4416593964") \
        == "https://www.linkedin.com/jobs/view/4416593964/"
    assert alerts.canonical_url("linkedin-alert", "https://evil.example/x") == ""
    assert alerts.canonical_url(
        "stepstone-alert", "https://www.stepstone.de/stellenangebote--Support-Engineer-Berlin-Acme--12345678-inline.html?utm=x"
    ) == "https://www.stepstone.de/stellenangebote--Support-Engineer-Berlin-Acme--12345678-inline.html"
    assert alerts.canonical_url("indeed-alert", "https://de.indeed.com/rc/clk?jk=0123456789abcdef&from=ja") \
        == "https://de.indeed.com/viewjob?jk=0123456789abcdef"
    assert alerts.source_label("linkedin-alert") == "LinkedIn (Job-Alert)"
    assert alerts.source_label("arbeitsagentur") == "Arbeitsagentur"


def test_import_requires_auth_and_json(ctx):
    client, _, _ = ctx
    anon = TestClient(client.app)
    assert anon.post("/api/v1/jobs/import", json=[item()]).status_code == 401
    assert client.post("/api/v1/jobs/import", content="[]", headers={"content-type": "text/plain"}).status_code == 415


def test_import_new_jobs_scored_manual_without_letter(ctx):
    client, db, _ = ctx
    r = client.post("/api/v1/jobs/import", json=[
        item(),
        item(external_id="4473114556", title="Customer Support Agent GER/ENG (all genders)", company="Cardmarket.com",
             url="https://www.linkedin.com/comm/jobs/view/4473114556?trk=x"),
        item(source="xing-alert", external_id="1"),                      # unknown source
        item(external_id="", url="", title="Ohne Link"),                 # no id, no link
    ])
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["received"] == 4 and body["imported"] == 2 and body["invalid"] == 2 and body["duplicates"] == 0
    job = db.get_job(body["imported_ids"][0])
    assert job["source"] == "linkedin-alert" and job["source_id"] == "4416593964"
    assert job["url"] == "https://www.linkedin.com/jobs/view/4416593964/"
    assert job["apply_method"] == "manual" and job["apply_email"] is None
    assert not job["letter"] and job["published"] == "2026-10-02"
    bd = job["score_breakdown"]
    assert bd["title"] == 25 and bd["location"] == 15 and job["score"] > 0  # title + location, no text
    detail = client.get(f"/api/v1/jobs/{job['id']}").json()
    assert detail["source_label"] == "LinkedIn (Job-Alert)" and detail["description_length"] == 0
    assert detail["view"] == "manual"
    # filter by the new source; /sources lists the alert sources with labels
    listed = client.get("/api/v1/jobs", params={"source": "linkedin-alert"}).json()
    assert listed["count"] == 2
    srcs = {s["id"]: s["label"] for s in client.get("/api/v1/sources").json()}
    assert srcs["stepstone-alert"] == "StepStone (Job-Alert)" and srcs["indeed-alert"] == "Indeed (Job-Alert)"


def test_reimport_is_duplicate(ctx):
    client, db, _ = ctx
    first = client.post("/api/v1/jobs/import", json=[item()]).json()
    again = client.post("/api/v1/jobs/import", json=[item(), item(title="Cloud Support Engineer (w/m/d)")]).json()
    assert again["imported"] == 0 and again["duplicates"] == 2
    assert again["duplicate_ids"] == [first["imported_ids"][0]] * 2
    assert len(db.list_jobs()) == 1


def test_dedup_with_existing_arbeitsagentur_job(ctx, settings):
    client, db, _ = ctx
    aa = db.insert_job(JobPosting(source="arbeitsagentur", source_id="10000-1", title="Cloud Support Engineer (w/m/d)",
                                  company="ACME GmbH", location="Berlin", description=POSTING), 80, {})
    r = client.post("/api/v1/jobs/import", json=[item(company="Acme")]).json()
    assert r["imported"] == 0 and r["duplicate_ids"] == [aa]
    job = db.get_job(aa)
    assert job["source"] == "arbeitsagentur" and job["also_seen_on"] == "linkedin-alert"
    assert job["description"] == POSTING  # untouched
    listed = client.get("/api/v1/jobs", params={"source": "linkedin-alert"}).json()
    assert [j["id"] for j in listed["items"]] == [aa]


def test_no_automatic_ki_letter_without_posting_text(ctx, settings):
    client, db, _ = ctx
    jid = client.post("/api/v1/jobs/import", json=[item()]).json()["imported_ids"][0]
    long_aa = db.insert_job(JobPosting(source="arbeitsagentur", source_id="2", title="Application Support",
                                       company="B GmbH", location="Berlin", description=POSTING), 60, {})
    short_aa = db.insert_job(JobPosting(source="arbeitsagentur", source_id="3", title="Support Engineer",
                                        company="C GmbH", location="Berlin", description="Kurz."), 70, {})
    ids = [j["id"] for j in letters.candidates(settings, db, capped=False)]
    assert ids == [long_aa]
    assert jid not in ids and short_aa not in ids


def test_paste_description_rescores_and_enables_ki(ctx, settings):
    client, db, _ = ctx
    jid = client.post("/api/v1/jobs/import", json=[item()]).json()["imported_ids"][0]
    before = db.get_job(jid)["score"]
    r = client.put(f"/api/v1/jobs/{jid}/description", json={"description": "zu kurz"})
    assert r.status_code == 200 and r.json()["hint"] == alerts.KI_NEEDS_POSTING_HINT
    r = client.put(f"/api/v1/jobs/{jid}/description", json={"description": POSTING})
    body = r.json()
    assert r.status_code == 200 and body["description"] == POSTING and body["description_length"] == len(POSTING)
    assert body["letter_started"] is False  # no LLM configured in tests
    job = db.get_job(jid)
    assert job["score"] > before and "Linux" in job["score_breakdown"]["matched"]
    assert job["apply_method"] == "manual" and job["apply_email"] is None  # address not taken over automatically
    assert jid in [j["id"] for j in letters.candidates(settings, db, capped=False)]
    # a later rescore / backfill keeps alert jobs on "apply manually"
    db.backfill_apply_email()
    assert db.get_job(jid)["apply_email"] is None
    assert client.put("/api/v1/jobs/999/description", json={"description": POSTING}).status_code == 404


def test_paste_description_starts_ki_letter_when_llm_enabled(ctx, settings, monkeypatch):
    client, db, _ = ctx
    jid = client.post("/api/v1/jobs/import", json=[item()]).json()["imported_ids"][0]
    started = []
    monkeypatch.setattr(type(settings.llm), "enabled", property(lambda self: True))
    monkeypatch.setattr(letters, "start", lambda s, d, jobs, **kw: started.append([j["id"] for j in jobs]) or True)
    body = client.put(f"/api/v1/jobs/{jid}/description", json={"description": POSTING}).json()
    assert body["letter_started"] is True and started == [[jid]]
    db.update_job(jid, letter="Mein Text", letter_origin="manuell")
    body = client.put(f"/api/v1/jobs/{jid}/description", json={"description": POSTING + " Neu."}).json()
    assert body["letter_started"] is False and started == [[jid]]  # user letter never replaced


def test_dashboard_paste_form(ctx):
    client, db, _ = ctx
    jid = client.post("/api/v1/jobs/import", json=[item()]).json()["imported_ids"][0]
    html = client.get(f"/jobs/{jid}").text
    assert "Anzeigentext einfügen" in html and "LinkedIn (Job-Alert)" in html
    assert "Job-Alert-E-Mails enthalten keinen Anzeigentext" in html
    assert "Kein Anzeigentext" in html  # hint next to the KI button
    assert "Anzeigentext einfügen, dann KI-Anschreiben" in client.get("/today").text
    r = client.post(f"/jobs/{jid}/description", data={"description": POSTING}, follow_redirects=False)
    assert r.status_code == 303 and "msg=description_saved" in r.headers["location"]
    assert db.get_job(jid)["description"] == POSTING
    index = client.get("/").text
    assert '<option value="linkedin-alert"' in index and "LinkedIn (Job-Alert)" in index
    assert "Anzeigentext einfügen, dann KI-Anschreiben" not in client.get("/today").text
