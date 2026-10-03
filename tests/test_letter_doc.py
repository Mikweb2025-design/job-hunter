"""Cover-letter document (print page, PDF, API), the no-LLM template, old-template migration
and the "write all missing letters" batch (fake opencode only, never the real CLI)."""
import re
from datetime import date

import pytest
from fastapi.testclient import TestClient

from jobhunter import letter_doc, letters
from jobhunter.__main__ import main as cli
from jobhunter.config import ApplicantConfig, LLMConfig, SendConfig, load_settings
from jobhunter.db import Database
from jobhunter.llm import (MAX_LETTER_CHARS, LetterRejected, clean_letter_output, paragraphs,
                           template_letter)
from jobhunter.models import JobPosting
from jobhunter.outbox import has_placeholder
from jobhunter.scoring import CVProfile
from jobhunter.web import create_app

from .test_opencode_views import GOOD, add_job, fake_oc, oc_cfg  # noqa: F401 (fixture)

AUTH = ("u", "p")
CV_FULL = """# Daniele Michelin – Profil
Berlin · Specialist Support Engineer bei IONOS/STRATO seit 2008 (2018 – heute, 2nd/3rd Level)
## Kernergebnisse
- Technischer Support für eine Nextcloud-Plattform mit rund 15.000 Instanzen und HiDrive mit rund 150.000 Instanzen
- Bearbeitung von rund 200 Tickets pro Woche für Nextcloud, HiDrive und S3-Objektspeicher
- Aufbau einer KI-gestützten Ticket-Triage über MCP (Model Context Protocol)
- Eigene Tools und Automatisierungen mit Python, FastAPI und Docker
## Keywords
Nextcloud: 4, Linux: 2, Python: 2, Docker: 2, Support, Ticket
"""


@pytest.fixture
def client(settings):
    settings.dashboard_user, settings.dashboard_password = AUTH
    settings.send = SendConfig(mode="approve", dry_run=True)
    db = Database(settings.db_path)
    c = TestClient(create_app(settings, db=db))
    c.auth = AUTH
    return c, db, settings


# ---- salutation / title / filename ------------------------------------------

@pytest.mark.parametrize("text, expected", [
    ("Ihre Ansprechpartnerin: Frau Anna Schmidt, Recruiting", "Sehr geehrte Frau Schmidt,"),
    ("Ansprechpartner:\nHerr Jörg Müller-Lüdenscheidt\nTel. 030 123", "Sehr geehrter Herr Müller-Lüdenscheidt,"),
    ("Ansprechpartner für Rückfragen: Herr Dr. Özdemir", "Sehr geehrter Herr Dr. Özdemir,"),
    ("Kontaktperson – Frau Weiß", "Sehr geehrte Frau Weiß,"),
    ("Wir sind Ihre Ansprechpartner, die jederzeit erreichbar sind.", letter_doc.DEFAULT_SALUTATION),
    ("Ansprechpartner: Frau Anna Schmidt oder Herr Max Meier", letter_doc.DEFAULT_SALUTATION),  # two people
    ("Bitte wenden Sie sich an Frau Schmidt.", letter_doc.DEFAULT_SALUTATION),  # no explicit contact label
    ("Ansprechpartner:innen im Team", letter_doc.DEFAULT_SALUTATION),
    ("", letter_doc.DEFAULT_SALUTATION),
])
def test_detect_salutation(text, expected):
    assert letter_doc.detect_salutation(text) == expected


def test_letter_title_and_filename():
    assert letter_doc.letter_title("SoftwareOne Deutschland GmbH: Power Platform Support Engineer (gn)",
                                   "SoftwareOne Deutschland GmbH") == "Power Platform Support Engineer"
    assert letter_doc.letter_title("Support Engineer (m/w/d)", "Acme") == "Support Engineer"
    assert letter_doc.pdf_filename("Müller & Söhne GmbH / Berlin", date(2026, 10, 3)) == \
        "Anschreiben_Müller_Söhne_GmbH_Berlin_2026-10-03.pdf"
    assert letter_doc.pdf_filename("]init[ AG", date(2026, 1, 2)) == "Anschreiben_init_AG_2026-01-02.pdf"
    assert letter_doc.pdf_filename("", date(2026, 1, 2)) == "Anschreiben_Unbekannt_2026-01-02.pdf"
    assert len(letter_doc.sanitize_filename_part("x" * 200)) == 60


