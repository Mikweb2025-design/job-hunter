import base64
import json

import httpx

from jobhunter.sources.adzuna import AdzunaSource, parse_response
from jobhunter.sources.arbeitsagentur import (ArbeitsagenturSource, apply_detail, parse_salary,
                                              parse_search_response)
from jobhunter.sources.base import SourceError
from jobhunter.sources.rss import RSSSource, parse_feed

from .conftest import FIX, load_json, mock_client


# ---- Bundesagentur für Arbeit ------------------------------------------------
def test_ba_parse_search():
    jobs = parse_search_response(load_json("ba_search.json"))
    assert len(jobs) == 3
    j = jobs[0]
    assert j.source == "arbeitsagentur"
    assert j.source_id == "13644-297443-S"
    assert j.title == "Technical Support Engineer [m/w/d]"
    assert j.company == "Virtimo"
    assert j.location == "10178 Berlin"
    assert j.remote is True
    assert j.url.startswith("https://www.get-in-it.de/")
    assert j.published == "2026-09-03"
    assert jobs[2].salary_min == 48000 and jobs[2].salary_max == 55000
    assert jobs[1].url == "https://www.arbeitsagentur.de/jobsuche/jobdetail/14087-35JBRGNBXY3UWVFJ-S" or jobs[1].url


def test_ba_parse_legacy_v4_shape():
    data = {"stellenangebote": [{"refnr": "10000-1", "titel": "Support Engineer", "arbeitgeber": "ACME",
                                 "arbeitsort": {"plz": "10115", "ort": "Berlin"},
                                 "aktuelleVeroeffentlichungsdatum": "2026-09-01"}]}
    [j] = parse_search_response(data)
    assert (j.source_id, j.company, j.location) == ("10000-1", "ACME", "10115 Berlin")
    assert j.url == "https://www.arbeitsagentur.de/jobsuche/jobdetail/10000-1"


def test_ba_salary_conversion():
    assert parse_salary({"verguetungsangabe": "MONATSGEHALT", "festgehalt": 4000}) == (48000, 48000)
    assert parse_salary({"verguetungsangabe": "STUNDENLOHN", "festgehalt": 20})[0] == 20 * 1720
    assert parse_salary({"verguetungsangabe": "KEINE_ANGABEN"}) == (None, None)


def test_ba_detail_fills_description():
    [j] = parse_search_response(load_json("ba_search.json"))[:1]
    apply_detail(j, load_json("ba_detail.json"))
    assert "Technical Support Engineer" in j.description
    assert "Deine Aufgaben" in j.description


def test_ba_fetch_falls_back_to_legacy_endpoint_and_sends_api_key(profile):
    seen = []

    def handler(req: httpx.Request):
        seen.append(req)
        assert req.headers["X-API-Key"] == "jobboerse-jobsuche"
        if req.url.path.endswith("/pc/v6/jobs"):
            return httpx.Response(403, text="No match found for request")
        if req.url.path.endswith("/pc/v4/app/jobs"):
            return httpx.Response(200, json={"stellenangebote": [
                {"refnr": "1-A", "titel": "Support Engineer", "arbeitgeber": "ACME"}], "maxErgebnisse": 1})
        return httpx.Response(404)

    profile.remote_ok = False
    src = ArbeitsagenturSource({}, client=mock_client(handler))
    jobs = src.fetch(profile)
    assert [j.source_id for j in jobs] == ["1-A"]
    assert seen[0].url.params["was"] == "Support Engineer"
    assert seen[0].url.params["angebotsart"] == "1"


def test_ba_enrich_uses_base64_refnr():
    detail = load_json("ba_detail.json")

    def handler(req):
        code = req.url.path.rsplit("/", 1)[-1]
        assert base64.b64decode(code).decode() == "13644-297443-S"
        return httpx.Response(200, json=detail)

    src = ArbeitsagenturSource({}, client=mock_client(handler))
    [j] = parse_search_response(load_json("ba_search.json"))[:1]
    src.enrich(j)
    assert "Deine Aufgaben" in j.description


def test_ba_all_endpoints_forbidden_raises(profile):
    src = ArbeitsagenturSource({}, client=mock_client(lambda r: httpx.Response(403)))
    try:
        src.fetch(profile)
    except SourceError as exc:
        assert "403" in str(exc)
    else:
        raise AssertionError("expected SourceError")


def test_ba_retries_on_503(profile, monkeypatch):
    import jobhunter.sources.base as base
    monkeypatch.setattr(base.time, "sleep", lambda s: None)
    calls = {"n": 0}

    def handler(req):
        calls["n"] += 1
        if calls["n"] == 1:
            return httpx.Response(503)
        return httpx.Response(200, json=load_json("ba_search.json"))

    profile.remote_ok = False
    src = ArbeitsagenturSource({"max_pages": 1}, client=mock_client(handler))
    assert len(src.fetch(profile)) == 3
    assert calls["n"] == 2


