from jobhunter.models import JobPosting
from jobhunter.scoring import CVProfile, combined_score, find_keywords, score_job


def job(**kw):
    base = dict(source="t", source_id="1", title="Support Engineer (m/w/d)", company="X",
                location="10115 Berlin", description="")
    base.update(kw)
    return JobPosting(**base)


def test_cv_profile_parsing(cv_text):
    cv = CVProfile.parse(cv_text, {"MCP": 3})
    assert cv.keywords["Nextcloud"] == 4
    assert cv.keywords["Support"] == 1.0
    assert cv.keywords["Ticket"] == 1.0
    assert cv.keywords["MCP"] == 3
    assert not any("comment" in k for k in cv.keywords)
    assert len(cv.results) == 2 and "Nextcloud" in cv.results[0]


def test_keyword_boundaries():
    assert find_keywords("Erfahrung mit S3 und C++", ["S3", "C++", "C"]) == ["S3", "C++"]
    assert find_keywords("Ticketsystem", ["Ticket"]) == []
    assert find_keywords("PYTHON, docker", ["Python", "Docker"]) == ["Python", "Docker"]


def test_strong_match_scores_high(profile, cv_text):
    cv = CVProfile.parse(cv_text)
    j = job(description="Nextcloud, Linux, Python, Docker, S3, SQL, Tickets im Support", salary_max=55000)
    r = score_job(j, profile, cv)
    assert r.breakdown["keywords"] == 40
    assert r.breakdown["title"] == 25
    assert r.breakdown["location"] == 15
    assert r.breakdown["salary"] == 20
    assert r.score == 100


def test_unknown_salary_is_neutral(profile, cv_text):
    cv = CVProfile.parse(cv_text)
    r = score_job(job(), profile, cv)
    assert r.breakdown["salary"] == 10
    assert r.breakdown["salary_reason"] == "unbekannt"


def test_low_salary_and_predicted_salary(profile, cv_text):
    cv = CVProfile.parse(cv_text)
    assert score_job(job(salary_min=30000, salary_max=36000), profile, cv).breakdown["salary"] == 0
    assert score_job(job(salary_max=41000), profile, cv).breakdown["salary"] == 5  # within 10%
    predicted = score_job(job(salary_max=30000, salary_predicted=True), profile, cv)
    assert predicted.breakdown["salary"] == 10


def test_location_and_remote(profile, cv_text):
    cv = CVProfile.parse(cv_text)
    assert score_job(job(location="80331 München"), profile, cv).breakdown["location"] == 0
    assert score_job(job(location="80331 München", remote=True), profile, cv).breakdown["location"] == 15
    profile.remote_ok = False
    assert score_job(job(location="80331 München", remote=True), profile, cv).breakdown["location"] == 0
    assert score_job(job(location=""), profile, cv).breakdown["location_reason"] == "unbekannt"


def test_excluded_title_forces_zero(profile, cv_text):
    cv = CVProfile.parse(cv_text)
    r = score_job(job(title="Werkstudent Support (m/w/d)", description="Nextcloud Linux Python"), profile, cv)
    assert r.score == 0 and r.excluded and r.breakdown["excluded"] == ["Werkstudent"]


def test_excluded_keyword_in_text_penalises(profile, cv_text):
    cv = CVProfile.parse(cv_text)
    clean = score_job(job(description="Linux Support"), profile, cv)
    dirty = score_job(job(description="Linux Support über Zeitarbeit"), profile, cv)
    assert dirty.score == clean.score - 10
    assert dirty.breakdown["excluded_in_text"] == ["Zeitarbeit"]


def test_title_partial_match(profile, cv_text):
    cv = CVProfile.parse(cv_text)
    full = score_job(job(title="Senior Technical Account Manager (m/w/d)"), profile, cv)
    partial = score_job(job(title="Account Manager Vertrieb"), profile, cv)
    none = score_job(job(title="Buchhalter"), profile, cv)
    assert full.breakdown["title"] == 25
    assert 0 < partial.breakdown["title"] < 25
    assert none.breakdown["title"] == 0


def test_score_bounds(profile, cv_text):
    cv = CVProfile.parse(cv_text)
    r = score_job(job(title="Buchhalter", location="Hamburg", salary_max=20000,
                      description="Zeitarbeit"), profile, cv)
    assert 0 <= r.score <= 100


def test_combined_score():
    assert combined_score(60, None) == 60
    assert combined_score(60, 90) == 75
