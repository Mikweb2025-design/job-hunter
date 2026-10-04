"""Editable search profile, sources and CV profile (DB overrides over config.yaml)."""
import json
import time

import httpx
import pytest
from fastapi.testclient import TestClient

from jobhunter import search_profile as sp
from jobhunter.db import Database
from jobhunter.pipeline import run_cycle
from jobhunter.sources.arbeitsagentur import ArbeitsagenturSource
from jobhunter.sources.remotive import RemotiveSource
from jobhunter.web import create_app

from .conftest import FIX, load_json, mock_client
from .test_pipeline_web import _sources

AUTH = ("u", "p")
REMOTE_IN_FIXTURE = sum(1 for i in load_json("ba_search.json")["ergebnisliste"] if i.get("homeofficemoeglich"))


@pytest.fixture(autouse=True)
def _clear_cache():
    sp.clear_preview_cache()
    yield
    sp.clear_preview_cache()


@pytest.fixture
def db(settings):
    return Database(settings.db_path)


def test_validate_cleans_and_rejects():
    clean = sp.validate_profile({"queries": [" Support  Engineer ", "support engineer", "", "Cloud"],
                                 "radius_km": 50.4, "keyword_weights": {"Linux": "2,5".replace(",", ".")}})
    assert clean["queries"] == ["Support Engineer", "Cloud"] and clean["radius_km"] == 50
    assert clean["keyword_weights"] == {"Linux": 2.5}
    for bad in ({"queries": []}, {"queries": ["x"] * 0}, {"queries": [f"q{i}" for i in range(31)]},
                {"radius_km": 500}, {"days_back": 0}, {"location": " "}, {"remote_ok": "ja"},
                {"keyword_weights": {"Linux": 11}}, {"unknown": 1}, {"min_salary": "viel"},
                {"queries": ["x" * 81]}):
        with pytest.raises(sp.ProfileError):
            sp.validate_profile(bad)
    with pytest.raises(sp.ProfileError) as e:
        sp.validate_profile({"queries": [], "radius_km": -1})
    assert set(e.value.errors) == {"queries", "radius_km"}


def test_save_merge_persist_and_reset(settings, db):
    sp.apply_overrides(settings, db)
    base_queries = list(settings.profile.queries)
    sp.save(settings, db, {"queries": ["Cloud Support", "Linux Administrator"], "radius_km": 50,
                           "location": settings.profile.location}, None)
    assert settings.profile.queries == ["Cloud Support", "Linux Administrator"]
    assert settings.profile.radius_km == 50
    assert settings.profile_base.queries == base_queries          # config.yaml untouched
    stored = db.get_setting("search_profile")
    assert "location" not in stored                                 # same as config → no override
    # a fresh process (new settings from config.yaml) sees the override from the DB
    from dataclasses import replace
    fresh = replace(settings, profile=settings.profile_base, profile_base=None, sources_base=None)
    sp.apply_overrides(fresh, db)
    assert fresh.profile.queries == ["Cloud Support", "Linux Administrator"]
    payload = sp.payload(settings, db)
    assert set(payload["overridden"]) == {"queries", "radius_km"} and payload["base"]["queries"] == base_queries
    sp.reset(settings, db, "profile")
    assert settings.profile.queries == base_queries and db.get_setting("search_profile") is None


def test_invalid_save_changes_nothing(settings, db):
    sp.apply_overrides(settings, db)
    with pytest.raises(sp.ProfileError):
        sp.save(settings, db, {"queries": ["ok"], "days_back": 999}, None)
    assert db.get_setting("search_profile") is None


def test_sources_override(settings, db):
    sp.apply_overrides(settings, db)
    sp.save(settings, db, None, {"remotive": {"enabled": True, "category": "customer-support"},
                                 "ats": {"enabled": True, "companies": [{"ats": "greenhouse", "token": "sumup"}]}})
    assert settings.sources["remotive"] == {"enabled": True, "category": "customer-support"}
    assert settings.sources["ats"]["companies"][0]["name"] == "sumup"
    ids = {s["id"]: s for s in sp.sources_payload(settings)}
    assert ids["remotive"]["enabled"] and ids["ats"]["configured"] and not ids["jobicy"]["enabled"]
    assert ids["adzuna"]["configured"] is False and "ADZUNA" in ids["adzuna"]["reason"]
    for bad in ({"nope": {}}, {"remotive": {"category": "x"}}, {"adzuna": {"app_key": "secret"}},
                {"ats": {"companies": [{"ats": "workday", "token": "x"}]}},
                {"rss": {"feeds": ["javascript:alert(1)"]}}, {"arbeitsagentur": {"max_pages": 9}}):
        with pytest.raises(sp.ProfileError):
            sp.validate_sources(bad)
    sp.reset(settings, db, "sources")
    assert "remotive" not in settings.sources


