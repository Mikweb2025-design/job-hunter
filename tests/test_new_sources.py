"""New feed sources (recorded responses, no network)."""
import json

import httpx

from jobhunter.config import SearchProfile
from jobhunter.sources import REGISTRY, build_sources
from jobhunter.sources import arbeitnow, ats, berlinstartupjobs, jobicy, remotive
from jobhunter.sources.base import place_ok, remote_geo_ok, title_matches

from .conftest import FIX, mock_client

SRC = FIX / "sources"


def _json(name):
    return json.loads((SRC / name).read_text(encoding="utf-8"))


def _profile(**kw):
    base = dict(queries=["Support"], location="Berlin", remote_ok=True,
                target_titles=["Platform Engineer", "Customer Support Agent"])
    base.update(kw)
    return SearchProfile(**base)


def test_title_matching_and_geo():
    assert title_matches("Technical Support Engineer (m/w/d)", ["Support Engineer"]) == "Support Engineer"
    assert title_matches("Support-Engineer", ["Support Engineer"])
    assert title_matches("Supporter IT", ["Support"]) == "Support"
    assert title_matches("Backend Developer", ["Support Engineer", "DevOps"]) is None
    assert remote_geo_ok("Worldwide") and remote_geo_ok("Europe") and remote_geo_ok("Germany") and remote_geo_ok("")
    assert not remote_geo_ok("USA") and not remote_geo_ok("USA, Canada, Argentina")
    p = _profile(extra_locations=["Potsdam"])
    assert place_ok("10115 Berlin", False, p) and place_ok("Potsdam", False, p)
    assert not place_ok("München", False, p) and place_ok("München", True, p)


def test_new_sources_registered_and_opt_in():
    for name in ("arbeitnow", "remotive", "jobicy", "berlinstartupjobs", "ats"):
        assert name in REGISTRY
    names = [s.name for s in build_sources({"arbeitnow": {}, "remotive": {"enabled": True}})]
    assert "remotive" in names and "arbeitnow" not in names and "arbeitsagentur" in names


def test_arbeitnow_parse_and_filter():
    jobs = arbeitnow.parse_response(_json("arbeitnow.json"))
    assert len(jobs) == 11 and all(j.source == "arbeitnow" for j in jobs)
    j = jobs[0]
    assert j.location == "Berlin" and j.url.startswith("https://www.arbeitnow.com/") and j.published[:2] == "20"
    assert "<p>" not in j.description
    src = arbeitnow.ArbeitnowSource({}, client=mock_client(lambda r: httpx.Response(200, json=_json("arbeitnow.json"))))
    kept = src.fetch(_profile(queries=["Support"], target_titles=["IT Architect"]))
    titles = {k.title for k in kept}
    # Berlin support job + remote IT architect; London jobs and unrelated titles dropped
    assert titles == {"Commercial Support Associate", "Senior IT Architect (m/w/d)"}


def test_remotive_keeps_europe_open_matching_titles():
    jobs = remotive.parse_response(_json("remotive.json"))
    assert all(j.remote and j.source == "remotive" for j in jobs)
    calls = []

    def handler(req):
        calls.append(str(req.url))
        return httpx.Response(200, json=_json("remotive.json"))
    src = remotive.RemotiveSource({}, client=mock_client(handler))
    kept = src.fetch(_profile(queries=["AI Engineer"], target_titles=[]))
    assert len(calls) == 1  # one request per run (Remotive terms)
    assert {k.title for k in kept} == {"Senior AI Engineer", "Senior Independent AI Engineer / Architect"}
    assert src.fetch(_profile(queries=["AI Engineer"], remote_ok=False)) == []
    # USA-only jobs are dropped even when the title matches
    assert not [k for k in src.fetch(_profile(queries=["Content Reviewer"]))]


def test_jobicy_parse_and_filter():
    src = jobicy.JobicySource({}, client=mock_client(lambda r: httpx.Response(200, json=_json("jobicy.json"))))
    kept = src.fetch(_profile(queries=["Platform Engineer"], target_titles=[]))
    assert [k.title for k in kept] == ["Platform Engineer"]
    assert kept[0].location == "Remote (Anywhere)" and kept[0].description


def test_berlinstartupjobs_feed():
    jobs = berlinstartupjobs.parse((SRC / "berlinstartupjobs.xml").read_bytes())
    assert len(jobs) == 12 and all(j.source == "berlinstartupjobs" and j.location == "Berlin" for j in jobs)
    dt = [j for j in jobs if j.company == "DATATRONiQ"]
    assert dt and dt[0].title.startswith("Cloud & DevOps Engineer")
    src = berlinstartupjobs.BerlinStartupJobsSource(
        {"feeds": ["https://berlinstartupjobs.com/engineering/feed/"]},
        client=mock_client(lambda r: httpx.Response(200, content=(SRC / "berlinstartupjobs.xml").read_bytes())))
    assert [k.company for k in src.fetch(_profile(queries=["DevOps Engineer"], target_titles=[]))] == ["DATATRONiQ"]