def test_build_document_fields():
    job = {"id": 7, "title": "Cloud Support Engineer (m/w/d)", "company": "Acme GmbH", "location": "10115 Berlin",
           "description": "Ansprechpartnerin: Frau Erika Müßig", "letter": "Absatz eins.\n\nAbsatz zwei.\nNoch zwei.",
           "letter_origin": "KI (opencode)"}
    d = letter_doc.build_document(job, ApplicantConfig(), date(2026, 10, 3))
    assert d["sender"]["name"] == "Daniele Michelin" and "info@daniele-michelin.com" in d["sender"]["contact"]
    assert d["recipient"]["lines"] == ["Acme GmbH", "10115 Berlin"]
    assert d["place_date"] == "Berlin, 03.10.2026" and d["date"] == "03.10.2026"
    assert d["subject"] == "Bewerbung als Cloud Support Engineer"
    assert d["salutation"] == "Sehr geehrte Frau Müßig,"
    assert d["body"] == ["Absatz eins.", "Absatz zwei. Noch zwei."]
    assert (d["closing"], d["signature"], d["enclosures"]) == ("Mit freundlichen Grüßen", "Daniele Michelin", ["Lebenslauf"])
    assert d["filename"] == "Anschreiben_Acme_GmbH_2026-10-03.pdf" and not d["has_placeholder"]


def test_render_pdf_one_page_with_umlauts():
    pytest.importorskip("fpdf")
    long_body = "\n\n".join(["Größere Änderungen für Kundinnen und Kunden – „Qualität“ prüfen, Übergänge "
                             "dokumentieren und Fehler bis zur Ursache analysieren. " * 3] * 4)
    job = {"id": 1, "title": "Support Engineer", "company": "Müller GmbH", "location": "Berlin",
           "description": "", "letter": long_body}
    pdf = letter_doc.render_pdf(letter_doc.build_document(job, ApplicantConfig(), date(2026, 10, 3)))
    assert pdf.startswith(b"%PDF") and len(re.findall(rb"/Type\s*/Page(?!s)", pdf)) == 1
    assert b"LiberationSans" in pdf  # embedded Unicode font (umlauts, „“, –)


# ---- web + API ----------------------------------------------------------------

def test_print_page_pdf_and_api(client):
    c, db, settings = client
    job = add_job(db, company="Bäckerei Groß GmbH", letter=GOOD, origin="KI (opencode)")
    db.update_job(job["id"], description="Ansprechpartner: Herr Max Weber")
    r = c.get(f"/jobs/{job['id']}/anschreiben")
    assert r.status_code == 200
    assert "Als PDF speichern" in r.text and "window.print()" in r.text and "@media print" in r.text
    assert "Sehr geehrter Herr Weber," in r.text and "Bäckerei Groß GmbH" in r.text
    assert "Bewerbung als Cloud Support Engineer" in r.text and "Mit freundlichen Grüßen" in r.text
    assert "Anlage: Lebenslauf" in r.text and "#1E5F66" in r.text
    r = c.get(f"/jobs/{job['id']}/anschreiben.pdf")
    assert r.status_code == 200 and r.headers["content-type"] == "application/pdf"
    assert r.content.startswith(b"%PDF")
    assert "Anschreiben_B%C3%A4ckerei_Gro%C3%9F_GmbH_" in r.headers["content-disposition"]
    d = c.get(f"/api/v1/jobs/{job['id']}/letter-document").json()
    assert d["salutation"] == "Sehr geehrter Herr Weber," and d["body"] == paragraphs(GOOD)
    assert d["sender"]["phone"] == "+49 160 7804710" and d["recipient"]["company"] == "Bäckerei Groß GmbH"
    assert c.get("/api/v1/jobs/9999/letter-document").status_code == 404
    assert c.get("/api/v1/send-settings").json()["applicant"]["city"] == "Berlin"
    detail = c.get(f"/jobs/{job['id']}").text
    assert f"/jobs/{job['id']}/anschreiben" in detail and "Anschreiben als PDF" in detail