def test_cv_save_backup_and_sync(settings, db):
    old = settings.cv_path.read_text(encoding="utf-8")
    backup = sp.save_cv(settings, db, old + "\n## Neu\nLinux: 3\n")
    assert backup and (settings.data_dir / backup).read_text(encoding="utf-8") == old
    new = settings.cv_path.read_text(encoding="utf-8")
    assert "## Neu" in new and db.get_setting("cv_profile")["text"] == new
    with pytest.raises(sp.ProfileError):
        sp.save_cv(settings, db, "   ")
    # deploy put the old (unchanged) file back? → UI version wins
    settings.cv_path.write_text(old, encoding="utf-8")
    db.set_setting("cv_profile", {**db.get_setting("cv_profile"), "file_sha": sp._sha(old)})
    assert sp.sync_cv_on_start(settings, db) == "db"
    assert "## Neu" in settings.cv_path.read_text(encoding="utf-8")
    # file changed by someone else (new repo version) → file wins, UI version kept as backup
    settings.cv_path.write_text("# Ganz neu\n", encoding="utf-8")
    assert sp.sync_cv_on_start(settings, db) == "file"
    assert settings.cv_path.read_text(encoding="utf-8") == "# Ganz neu\n"
    assert list(settings.data_dir.glob("cv_profile.ui-*.md"))
    assert sp.sync_cv_on_start(settings, db) == "same"


def test_suggestions_from_cv_and_liked_jobs(settings, db):
    settings.cv_path.write_text(settings.cv_path.read_text(encoding="utf-8")
                                + "\n## Zielrollen\nCloud Support Engineer, Application Support, Berlin oder remote.\n## X\n",
                                encoding="utf-8")
    run_cycle(settings, db=db, sources=_sources()[:2], notify=False)
    job = db.list_jobs()[0]
    db.update_job(job["id"], status="interessant")
    sp.apply_overrides(settings, db)
    s = sp.suggestions(settings, db)
    qs = {x["value"]: x for x in s["queries"]}
    assert "Cloud Support Engineer" in qs and "Zielrolle" in qs["Cloud Support Engineer"]["reason"]
    assert "Linux Administrator" in qs and "Linux" in qs["Linux Administrator"]["reason"]
    assert "Support Engineer" not in qs                     # already a query
    assert s["liked_jobs"] == 1 and any("markiert" in x["reason"] for x in s["queries"] + s["titles"])
    assert all(x["kind"] == "title" for x in s["titles"])
    assert sp.clean_title("Senior Technical Support Engineer (m/w/d) - Cloud") == "Technical Support Engineer"


def _ba_handler(calls):
    def handler(req):
        calls.append(dict(req.url.params))
        return httpx.Response(200, json=load_json("ba_search.json"))
    return handler


def test_preview_counts_without_saving(settings, db):
    sp.apply_overrides(settings, db)
    calls = []
    remotive_json = json.loads((FIX / "sources" / "remotive.json").read_text(encoding="utf-8"))

    def make(name, opts):
        if name == "arbeitsagentur":
            return ArbeitsagenturSource(opts, client=mock_client(_ba_handler(calls)))
        if name == "remotive":
            return RemotiveSource(opts, client=mock_client(lambda r: httpx.Response(200, json=remotive_json)))
        raise AssertionError(name)

    before = db.list_jobs()
    r = sp.preview(settings, db, {"queries": ["Support Engineer", "AI Engineer"]}, {"remotive": {"enabled": True}},
                   make_source=make)
    assert db.list_jobs() == before and db.get_setting("search_profile") is None   # nothing stored
    assert [q["query"] for q in r["queries"]] == ["Support Engineer", "AI Engineer"]
    q = r["queries"][0]
    # remote = postings with homeofficemoeglich among the nationwide hits (fixture: 1 of 3)
    assert q["arbeitsagentur"]["local"] == 105 and q["arbeitsagentur"]["remote"] == REMOTE_IN_FIXTURE
    assert q["arbeitsagentur"]["new_in_page"] == 3 and len(q["samples"]) == 3
    assert r["queries"][1]["feeds"]["remotive"] == 2
    assert {s["id"]: s["matching"] for s in r["sources"]}["remotive"] >= 2
    assert len(calls) == 4 and calls[0]["was"] == "Support Engineer" and "wo" not in calls[1] and calls[1]["size"] == "100"
    assert not r["cached"]
    # cached: no new requests
    r2 = sp.preview(settings, db, {"queries": ["Support Engineer", "AI Engineer"]}, {"remotive": {"enabled": True}},
                    make_source=make)
    assert len(calls) == 4 and r2["cached"]
    # existing jobs are not "new"
    run_cycle(settings, db=db, sources=_sources()[:1], notify=False)
    sp.clear_preview_cache()
    r3 = sp.preview(settings, db, {"queries": ["Support Engineer"]}, make_source=make)
    assert r3["queries"][0]["arbeitsagentur"]["new_in_page"] == 0


