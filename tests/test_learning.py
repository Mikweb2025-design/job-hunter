from datetime import date

from jobhunter import learning
from jobhunter.learning import OutcomeModel, features, is_agency, outcome
from jobhunter.models import JobPosting
from jobhunter.notify import format_message
from jobhunter.scoring import CVProfile, score_job
from jobhunter.views import freshness_bonus, filter_view


def j(title, status="beworben", company="Firma GmbH", reply=None, close=None, remote=0, applied="2026-10-01",
      description=""):
    return {"title": title, "status": status, "company": company, "reply_kind": reply, "close_reason": close,
            "remote": remote, "applied_date": applied, "description": description}


def test_outcomes():
    assert outcome(j("A", "gespraech")) == 1
    assert outcome(j("A", reply="unterlagen")) == 1
    assert outcome(j("A", reply="eingang")) is None          # only an acknowledgement
    assert outcome(j("A")) is None                           # no answer yet
    assert outcome(j("A", "absage")) == -1
    assert outcome(j("A", "absage", close="absage_firma", reply="rueckfrage")) == -1  # final word counts
    assert outcome(j("A", "absage", close="kein_interesse")) is None
    assert outcome(j("A", "absage", applied=None)) is None   # rejected by the user before applying
    assert outcome(j("A", "neu")) is None


def test_agency_detection_and_features():
    assert is_agency("puro Personaldienstleistung GmbH")
    assert is_agency("Acme", "Für unseren Kunden in Berlin suchen wir …")
    assert not is_agency("SysEleven GmbH", "Wir betreiben eine Cloud-Plattform")
    f = features(j("Cloud Support Engineer (m/w/d)", company="SysEleven GmbH"))
    assert {"t:cloud", "t:support", "t:engineer", "direct", "onsite"} <= f
    assert "t:m" not in f and "t:w" not in f


def test_model_learns_from_outcomes():
    jobs = [
        j("Cloud Support Engineer", "gespraech"),
        j("IT Support Specialist", "gespraech"),
        j("Support Mitarbeiter", "absage", company="puro Personaldienstleistung GmbH"),
        j("IT Administrator", "absage", company="digatus personal GmbH"),
        j("IT Administrator", "absage", company="Zeitarbeit Nord GmbH"),
        j("Noch offen"),
    ]
    m = OutcomeModel.build(jobs)
    assert m.samples == 5
    assert m.weights["agency"] < 0 < m.weights["direct"]
    good, why = m.score(j("Cloud Support Engineer", "neu", company="Hosting AG"))
    bad, _ = m.score(j("IT Administrator", "neu", company="Personalservice Berlin GmbH"))
    assert good > 0 > bad
    assert -learning.MAX_LEARNED <= bad and good <= learning.MAX_LEARNED
    assert any("✓" in r for r in why)
    assert m.score(j("Koch", "neu", remote=1, company="Personal Partner GmbH"))[0] < 0  # agency known as bad
    assert OutcomeModel().score(j("Koch", "neu")) == (0.0, [])  # no data yet: no effect
    koch, _ = m.score(j("Koch", "neu", remote=1))  # only "direkt" known -> small bonus
    assert koch > 0


def test_score_job_uses_active_model(profile, cv_text):
    cv = CVProfile.parse(cv_text)
    p = JobPosting(source="t", source_id="1", title="IT Administrator", company="Personal Partner GmbH",
                   location="10115 Berlin", description="")
    before = score_job(p, profile, cv)
    assert before.breakdown["learned"] == 0
    learning._ACTIVE = OutcomeModel.build([j("IT Administrator", "absage", company="digatus personal GmbH"),
                                           j("IT Administrator", "absage", company="puro Personalservice"),
                                           j("Cloud Support", "gespraech", company="Hosting AG"),
                                           j("Cloud Support", "gespraech", company="Cloud SE")])
    after = score_job(p, profile, cv)
    assert after.breakdown["learned"] < 0 and after.score < before.score
    assert after.breakdown["learned_reasons"]


def test_freshness_bonus_and_today_order():
    today = date(2026, 10, 18)
    assert freshness_bonus({"published": "2026-10-17"}, today) == 10
    assert freshness_bonus({"published": "2026-10-12"}, today) == 5
    assert freshness_bonus({"published": "2026-10-05"}, today) == 0
    assert freshness_bonus({"published": "2026-09-30"}, today) == -5
    assert freshness_bonus({"published": "2026-08-01"}, today) == -10
    assert freshness_bonus({"fetched_at": "2026-10-16T06:30:00+00:00"}, today) == 10
    assert freshness_bonus({}, today) == 0
    jobs = [{"view": "manual", "score": 70, "published": "2026-08-20", "fetched_at": "a", "id": 1},
            {"view": "manual", "score": 64, "published": "2026-10-17", "fetched_at": "b", "id": 2}]
    assert [x["id"] for x in filter_view(jobs, "today", today=today)] == [2, 1]  # 74 beats 60


def test_telegram_message_lists_follow_ups():
    msg = format_message([], "https://x/jobs", [{"title": "Cloud Support", "company": "ACME"}])
    assert "Nachfassen fällig: 1" in msg and "Cloud Support – ACME" in msg and "/tracker" in msg
    assert "neue Top-Treffer" not in msg