def test_today_page_has_pdf_button(client):
    c, db, _ = client
    job = add_job(db, email=None, letter=GOOD, origin="KI (opencode)", score=90)
    assert f"/jobs/{job['id']}/anschreiben?back=today" in c.get("/today").text


def test_applicant_config_yaml(tmp_path):
    cfg = tmp_path / "c.yaml"
    cfg.write_text("applicant:\n  name: Erika Muster\n  street: Hauptstraße 1\n  city: Köln\n", encoding="utf-8")
    a = load_settings(cfg).applicant
    assert (a.name, a.street, a.city, a.email) == ("Erika Muster", "Hauptstraße 1", "Köln", "info@daniele-michelin.com")
    assert load_settings("config.yaml").applicant.linkedin == "linkedin.com/in/daniele-michelin-02863143b"


# ---- letter rules / template ------------------------------------------------------

def test_clean_requires_paragraphs_and_length():
    one_par = " ".join(paragraphs(GOOD))
    with pytest.raises(LetterRejected, match="Absätze"):
        clean_letter_output(one_par)
    # single line breaks between paragraphs are accepted and normalized
    assert clean_letter_output(GOOD.replace("\n\n", "\n")) == GOOD
    with pytest.raises(LetterRejected, match="zu lang"):
        clean_letter_output(GOOD + "\n\n" + "Ich ergänze noch viele Details. " * 60)
    with pytest.raises(LetterRejected, match="hiermit bewerbe"):
        clean_letter_output("Hiermit bewerbe ich mich als Support Engineer. " + GOOD)
    assert len(GOOD) < MAX_LETTER_CHARS
    # brackets that belong to the company name are not placeholders
    letter = GOOD.replace("Acme GmbH", "]init[ AG")
    assert clean_letter_output(letter, company="]init[ AG") == letter
    with pytest.raises(LetterRejected, match="Platzhalter"):
        clean_letter_output(letter)


def test_template_letter_complete_without_placeholders():
    cv = CVProfile.parse(CV_FULL)
    job = {"title": "SoftwareOne Deutschland GmbH: Power Platform Support Engineer (gn)",
           "company": "SoftwareOne Deutschland GmbH", "description": "Support für Nextcloud und Tickets, Python"}
    t = template_letter(cv, job)
    assert "[" not in t and "]" not in t and not has_placeholder(t)
    assert "Power Platform Support Engineer bei SoftwareOne Deutschland GmbH" in t
    assert 600 <= len(t) <= MAX_LETTER_CHARS and len(paragraphs(t)) == 4
    assert "rund 15.000 Instanzen" in t and "90 Tagen" in t and "Gespräch" in t
    assert "technischer Support für eine Nextcloud" in t  # adjective lower-cased inside the list
    # passes the same checks as KI letters (first person, no invented numbers)
    assert clean_letter_output(t, sources=[CV_FULL, job["title"] + job["description"]]) == t
    t2 = template_letter(CVProfile.parse(""), {"title": "", "company": "", "description": ""})
    assert "[" not in t2 and len(paragraphs(t2)) == 4 and "in Ihrem Unternehmen" in t2


# ---- migration + batch -------------------------------------------------------------

