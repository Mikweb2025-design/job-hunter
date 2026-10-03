from jobhunter.dedup import dedup_key, dedupe, normalize_company, normalize_title
from jobhunter.models import JobPosting


def test_normalize_title_strips_gender_tags():
    variants = [
        "Technical Support Engineer [m/w/d]",
        "Technical Support Engineer (m/w/d)",
        "Technical Support Engineer (w/m/d)",
        "Technical Support Engineer m/w/d",
        "Technical Support Engineer (all genders)",
        "Technical Support Engineer (gn)",
        "technical support engineer (f/m/x)",
    ]
    assert {normalize_title(v) for v in variants} == {"technical support engineer"}


def test_normalize_title_keeps_slashes_inside_words():
    assert normalize_title("Show/Display Specialist") == "show display specialist"
    assert "ci" in normalize_title("CI/CD Engineer (m/w/d)")


def test_normalize_company_strips_legal_forms_and_umlauts():
    assert normalize_company("Virtimo AG") == normalize_company("Virtimo") == "virtimo"
    assert normalize_company("Müller & Co. KG") == "muller"
    assert normalize_company("Example GmbH & Co. KG") == "example"
    assert normalize_company("Amazon Web Services Germany GmbH") == "amazon web services"


def test_dedup_key_cross_source():
    a = dedup_key("Technical Support Engineer [m/w/d]", "Virtimo")
    b = dedup_key("Technical Support Engineer (m/w/d)", "Virtimo AG")
    assert a == b
    assert a != dedup_key("Technical Support Engineer (m/w/d)", "Other GmbH")


def test_dedupe_merges_and_fills_gaps():
    ba = JobPosting(source="arbeitsagentur", source_id="1", title="Cloud Support Engineer (m/w/d)",
                    company="Beispiel Cloud GmbH", description="kurz")
    az = JobPosting(source="adzuna", source_id="2", title="Cloud Support Engineer [w/m/d]",
                    company="Beispiel Cloud", description="eine viel längere Beschreibung",
                    salary_min=50000, salary_max=60000, url="https://x")
    other = JobPosting(source="adzuna", source_id="3", title="DevOps Engineer", company="Beispiel Cloud")
    out = dedupe([ba, az, other])
    assert len(out) == 2
    merged = out[0]
    assert merged.source == "arbeitsagentur"
    assert merged.description == "eine viel längere Beschreibung"
    assert merged.salary_max == 60000