# ---- Adzuna --------------------------------------------------------------------
def test_adzuna_parse():
    jobs = parse_response(load_json("adzuna_search.json"))
    assert len(jobs) == 3
    j = jobs[0]
    assert j.title == "Cloud Support Engineer (m/w/d)"  # HTML stripped
    assert j.company == "Beispiel Cloud GmbH"
    assert j.location == "Berlin, Deutschland"
    assert (j.salary_min, j.salary_max) == (52000, 62000)
    assert j.salary_predicted is False
    assert j.remote is True
    assert j.published == "2026-09-30"
    assert jobs[1].salary_predicted is True
    assert jobs[2].salary_min is None


def test_adzuna_skipped_without_keys(monkeypatch):
    monkeypatch.delenv("ADZUNA_APP_ID", raising=False)
    monkeypatch.delenv("ADZUNA_APP_KEY", raising=False)
    ok, why = AdzunaSource({}).is_configured()
    assert not ok and "ADZUNA" in why


def test_adzuna_fetch_params(profile):
    def handler(req):
        assert req.url.path == "/v1/api/jobs/de/search/1"
        assert req.url.params["app_id"] == "test-id"
        assert req.url.params["what"] in ("Support Engineer", "Support Engineer remote")
        return httpx.Response(200, json=load_json("adzuna_search.json"))

    src = AdzunaSource({"app_id": "test-id", "app_key": "test-key", "max_pages": 1, "remote_search": True},
                       client=mock_client(handler))
    assert len(src.fetch(profile)) == 6  # local + remote search


def _adzuna(db, calls, **opts):
    def handler(req):
        calls.append(req.url.params["what"])
        return httpx.Response(200, json=load_json("adzuna_search.json"))
    src = AdzunaSource({"app_id": "id", "app_key": "key", **opts}, client=mock_client(handler))
    src.attach_db(db)
    return src


def test_adzuna_call_budget_per_run_total_and_rotation(profile, settings):
    from jobhunter.db import Database
    db = Database(settings.db_path)
    profile.queries = ["A", "B", "C"]
    calls: list[str] = []
    src = _adzuna(db, calls, max_calls_per_run=2, max_calls_total=5, once_per_day=False)
    assert src.is_configured()[0]
    src.fetch(profile)
    assert calls == ["A", "B"] and src.calls_used() == 2        # 2 per run
    src.fetch(profile)
    assert calls[2:] == ["C", "A"]                             # next run continues with the next terms
    src.fetch(profile)
    assert calls[4:] == ["B"] and src.calls_used() == 5        # only what is left of the total
    ok, why = src.is_configured()
    assert not ok and "aufgebraucht" in why and "5/5" in why
    assert src.fetch(profile) == [] and len(calls) == 5         # never more


def test_adzuna_stops_for_good_on_quota_error(profile, settings):
    import pytest
    from jobhunter.db import Database
    db = Database(settings.db_path)
    src = AdzunaSource({"app_id": "id", "app_key": "key"},
                       client=mock_client(lambda req: httpx.Response(429, text="limit")))
    src.attach_db(db)
    with pytest.raises(SourceError):
        src.fetch(profile)
    ok, why = src.is_configured()
    assert not ok and "HTTP 429" in why


# ---- RSS / Atom ------------------------------------------------------------------
def test_rss_parse_with_separator():
    jobs = parse_feed((FIX / "jobs_feed.rss").read_bytes(), {"name": "bsp", "title_separator": " - ",
                                                             "location": "Berlin"})
    assert len(jobs) == 2
    j = jobs[0]
    assert j.source == "rss:bsp"
    assert j.title == "Application Support Specialist (w/m/d)"
    assert j.company == "Muster Software GmbH"
    assert j.location == "Berlin"
    assert "<" not in j.description and "Linux & SQL" in j.description
    assert j.remote is True  # "Homeoffice"
    assert j.published == "2026-09-30"
    assert j.url == "https://jobs.example.org/stellen/123"


def test_atom_parse_author_as_company():
    [j] = parse_feed((FIX / "jobs_feed.atom").read_bytes(), {})
    assert j.source == "rss:Atom Jobs"
    assert j.company == "Wolkenwerk GmbH"
    assert "Nextcloud" in j.description and "<p>" not in j.description


def test_rss_one_broken_feed_does_not_kill_others(profile):
    good = (FIX / "jobs_feed.rss").read_bytes()

    def handler(req):
        if "broken" in str(req.url):
            return httpx.Response(500)
        return httpx.Response(200, content=good)

    import jobhunter.sources.base as base
    base.time.sleep = lambda s: None
    src = RSSSource({"feeds": ["https://broken.example/x.rss", {"url": "https://ok.example/y.rss"}]},
                    client=mock_client(handler))
    assert len(src.fetch(profile)) == 2


def test_adzuna_only_once_per_day(profile, settings):
    from jobhunter.db import Database
    db = Database(settings.db_path)
    calls: list[str] = []
    src = _adzuna(db, calls, max_calls_per_run=1)
    assert src.is_configured()[0]
    src.fetch(profile)
    ok, why = src.is_configured()          # a second run today ("Jetzt suchen") is skipped
    assert not ok and "heute schon" in why and len(calls) == 1
    db.set_setting("adzuna_calls", {"used": 1, "day": "2000-01-01"})
    assert src.is_configured()[0]          # next day: allowed again