def test_preview_only_one_at_a_time(settings, db):
    sp.apply_overrides(settings, db)
    assert sp._preview_lock.acquire(blocking=False)
    try:
        with pytest.raises(sp.PreviewBusy):
            sp.preview(settings, db, make_source=lambda n, o: None)
    finally:
        sp._preview_lock.release()


@pytest.fixture
def client(settings):
    settings.dashboard_user, settings.dashboard_password = AUTH
    db = Database(settings.db_path)
    run_cycle(settings, db=db, sources=_sources()[:2], notify=False)
    c = TestClient(create_app(settings, db=db))
    c.auth = AUTH
    return c, db, settings


def _wait_rescore():
    for _ in range(100):
        if not sp.rescore_status()["busy"]:
            return
        time.sleep(0.05)


def test_api_search_profile_roundtrip(client, monkeypatch):
    c, db, settings = client
    started = []
    monkeypatch.setattr("jobhunter.actions.start_run", lambda s: started.append(1) or True)
    r = c.get("/api/v1/search-profile")
    assert r.status_code == 200 and r.json()["profile"]["queries"] == ["Support Engineer"]
    assert {s["id"] for s in r.json()["sources"]} >= {"arbeitsagentur", "arbeitnow", "ats", "remotive"}
    r = c.put("/api/v1/search-profile", json={"profile": {"queries": ["Cloud Support"], "min_salary": 50000},
                                              "sources": {"jobicy": {"enabled": True}}, "run_now": True})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["profile"]["queries"] == ["Cloud Support"] and body["run_started"] and started
    assert body["rescore_started"] in (True, False) and set(body["overridden"]) == {"queries", "min_salary"}
    _wait_rescore()
    assert settings.profile.min_salary == 50000
    r = c.put("/api/v1/search-profile", json={"profile": {"queries": []}})
    assert r.status_code == 422 and "queries" in r.json()["errors"]
    assert c.put("/api/v1/search-profile", content="x", headers={"content-type": "text/plain"}).status_code == 415
    r = c.post("/api/v1/search-profile/reset", json={"what": "all"})
    assert r.status_code == 200 and r.json()["profile"]["queries"] == ["Support Engineer"] and r.json()["overridden"] == []
    _wait_rescore()
    assert TestClient(c.app).get("/api/v1/search-profile").status_code == 401


def test_api_cv_profile_and_rescore(client):
    c, db, settings = client
    r = c.get("/api/v1/cv-profile")
    assert r.status_code == 200 and "Nextcloud" in r.json()["text"] and "wahre" in r.json()["warning"]
    r = c.put("/api/v1/cv-profile", json={"text": r.json()["text"] + "\nKubernetes: 5\n", "rescore": True})
    assert r.status_code == 200 and r.json()["backup"].startswith("cv_profile.backup-")
    _wait_rescore()
    assert c.put("/api/v1/cv-profile", json={"text": ""}).status_code == 422
    r = c.post("/api/v1/rescore", json={})
    assert r.status_code == 202
    _wait_rescore()
    assert c.get("/api/v1/rescore").json()["done"] == len(db.list_jobs())


def test_api_suggestions_and_preview(client, monkeypatch):
    c, db, settings = client
    r = c.get("/api/v1/search-profile/suggestions")
    assert r.status_code == 200 and r.json()["queries"]
    monkeypatch.setattr(sp, "preview", lambda *a, **k: {"queries": [], "sources": [], "cached": False})
    assert c.post("/api/v1/search-profile/preview", json={"profile": {"queries": ["X"]}}).status_code == 200

    def busy(*a, **k):
        raise sp.PreviewBusy("läuft")
    monkeypatch.setattr(sp, "preview", busy)
    assert c.post("/api/v1/search-profile/preview", json={}).status_code == 429


def test_profile_page_renders(client):
    c, _, _ = client
    r = c.get("/profile")
    assert r.status_code == 200 and "Suchprofil" in r.text and "Speichern + Jetzt suchen" in r.text
    assert "/profile" in c.get("/").text  # nav link


def test_sources_override_stores_only_differences(settings, db):
    settings.sources = {"arbeitsagentur": {"enabled": True, "max_pages": 2}}
    sp.apply_overrides(settings, db)
    sp.save(settings, db, None, {"arbeitsagentur": {"enabled": True, "max_pages": 2, "remote_search": True},
                                 "jobicy": {"enabled": False, "geo": "germany"},
                                 "remotive": {"enabled": True, "category": ""}})
    assert db.get_setting("sources") == {"remotive": {"enabled": True}}
    assert settings.sources["arbeitsagentur"]["max_pages"] == 2 and settings.sources["remotive"]["enabled"]