def test_fix_old_templates_and_candidates(settings):
    db = Database(settings.db_path)
    old = add_job(db, title="A", company="A1", letter="Satz. [konkreten Bezug ergänzen]", origin="vorlage", score=90)
    manual = add_job(db, title="B", company="B1", letter="Mein Text [noch offen]", origin="manuell", score=95)
    ki = add_job(db, title="C", company="C1", letter=GOOD, origin="KI (opencode)", score=99)
    empty = add_job(db, title="D", company="D1", score=50)
    zero = add_job(db, title="E", company="E1", score=0)
    applied = add_job(db, title="F", company="F1", score=80, status="beworben")
    assert letters.fix_old_templates(settings, db, dry_run=True) == [old["id"]]
    assert db.get_job(old["id"])["letter"].startswith("Satz.")
    assert letters.fix_old_templates(settings, db) == [old["id"]]
    fixed = db.get_job(old["id"])
    assert fixed["letter_origin"] == "vorlage" and not has_placeholder(fixed["letter"])
    assert db.get_job(manual["id"])["letter"] == "Mein Text [noch offen]"  # user text untouched
    ids = [j["id"] for j in letters.candidates(settings, db, capped=False)]
    assert ids == [old["id"], empty["id"]]  # best first; not manual/KI/score 0/applied
    assert zero["id"] not in ids and applied["id"] not in ids and ki["id"] not in ids
    settings.llm.max_per_run = 1
    assert len(letters.candidates(settings, db)) == 1


def test_cli_letters_all_with_fake_opencode(settings, fake_oc, tmp_path, capsys):
    binary, _ = fake_oc
    db = Database(settings.db_path)
    a = add_job(db, title="A", company="A1", letter="X [ergänzen]", origin="vorlage", score=90)
    b = add_job(db, title="B", company="B1", score=60)
    m = add_job(db, title="M", company="M1", letter="Eigener Text", origin="manuell", score=99)
    cfg = tmp_path / "c.yaml"
    cfg.write_text(f"data_dir: {settings.data_dir}\nllm:\n  provider: opencode\n  model: opencode/big-pickle\n"
                   f"  opencode_bin: {binary}\n  timeout_s: 20\n  max_per_run: 1\n", encoding="utf-8")
    assert cli(["--config", str(cfg), "letters", "--dry-run"]) == 0
    out = capsys.readouterr().out
    assert "1 würden ersetzt" in out and "Stellen für KI-Anschreiben: 1" in out
    assert cli(["--config", str(cfg), "letters", "--all"]) == 0
    out = capsys.readouterr().out
    assert "Fertig: 2 geschrieben, 0 fehlgeschlagen" in out
    for j in (a, b):
        got = db.get_job(j["id"])
        assert got["letter"] == GOOD and got["letter_origin"] == "KI (opencode)"
    assert db.get_job(m["id"])["letter"] == "Eigener Text"


def test_pipeline_templates_new_jobs_and_rewrites_old_templates(settings, fake_oc):
    from jobhunter.pipeline import run_cycle
    from jobhunter.sources.adzuna import parse_response as adzuna_parse

    from .conftest import load_json
    from .test_pipeline_web import FixtureSource
    binary, _ = fake_oc
    db = Database(settings.db_path)
    old = add_job(db, title="Alt", company="Alt GmbH", letter="Satz. [Bezug ergänzen]", origin="vorlage", score=99)
    mine = add_job(db, title="Meins", company="M GmbH", letter="Mein Text", origin="manuell", score=98)
    settings.llm = oc_cfg(binary, max_per_run=1)
    rep = run_cycle(settings, db=db, sources=[FixtureSource("adzuna", adzuna_parse(load_json("adzuna_search.json")))],
                    notify=False)
    assert rep.llm_done == 1
    assert db.get_job(old["id"])["letter_origin"] == "KI (opencode)"  # best score first, old template rewritten
    assert db.get_job(mine["id"])["letter"] == "Mein Text"
    new = [j for j in db.list_jobs() if j["id"] in rep.new_ids]
    assert new and all(not has_placeholder(j["letter"]) for j in new if j["letter"])
    assert all(j["letter_origin"] == "vorlage" for j in new if j["rule_score"] > 0)
    assert not letters.is_running()
