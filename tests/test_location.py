"""Relocation filter: auto-send only Berlin/Brandenburg or explicit 100% remote."""
import pytest

from jobhunter.config import SendConfig
from jobhunter.db import Database
from jobhunter.location import in_home_region, is_full_remote, location_ok


@pytest.fixture
def env(settings):
    settings.send = SendConfig(mode="auto", dry_run=False)
    return settings, Database(settings.db_path)


def J(location="", title="Support Engineer", description="", remote=False):
    return {"title": title, "company": "Acme", "location": location,
            "description": description, "remote": remote}


def test_berlin_qualifies():
    for loc in ("Berlin", "10115 Berlin", "12489 Berlin", "Berlin, DE, 10557",
                "München, Berlin", "13353 Berlin"):
        assert in_home_region(J(loc)), loc
        assert location_ok(J(loc))[0]


def test_brandenburg_qualifies():
    for loc in ("14467 Potsdam", "03046 Cottbus", "Brandenburg an der Havel",
                "15230 Frankfurt (Oder)", "16515 Oranienburg", "14612 Falkensee"):
        assert in_home_region(J(loc)), loc


def test_rest_of_germany_does_not():
    for loc in ("24114 Kiel", "51063 Köln", "90411 Nürnberg, Mittelfranken",
                "48291 Telgte", "07745 Jena", "91126 Rednitzhembach",
                "59192 Bergkamen", "26135 Oldenburg (Oldb)", "20457 Hamburg",
                "80331 München", "60313 Frankfurt am Main"):
        assert not in_home_region(J(loc)), loc
        assert location_ok(J(loc)) == (False, "zu_weit")


def test_full_remote_qualifies_anywhere():
    desc = "Du hast die Möglichkeit, bis zu 100 % remote zu arbeiten."
    assert is_full_remote(J("40699 Erkrath", description=desc))
    assert location_ok(J("40699 Erkrath", description=desc)) == (True, "remote100")
    assert is_full_remote(J("", title="Platform Engineer (fully remote)", description="x"))
    assert is_full_remote(J("", description="Wir sind remote-first und ortsunabhängig."))
    assert is_full_remote(J("", description="Standort Düsseldorf, Köln oder 100% remote."))


def test_hybrid_does_not_count_as_remote():
    # "Homeoffice möglich" in Kiel is hybrid, not 100% remote.
    for desc in ("Homeoffice möglich. Bewerbung an jobs@x.de",
                 "Mobiles Arbeiten möglich (2 Tage/Woche vor Ort).",
                 "Hybrides Arbeiten in Kiel, flexible Zeiten.",
                 "Kein 100%-iges Match? Melde dich trotzdem!"):
        assert not is_full_remote(J("24114 Kiel", description=desc)), desc
        assert location_ok(J("24114 Kiel", description=desc)) == (False, "zu_weit")


def test_empty_location_without_proof_is_far():
    assert location_ok(J("")) == (False, "zu_weit")


def test_gate_blocks_auto_but_allows_manual_approve(env):
    """Far jobs: auto_blockers gets 'location', hard blockers stay empty (manual OK)."""
    from jobhunter.outbox import Gate
    settings, db = env
    from tests.test_send import add_job, LETTER
    job = add_job(db, title="Support Kiel", company="Far GmbH",
                  location="24114 Kiel", email="jobs@far.de")
    dec = Gate(settings, db).evaluate(job)
    assert "location" in dec.auto_blockers
    assert "location" not in dec.blockers  # manual approval still possible
    assert dec.can_send and not dec.auto_ok

    home = add_job(db, title="Support Berlin", company="Home GmbH",
                   location="10115 Berlin", email="jobs@home.de")
    dec2 = Gate(settings, db).evaluate(home)
    assert "location" not in dec2.auto_blockers


def test_classify_far_view(env):
    settings, db = env
    from jobhunter.views import classify, real_sent_ids
    from tests.test_send import add_job
    far = add_job(db, title="F", company="FC", location="24114 Kiel", email="jobs@f.de")
    ids = real_sent_ids(db)
    assert classify(far, ids, settings.send.blocklist) == "far"
    db.update_job(far["id"], status="zu_weit")
    assert classify(db.get_job(far["id"]), ids, settings.send.blocklist) == "far"
    # Explicit "interessant" rescues it to manual/auto (portal), auto-send stays blocked.
    db.update_job(far["id"], status="interessant")
    rescued = db.get_job(far["id"])
    assert classify(rescued, ids, settings.send.blocklist) == "auto"
    from jobhunter.views import apply_label
    assert "kein Auto-Versand" in apply_label(rescued, "auto")
    from jobhunter.outbox import Gate
    assert "location" in Gate(settings, db).evaluate(rescued).auto_blockers