def test_ats_parsers():
    gh = ats.parse_greenhouse(_json("greenhouse.json"), "SumUp")
    assert gh[0].company == "SumUp" and gh[0].location == "Berlin, Germany" and gh[0].source == "greenhouse"
    with_text = [j for j in gh if j.description]
    assert with_text and "jobs@sumup.example" in with_text[0].description and "<p>" not in with_text[0].description
    lv = ats.parse_lever(_json("lever.json"), "Spotify")
    assert lv[0].title == "Android Engineer - Experience" and lv[0].url.startswith("https://jobs.lever.co/")
    assert lv[3].remote and lv[0].published.startswith("20")
    ps = ats.parse_personio((SRC / "personio.xml").read_bytes(), "ottonova", "ottonova")
    assert ps[0].location == "München, Köln" and "Solvency" in ps[0].description
    assert ps[0].url.startswith("https://ottonova.jobs.personio.de/job/") and ps[0].published == "2026-03-23"
    sr = ats.parse_smartrecruiters_list(_json("smartrecruiters.json"), "DeliveryHero", "Delivery Hero")
    assert sr[0].company == "Delivery Hero" and sr[0].extra["detail"].endswith(sr[0].source_id)
    job = ats.apply_smartrecruiters_detail(sr[0], {"jobAd": {"sections": {"jobDescription": {
        "title": "Aufgaben", "text": "<p>Kunden helfen</p>"}}}, "postingUrl": "https://jobs.smartrecruiters.com/x"})
    assert "Kunden helfen" in job.description and job.url == "https://jobs.smartrecruiters.com/x"


def test_ats_source_filters_and_survives_broken_company():
    def handler(req):
        if "greenhouse" in req.url.host:
            return httpx.Response(200, json=_json("greenhouse.json"))
        return httpx.Response(404, json={"ok": False})
    src = ats.ATSSource({"companies": [{"ats": "greenhouse", "token": "sumup", "name": "SumUp"},
                                       {"ats": "lever", "token": "nobody", "name": "Nobody"},
                                       {"ats": "personio", "token": "bad token!"}]},
                        client=mock_client(handler))
    assert [c["token"] for c in src.companies()] == ["sumup", "nobody"]  # invalid token ignored
    kept = src.fetch(_profile(queries=["Customer Support"], target_titles=[]))
    assert {k.location for k in kept} == {"Berlin, Germany"} and len(kept) == 2
    assert ats.ATSSource({}).is_configured()[0] is False


def test_ats_personio_unknown_company_redirect_is_error():
    def handler(req):
        if req.url.host.endswith("jobs.personio.de"):
            return httpx.Response(307, headers={"location": "https://personio.com/"})
        return httpx.Response(429, text="<html>checkpoint</html>")
    client = httpx.Client(transport=httpx.MockTransport(handler), follow_redirects=True)
    src = ats.ATSSource({"companies": [{"ats": "personio", "token": "nope"}]}, client=client)
    jobs, errors = src.fetch_all()
    assert jobs == [] and "nicht gefunden" in errors[0]


def test_arbeitsagentur_remote_search_keeps_home_office_only():
    from jobhunter.sources.arbeitsagentur import ArbeitsagenturSource
    from .conftest import load_json
    calls = []

    def handler(req):
        calls.append(dict(req.url.params))
        return httpx.Response(200, json=load_json("ba_search.json"))
    src = ArbeitsagenturSource({"max_pages": 1}, client=mock_client(handler))
    jobs = src.fetch(_profile(queries=["Support Engineer"]))
    assert "arbeitszeit" not in calls[1] and "wo" not in calls[1]   # v6: nationwide + local filter
    n_remote = sum(1 for i in load_json("ba_search.json")["ergebnisliste"] if i.get("homeofficemoeglich"))
    assert len(jobs) == 3 + n_remote


def test_portal_jobs_are_always_manual(tmp_path):
    from jobhunter.db import Database
    from jobhunter.models import JobPosting
    db = Database(tmp_path / "t.db")
    text = "Bewerbung bitte an jobs@firma.example. Fragen zur Barrierefreiheit: candidate.exp@firma.example"
    a = db.insert_job(JobPosting(source="greenhouse", source_id="1", title="SRE", company="X", description=text), 50, {})
    b = db.insert_job(JobPosting(source="arbeitnow", source_id="2", title="SRE2", company="Y", description=text), 50, {})
    assert db.get_job(a)["apply_method"] == "manual" and db.get_job(a)["apply_email"] is None
    assert db.get_job(b)["apply_method"] == "email"
    db.backfill_apply_email(overwrite=True)
    assert db.get_job(a)["apply_method"] == "manual"
