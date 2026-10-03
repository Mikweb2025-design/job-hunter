"""Regenerate the JSON fixtures for the Swift decoding tests from the real backend.

Usage (from the job-hunter repo's virtualenv):
    ../job-hunter/.venv/bin/python scripts/make_fixtures.py ../job-hunter

Uses the backend's own test fixtures (BA + Adzuna sample responses) and an in-process
TestClient: no network, no real credentials.
"""
import json
import sys
import tempfile
from pathlib import Path

backend = Path(sys.argv[1] if len(sys.argv) > 1 else "../job-hunter").resolve()
sys.path.insert(0, str(backend))

from fastapi.testclient import TestClient  # noqa: E402

from jobhunter.config import LLMConfig, SearchProfile, SendConfig, Settings  # noqa: E402
from jobhunter.models import JobPosting  # noqa: E402
from jobhunter.db import Database  # noqa: E402
from jobhunter.pipeline import run_cycle  # noqa: E402
from jobhunter.web import create_app  # noqa: E402
from tests.conftest import CV_TEXT  # noqa: E402
from tests.test_pipeline_web import _sources  # noqa: E402


out = Path(__file__).resolve().parent.parent / "Tests" / "JobHunterCoreTests" / "Fixtures"
out.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / "cv_profile.md").write_text(CV_TEXT, encoding="utf-8")
    profile = SearchProfile(queries=["Support Engineer"], location="Berlin", min_salary=44000,
                            target_titles=["Support Engineer", "Technical Account Manager", "Application Support"],
                            excluded_title_keywords=["Werkstudent", "Praktikum"], excluded_keywords=["Zeitarbeit"],
                            keyword_saturation=10)
    settings = Settings(profile=profile, llm=LLMConfig(threshold=0), sources={}, data_dir=tmp)
    db = Database(settings.db_path)
    run_cycle(settings, db=db, sources=_sources()[:2], notify=False)
    c = TestClient(create_app(settings, db=db))
    top = db.list_jobs()[0]["id"]
    excluded = [j for j in db.list_jobs() if j["score"] == 0][0]["id"]
    c.patch(f"/api/v1/jobs/{top}", json={"status": "beworben", "notes": "Über das Portal beworben"})
    files = {
        "jobs.json": c.get("/api/v1/jobs").json(),
        "job_detail.json": c.get(f"/api/v1/jobs/{top}").json(),
        "job_detail_excluded.json": c.get(f"/api/v1/jobs/{excluded}").json(),
        "stats.json": c.get("/api/v1/stats").json(),
        "health.json": c.get("/api/v1/health").json(),
        "run.json": {"started": True, "running": True},
    }
    # E-mail application fixtures: one job with a detected address and an LLM-style letter.
    settings.send = SendConfig(mode="auto", dry_run=False)
    letter = ("Ich betreue seit Jahren Kunden einer Hosting-Plattform. Ihre Anzeige nennt Linux. "
              "In den ersten 90 Tagen würde ich Tickets auswerten. Ich freue mich auf ein Gespräch.")
    mail_id = db.insert_job(JobPosting(source="rss", source_id="m1", title="Cloud Support Engineer (m/w/d)",
                                       company="Acme GmbH", description="Bitte senden Sie Ihre Bewerbung an jobs@acme.de."),
                            85, {})
    db.update_job(mail_id, score=85, letter=letter, letter_origin="anthropic")
    sent_id = db.insert_job(JobPosting(source="rss", source_id="m2", title="Support Engineer",
                                       company="Beta AG", description="Lebenslauf an karriere@beta.de"), 82, {})
    db.update_job(sent_id, score=82, letter=letter, letter_origin="manuell")
    c.post(f"/api/v1/jobs/{sent_id}/sent", json={"dry_run": True, "trigger": "manual",
                                                 "sent_at": "2026-10-02T09:00:00Z"})
    c.post(f"/api/v1/jobs/{sent_id}/sent", json={"dry_run": False, "trigger": "auto",
                                                 "sent_at": "2026-10-03T08:15:00Z"})
    files |= {
        "send_settings.json": c.get("/api/v1/send-settings").json(),
        "outbox.json": c.get("/api/v1/outbox").json(),
        "email_preview.json": c.get(f"/api/v1/jobs/{mail_id}/email-preview").json(),
        "email_preview_sent.json": c.get(f"/api/v1/jobs/{sent_id}/email-preview").json(),
        "sent.json": c.get("/api/v1/sent").json(),
        "jobs_with_mail.json": c.get("/api/v1/jobs").json(),
    }
    for name, data in files.items():
        (out / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("wrote", out / name)
