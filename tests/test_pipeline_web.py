from fastapi.testclient import TestClient

from jobhunter.db import Database
from jobhunter.llm import LLMError, parse_llm_json, template_letter
from jobhunter.pipeline import run_cycle
from jobhunter.scoring import CVProfile
from jobhunter.sources.adzuna import parse_response as adzuna_parse
from jobhunter.sources.arbeitsagentur import parse_search_response as ba_parse
from jobhunter.sources.base import Source, SourceError
from jobhunter.web import create_app

from .conftest import load_json


class FixtureSource(Source):
    def __init__(self, name, jobs):
        super().__init__({})
        self.name, self._jobs = name, jobs

    def fetch(self, profile):
        return self._jobs


class BrokenSource(Source):
    name = "broken"

    def fetch(self, profile):
        raise SourceError("HTTP 403")


def _sources():
    return [FixtureSource("arbeitsagentur", ba_parse(load_json("ba_search.json"))),
            FixtureSource("adzuna", adzuna_parse(load_json("adzuna_search.json"))),
            BrokenSource({})]


def test_run_cycle_dedups_scores_and_survives_broken_source(settings):
    db = Database(settings.db_path)
    rep = run_cycle(settings, db=db, sources=_sources(), notify=False)
    # 3 BA + 3 Adzuna, "Technical Support Engineer" Virtimo appears on both -> 5 unique
    assert len(rep.new_ids) == 5
    assert any("broken" in e for e in rep.errors)
    jobs = db.list_jobs()
    assert jobs == sorted(jobs, key=lambda j: -j["score"])
    virtimo = [j for j in jobs if "virtimo" in j["dedup_key"]]
    assert len(virtimo) == 1 and virtimo[0]["also_seen_on"] == "adzuna"
    werkstudent = [j for j in jobs if "Werkstudent" in j["title"]][0]
    assert werkstudent["score"] == 0
    # second run: nothing new
    assert run_cycle(settings, db=db, sources=_sources(), notify=False).new_ids == []


def test_template_letter_without_llm(settings, cv_text):
    db = Database(settings.db_path)
    settings.llm.threshold = 0
    run_cycle(settings, db=db, sources=_sources()[:2], notify=False)
    j = db.list_jobs()[0]
    assert j["letter_origin"] == "vorlage"
    assert j["letter"].count(".") >= 4
    letter = template_letter(CVProfile.parse(cv_text), {"title": "X", "company": "Y", "description": "Nextcloud"})
    assert "Nextcloud" in letter and "Gespräch" in letter


def test_parse_llm_json():
    assert parse_llm_json('Hier: {"score": 120, "reason": "Passt.", "letter": "A. B. C. D."}') == (100, "Passt.", "A. B. C. D.")
    try:
        parse_llm_json("kein json")
    except LLMError:
        pass
    else:
        raise AssertionError


def test_dashboard_renders_and_workflow(settings):
    db = Database(settings.db_path)
    run_cycle(settings, db=db, sources=_sources()[:2], notify=False)
    client = TestClient(create_app(settings, db=db))
    r = client.get("/")
    assert r.status_code == 200 and "Cloud Support Engineer" in r.text
    assert "Jetzt suchen" in r.text
    job = db.list_jobs()[0]
    r = client.get(f"/jobs/{job['id']}")
    assert r.status_code == 200 and "Kopieren" in r.text
    assert "Bewerbung öffnen" in r.text or "Jetzt manuell bewerben" in r.text
    r = client.post(f"/jobs/{job['id']}/status", data={"status": "beworben", "notes": "Gesendet per Portal"},
                    follow_redirects=False)
    assert r.status_code == 303
    j = db.get_job(job["id"])
    assert j["status"] == "beworben" and j["applied_date"] and j["notes"] == "Gesendet per Portal"
    assert client.post(f"/jobs/{job['id']}/status", data={"status": "hacked"}).status_code == 400
    r = client.post(f"/jobs/{job['id']}/regenerate", follow_redirects=False)
    assert r.status_code == 303 and db.get_job(job["id"])["letter_origin"] == "vorlage"
    assert client.get("/?status=beworben&min_score=0").text.count("/jobs/") >= 1
    csv = client.get("/export.csv")
    assert csv.status_code == 200 and "Titel" in csv.text
    x = client.get("/export.xlsx")
    assert x.status_code == 200 and x.content[:2] == b"PK"


def test_basic_auth(settings):
    settings.dashboard_user, settings.dashboard_password = "u", "p"
    client = TestClient(create_app(settings, db=Database(settings.db_path)))
    assert client.get("/").status_code == 401
    assert client.get("/", auth=("u", "wrong")).status_code == 401
    assert client.get("/", auth=("u", "p")).status_code == 200
    assert client.get("/healthz").status_code == 200


def test_cross_origin_post_rejected(settings):
    db = Database(settings.db_path)
    run_cycle(settings, db=db, sources=_sources()[:1], notify=False)
    client = TestClient(create_app(settings, db=db))
    jid = db.list_jobs()[0]["id"]
    r = client.post(f"/jobs/{jid}/status", data={"status": "absage"}, headers={"Origin": "https://evil.example"})
    assert r.status_code == 403


def test_telegram_message_format():
    from jobhunter.notify import format_message
    msg = format_message([{"id": 1, "title": "A <b>", "company": "C&D", "score": 88, "llm_reason": None}],
                         "https://jobs.example.org")
    assert "A &lt;b&gt;" in msg and "C&amp;D" in msg and "/jobs/1" in msg
