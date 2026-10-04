from jobhunter import links


def test_stepstone_tracking_link_replaced():
    job = {"title": "IT User Support Specialist", "company": "Greenberg Traurig Germany, LLP", "location": "Berlin",
           "source": "stepstone-alert", "url": "https://click.stepstone.de/f/a/abc~~/AAAmIhA~/xyz"}
    assert links.is_tracking(job["url"])
    assert links.apply_link(job) == "https://www.stepstone.de/jobs/it-user-support-specialist-greenberg-traurig-germany-llp/in-berlin"
    titles = [a["title"] for a in links.alternatives(job)]
    assert "Auf StepStone suchen" in titles and any(t.startswith("Link aus der E-Mail") for t in titles)


def test_normal_link_kept():
    job = {"title": "X", "company": "Y", "source": "arbeitsagentur", "url": "https://www.arbeitsagentur.de/jobsuche/jobdetail/1"}
    assert links.apply_link(job) == job["url"]


def test_slug_same_as_app():
    assert links.slug("Systemadministrator (m/w/d) Öffentlicher Dienst") == "systemadministrator-oeffentlicher-dienst"
