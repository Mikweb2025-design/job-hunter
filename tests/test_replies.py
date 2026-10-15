"""Employer replies from the mailbox: classification, matching, notes, tracker statistics.

The texts are real replies the user received (Oct 2026), shortened and anonymized
(company / person names, addresses and phone numbers replaced).
"""
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from jobhunter import replies, tracker
from jobhunter.config import SendConfig
from jobhunter.db import Database
from jobhunter.replies import ReplyItem, classify
from jobhunter.views import annotate
from jobhunter.web import create_app

from .test_opencode_views import add_job

AUTH = ("u", "p")

DOCS_LIST = """Hallo Herr Michelin,   vielen Dank für Ihre Bewerbung und Ihr Interesse an unserem Unternehmen.
Damit wir Ihre vollständige Bewerbung berücksichtigen können, bitte ich Sie, noch folgende Unterlagen an job@beispiel.de zu schicken:

- Schulabschlusszeugnis inkl. Notenübersicht
- Ausbildungszeugnisse inkl. Notenübersicht
- Praktikumszeugnis
- Arbeitszeugnis
- Sprachzertifikat
- Relevante Fort- und Weiterbildungszertifikate, sofern vorhanden.


Ich freue mich auf Ihre Unterlagen!

Mit freundlichen Grüßen
Erika Muster"""

DOCS_AND_QUESTIONS = """Hallo Daniele,
Deine Unterlagen zu lesen fanden wir sehr spannend. Kannst Du uns zur abschließenden Beurteilung Deiner Unterlagen noch die Notenübersichten aus der Ausbildung sowie Deine Arbeitszeugnisse zukommen lassen? Außerdem würde uns interessieren, wann Du bei uns anfangen könntest und was Du gerne verdienen möchtest. Wir freuen uns auf Deine Rückmeldung!
PS: Wenn Du ältere Unterlagen nicht mehr finden solltest, ist das kein Problem.
Liebe Grüße
Max"""

DEADLINE = """~~~~~ Wichtig: Bitte fügen Sie Ihre Antwort oberhalb dieser Zeile ein ~~~~~
Guten Tag Daniele Michelin ,
wir möchten uns nochmals herzlich für Ihre Bewerbung auf die Position "Senior Service Desk Mitarbeiter*in" bedanken.
Für eine umfassende Beurteilung Ihrer Qualifikationen bitten wir Sie, Ihre Bewerbung durch folgende Unterlagen bis spätestens 25.10.2026 zu vervollständigen.
Abschlusszeugnis (Ausbildung oder Studium)
Arbeitszeugnisse
Bitte laden Sie Ihre Unterlagen in Ihrem Profil hoch."""

EINGANG_WITH_OPTIONAL_DOCS = """Guten Tag Daniele Michelin,
vielen Dank für Ihr Interesse an der Stellenausschreibung Senior Service Desk Mitarbeiter*in. Hiermit bestätigen wir den Eingang Ihrer Bewerbungsunterlagen zum 10.10.2026. Ihre Unterlagen werden von uns sorgfältig und individuell geprüft.
Sofern Sie Ihrer Bewerbung weitere Unterlagen (z.B. Abschluss- oder Arbeitszeugnisse) hinzuzufügen möchten, nutzen Sie bitte folgenden Link.
Bitte reichen Sie alle relevanten Nachweise (insbesondere Abschluss- und Arbeitszeugnisse) möglichst vollständig ein."""

RUECKFRAGE = """Guten Tag Daniele Michelin,
wir freuen uns über Ihr Interesse an einer Tätigkeit bei uns und bedanken uns für Ihre Bewerbung. Können Sie uns bitte noch Ihre Verfügbarkeit nennen und Ihr Jahresbruttogehalt. Bitte haben Sie Verständnis dafür, dass wir für eine Rückmeldung noch etwas Zeit benötigen.
Mit freundlichen Grüßen"""

# Our own answer is quoted below the employer's text (Outlook, U+2028 line separators from Apple Mail).
QUOTED = ("Hallo Herr Michelin,\nvielen Dank für Ihre schnelle Antwort. Wir haben in der Tat noch zwei Fragen: "
          "Besitzen Sie einen Führerschein und die dazugehörige Fahrpraxis? Welchen Berufsabschluss haben Sie erworben?\n"
          "Mit freundlichen Grüßen\nPersonalleitung\n Von: Daniele Michelin <info@example.org> Gesendet: Donnerstag\n"
          "Betreff: Re: Ihre Bewerbung\nGehaltsvorstellung: Meine Gehaltsvorstellung liegt bei 48.000 € brutto. "
          "Arbeitszeugnisse sende ich gern nach.")

ABSAGE = """Guten Tag Daniele Michelin,
vielen Dank für Ihre Bewerbung. Leider müssen wir Ihnen mitteilen, dass wir Ihre Bewerbung nicht berücksichtigen konnten. Wir bedauern, Ihnen keinen positiven Bescheid geben zu können."""

ABSAGE_DU = """Guten Tag Daniele, wir haben Deine Unterlagen aufmerksam geprüft und uns entschieden, Deine Bewerbung im weiteren Auswahlprozess nicht zu berücksichtigen, da es aus unserer Sicht aktuell nicht passt."""

STEPSTONE_FEEDBACK = """Neuigkeiten zu deiner Bewerbung
IT User Support Specialist
Beispiel Partners LLP
Hallo Daniele Michelin,
vielen Dank für deine Bewerbung über Stepstone.
Leider hat Beispiel Partners LLP deine Bewerbung nicht für die nächste Runde ausgewählt.
Unten findest du das Feedback von Beispiel Partners LLP*:
Nach einer sorgfältigen Prüfung Ihrer Unterlagen müssen wir Ihnen jedoch leider mitteilen, dass wir Ihnen die gewünschte Position nicht anbieten können."""

CONDITIONAL_ABSAGE = """Hallo, vielen Dank für deine Bewerbung. Deine Mail ist eingegangen und wird von uns zeitnah gesichtet. Solltest du keine Rückmeldung von uns erhalten, so kannst du davon ausgehen, dass deine Bewerbung leider nicht in die engere Auswahl gekommen und dies als Absage zu werten ist. Aufgrund der vielen Bewerbungseingänge ist uns bedauerlicherweise nicht immer eine persönliche Absage möglich.
If you do not receive any feedback from us, you can assume that your application has unfortunately not been shortlisted. Unfortunately, due to the large number of applications received, it is not always possible for us to reject every applicant personally."""

CONDITIONAL_INVITE = """Sehr geehrter Interessent, wir haben Ihre Bewerbung erhalten. Vielen Dank. Sobald wir eine engere Auswahl getroffen haben, werden wir uns entweder telefonisch oder per E-Mail, zwecks Abstimmung eines Vorstellungsgespräches mit Ihnen in Verbindung setzen. Wir werden uns auch im Falle einer Absage bei Ihnen melden."""

EINLADUNG = """Hallo Daniele, Dein Profil hat uns wirklich gut gefallen, daher möchten wir Dich gerne ein wenig näher kennenlernen und Dich zu einem ersten Gespräch einladen. Der Terminvorschlag: Mittwoch, der 14.10.2026 13:00 Uhr via Google Meet."""

CALL_REQUEST = """Sehr geehrter Herr Michelin, ich habe versucht, Sie telefonisch zu erreichen, um mit Ihnen über Ihre eingegangene Bewerbung zu sprechen. Wann passt es Ihnen? Beste Grüße"""

PORTAL_REMINDER = """Vervollständigen Sie Ihre Bewerbung. Ihre Bewerbung ist fast vollständig, aber sie wird erst abgeschickt, wenn Sie sie auf die Schaltfläche klicken und das Formular ausfüllen."""

EINGANG = """Hallo Daniele, vielen Dank für deine Bewerbung auf unsere ausgeschriebene Position und dein Interesse. Wir prüfen deine Unterlagen genau und melden uns dazu schnellstmöglich bei dir. Hast du weitere Fragen oder möchtest direkt mehr erfahren? Dann schreib uns."""


# ---- classification ------------------------------------------------------------------

def test_documents_list_with_abbreviations_and_conditional_item():
    c = classify("Ihre Bewerbung bei Beispiel", DOCS_LIST)
    assert c.kind == "unterlagen"
    for d in ("Schulzeugnis", "Abschlusszeugnis", "Notenübersicht", "Praktikumszeugnis", "Arbeitszeugnisse",
              "Sprachnachweis", "Zertifikate / Weiterbildungsnachweise"):
        assert d in c.documents
    assert "Gehaltsvorstellung" not in c.questions


def test_documents_plus_salary_and_start_date():
    c = classify("Deine Bewerbung bei Beispiel", DOCS_AND_QUESTIONS)
    assert c.kind == "unterlagen"
    assert c.documents == ["Arbeitszeugnisse", "Notenübersicht"]
    assert c.questions == ["Gehaltsvorstellung", "Eintrittstermin / Verfügbarkeit"]


def test_deadline_is_extracted():
    c = classify("Nachreichung von Bewerbungsunterlagen", DEADLINE)
    assert c.kind == "unterlagen" and c.deadline == "25.10.2026"
    assert set(c.documents) == {"Abschlusszeugnis", "Arbeitszeugnisse"}


def test_acknowledgement_that_only_offers_to_add_documents_is_no_request():
    assert classify("Ihre Bewerbung für die Position", EINGANG_WITH_OPTIONAL_DOCS).kind == "eingang"


def test_rueckfrage_salary_and_availability():
    c = classify("Ihre Bewerbung als IT-Systemadministrator", RUECKFRAGE)
    assert c.kind == "rueckfrage"
    assert set(c.questions) == {"Eintrittstermin / Verfügbarkeit", "Gehaltsvorstellung"}


def test_quoted_own_mail_is_ignored():
    c = classify("AW: Ihre Bewerbung", QUOTED)
    assert c.kind == "rueckfrage"
    assert c.questions == ["Führerschein", "Berufsabschluss"]
    assert c.documents == []


@pytest.mark.parametrize("body", [ABSAGE, ABSAGE_DU, STEPSTONE_FEEDBACK])
def test_absage(body):
    c = classify("Ihre Bewerbung", body)
    assert c.kind == "absage" and c.requested == []


def test_conditional_rejection_and_invitation_are_acknowledgements():
    assert classify("Re: Bewerbung als Engineer", CONDITIONAL_ABSAGE).kind == "eingang"
    assert classify("AW: Bewerbung als Engineer", CONDITIONAL_INVITE).kind == "eingang"


def test_invitation_and_call_request():
    assert classify("Wir möchten Dich gern kennenlernen", EINLADUNG).kind == "einladung"
    assert classify("Terminverschiebung für Deinen Termin", "Neuer Termin: Mittwoch 12:30 Uhr").kind == "einladung"
    c = classify("Update bezüglich Ihrer Bewerbung", CALL_REQUEST)
    assert c.kind == "rueckfrage" and c.questions == ["Terminvorschläge"]


def test_portal_reminder_and_plain_acknowledgement():
    assert classify("Vervollständigen Sie Ihre Bewerbung", PORTAL_REMINDER).kind == "sonstiges"
    assert classify("Vielen Dank für deine Bewerbung", EINGANG).kind == "eingang"


# ---- matching + recording --------------------------------------------------------------

@pytest.fixture
def ctx(settings):
    settings.dashboard_user, settings.dashboard_password = AUTH
    settings.send = SendConfig()
    db = Database(settings.db_path)
    c = TestClient(create_app(settings, db=db))
    c.auth = AUTH
    return c, settings, db


def applied(db, title, company, email=None, days=5, status="beworben"):
    j = add_job(db, title=title, company=company, email=email)
    db.update_job(j["id"], status=status, applied_date=(date.today() - timedelta(days=days)).isoformat(),
                  status_updated_at=(date.today() - timedelta(days=days)).isoformat() + "T08:00:00+00:00",
                  apply_email=email)
    return db.get_job(j["id"])


def item(mid, sender, subject, body, days=0):
    return ReplyItem(message_id=mid, sender=sender, subject=subject, body=body,
                     received_at=(date.today() - timedelta(days=days)).isoformat() + "T10:00:00+00:00")


def test_match_by_sent_domain_company_and_title(ctx):
    _, _, db = ctx
    a = applied(db, "DevOps Engineer", "Zollbeispiel GmbH", email="jobs@zollbeispiel.de")
    b = applied(db, "Senior Workplace Engineer", "", email="bewerbung@ipb-beispiel.de")
    c = applied(db, "Cloud Support Engineer (m/w/d)", "SysBeispiel GmbH")
    other = applied(db, "Cloud Support Engineer (m/w/d)", "Andere AG")
    assert replies.match_job(db, item("1", "Zollbeispiel GmbH <jobs@zollbeispiel.de>", "Deine Bewerbung", "x"))["id"] == a["id"]
    assert replies.match_job(db, item("2", "HR <bewerbung@ipb-beispiel.de>", "AW: Bewerbung als Senior Workplace Engineer", ""))["id"] == b["id"]
    # ATS sender (personio): company in the display name decides, not the title
    assert replies.match_job(db, item("3", "Jan <sysbeispiel-jobs@m.personio.de>",
                                      "Wir bei der secunet (ehem. SysBeispiel) möchten Dich kennenlernen", ""))["id"] == c["id"]
    assert other["id"] != c["id"]
    assert replies.match_job(db, item("4", "Shop <news@shop.de>", "Angebote der Woche", "Rabatt")) is None
    # job board forwarding the employer's feedback: company in the subject
    d = applied(db, "IT User Support Specialist", "Beispiel Partners LLP")
    assert replies.match_job(db, item("5", "Stepstone <info@email.stepstone.de>",
                                      "Neuigkeiten zu deiner Bewerbung als IT User Support Specialist bei Beispiel Partners LLP",
                                      STEPSTONE_FEEDBACK))["id"] == d["id"]


def test_record_replies_notes_status_and_counts(ctx):
    _, _, db = ctx
    j = applied(db, "DevOps Engineer", "Zollbeispiel GmbH", email="jobs@zollbeispiel.de")
    k = applied(db, "Cloud Engineer", "Prodbeispiel SE", email="jobs@prodbeispiel.com")
    db.update_job(j["id"], notes="Kontakt: Max")
    out = replies.record_replies(db, [
        item("<a@x>", "Zollbeispiel GmbH <jobs@zollbeispiel.de>", "Deine Bewerbung bei Zollbeispiel", DOCS_AND_QUESTIONS),
        item("<b@x>", "recruiting@prodbeispiel.com", "Deine Bewerbung bei Prodbeispiel", ABSAGE),
        item("<c@x>", "Unbekannt <hr@niemand.de>", "Ihre Bewerbung als Hausmeister", RUECKFRAGE),
    ])
    assert out["matched"] == [j["id"], k["id"]] and out["unmatched"] == 1
    j2, k2 = db.get_job(j["id"]), db.get_job(k["id"])
    assert j2["notes"].startswith("Kontakt: Max\n📎 ")
    assert "Unterlagen angefordert – Unterlagen: Arbeitszeugnisse, Notenübersicht – Fragen: Gehaltsvorstellung" in j2["notes"]
    assert j2["reply_kind"] == "unterlagen" and j2["status"] == "beworben"
    assert j2["docs_requested"] == "Arbeitszeugnisse, Notenübersicht, Gehaltsvorstellung, Eintrittstermin / Verfügbarkeit"
    assert k2["status"] == "absage" and k2["close_reason"] == "absage_firma" and k2["reply_kind"] == "absage"
    assert db.status_history(k["id"])[-1]["source"] == "antwort"
    # the same mail again: ignored, notes unchanged
    again = replies.record_replies(db, [item("<a@x>", "jobs@zollbeispiel.de", "Deine Bewerbung", DOCS_AND_QUESTIONS)])
    assert again["duplicates"] == 1 and db.get_job(j["id"])["notes"] == j2["notes"]
    assert len(db.replies()) == 3 and db.replies(None)[-1]["job_id"] is None


def test_status_changed_by_user_after_the_mail_is_kept(ctx):
    _, _, db = ctx
    j = applied(db, "Cloud Engineer", "Prodbeispiel SE", email="jobs@prodbeispiel.com", status="gespraech", days=1)
    replies.record_replies(db, [item("<old@x>", "jobs@prodbeispiel.com", "Ihre Bewerbung", ABSAGE, days=3)])
    j2 = db.get_job(j["id"])
    assert j2["status"] == "gespraech" and "Absage" in j2["notes"]


def test_acknowledgement_marks_applied_but_is_no_answer(ctx):
    _, _, db = ctx
    j = applied(db, "Support Engineer", "Seitenbeispiel GmbH", email="karriere@seitenbeispiel.com", status="interessant")
    db.update_job(j["id"], applied_date=None)
    replies.record_replies(db, [item("<e@x>", "HR <karriere@seitenbeispiel.com>",
                                     "Eingangsbestätigung - Bewerbung bei der Seitenbeispiel GmbH", EINGANG)])
    j2 = db.get_job(j["id"])
    assert j2["status"] == "beworben" and j2["applied_date"] == date.today().isoformat()
    assert j2["reply_kind"] is None
    assert not tracker.has_response(j2, {})


def test_invitation_moves_to_gespraech(ctx):
    _, _, db = ctx
    j = applied(db, "Cloud Support Engineer", "SysBeispiel GmbH")
    replies.record_replies(db, [item("<i@x>", "Jan <sysbeispiel-jobs@m.personio.de>",
                                     "Wir bei SysBeispiel möchten Dich gern kennenlernen", EINLADUNG)])
    assert db.get_job(j["id"])["status"] == "gespraech"


def test_backfill_from_handwritten_notes(ctx):
    _, _, db = ctx
    a = applied(db, "A Engineer", "A GmbH")
    b = applied(db, "B Engineer", "B GmbH")
    c = applied(db, "C Engineer", "C GmbH")
    db.update_job(a["id"], notes="weitere unterlagen angefordert")
    db.update_job(b["id"], notes="Rücksprache wegen Gehalt")
    db.update_job(c["id"], notes="Hinweis Umzugsfilter")
    assert replies.backfill_from_notes(db) == 2
    assert db.get_job(a["id"])["reply_kind"] == "unterlagen"
    assert db.get_job(b["id"])["reply_kind"] == "rueckfrage"
    assert db.get_job(c["id"])["reply_kind"] is None


# ---- tracker + API ---------------------------------------------------------------------

def test_rueckfrage_counts_as_rueckmeldung_in_tracker(ctx):
    c, settings, db = ctx
    j = applied(db, "DevOps Engineer", "Zollbeispiel GmbH", email="jobs@zollbeispiel.de", days=20)
    applied(db, "Other Engineer", "Other GmbH", days=20)
    r = c.post("/api/v1/jobs/replies", json=[{
        "message_id": "<z@x>", "sender": "Zollbeispiel GmbH <jobs@zollbeispiel.de>",
        "subject": "Deine Bewerbung bei Zollbeispiel", "body": DOCS_AND_QUESTIONS,
        "received_at": (date.today() - timedelta(days=2)).isoformat() + "T09:00:00Z"}])
    assert r.status_code == 200 and r.json()["matched"] == [j["id"]]
    tr = c.get("/api/v1/tracker").json()
    k = tr["kpis"]
    assert k["applied"] == 2 and k["responses"] == 1 and k["response_rate"] == 50
    assert k["rueckfragen"] == 1 and k["docs_requested"] == 1 and k["open_requests"] == 1
    assert k["waiting"] == 1 and k["avg_days_to_answer"] == 18.0
    assert [x["id"] for x in tr["action_needed"]] == [j["id"]]
    # open requests: no "Nachfassen" for this one, only for the other (20 days without answer)
    assert [x["company"] for x in tr["follow_ups"]] == ["Other GmbH"]
    card = next(x for col in tr["columns"] for x in col["cards"] if x["id"] == j["id"])
    assert card["next_step"].startswith("Nachreichen / beantworten: Arbeitszeugnisse")
    rp = tr["replies"]
    assert {r["kind"]: r["jobs"] for r in rp["by_kind"]}["unterlagen"] == 1
    assert rp["requested"][0] == {"item": "Arbeitszeugnisse", "count": 1}
    # done: clear open requests (stays a Rückmeldung)
    assert c.patch(f"/api/v1/jobs/{j['id']}", json={"docs_requested": None}).status_code == 200
    k2 = c.get("/api/v1/tracker").json()["kpis"]
    assert k2["open_requests"] == 0 and k2["responses"] == 1
    hist = c.get(f"/api/v1/jobs/{j['id']}/history").json()["events"]
    assert any(e["kind"] == "reply" and "Unterlagen" in e["label"] for e in hist)


def test_reply_kind_set_by_hand(ctx):
    c, _, db = ctx
    j = applied(db, "DevOps Engineer", "Hand GmbH")
    assert c.patch(f"/api/v1/jobs/{j['id']}", json={"reply_kind": "rueckfrage"}).json()["reply_kind"] == "rueckfrage"
    assert c.get("/api/v1/tracker").json()["kpis"]["responses"] == 1
    assert c.patch(f"/api/v1/jobs/{j['id']}", json={"reply_kind": "quatsch"}).status_code == 422
    # dashboard form
    r = c.post(f"/jobs/{j['id']}/status", data={"status": "beworben", "reply_fields": "1", "reply_kind": "", "docs_requested": "Zeugnis"},
               follow_redirects=False)
    assert r.status_code == 303
    j2 = db.get_job(j["id"])
    assert j2["reply_kind"] is None and j2["docs_requested"] == "Zeugnis"


def test_tracker_page_shows_reply_statistics(ctx):
    c, _, db = ctx
    j = applied(db, "DevOps Engineer", "Zollbeispiel GmbH", email="jobs@zollbeispiel.de")
    replies.record_replies(db, [item("<p@x>", "jobs@zollbeispiel.de", "Deine Bewerbung", DOCS_AND_QUESTIONS)])
    html = c.get("/tracker").text
    assert "Rückfragen / Unterlagen" in html and "Antworten der Firmen" in html
    assert "Erledigt – nachgereicht" in html and "Am häufigsten angefragt" in html
    assert "Rückmeldung der Firma" in c.get(f"/jobs/{j['id']}").text


def test_reply_to_our_answer_replaces_open_requests(ctx):
    _, _, db = ctx
    j = applied(db, "IT-Administrator", "Gfbeispiel IT und Service GmbH", email="bewerbung@gfbeispiel.de")
    first = ("Sehr geehrter Herr Michelin, zur abschließenden Einschätzung benötigen wir noch Ihre Angabe zu den "
             "Gehaltsvorstellungen. Besitzen Sie einen Führerschein? Welchen Berufsabschluss haben Sie erworben?")
    replies.record_replies(db, [item("<g1@x>", "Gfbeispiel Bewerbung <bewerbung@gfbeispiel.de>", "Ihre Bewerbung", first, days=1)])
    assert db.get_job(j["id"])["docs_requested"] == "Gehaltsvorstellung, Führerschein, Berufsabschluss"
    replies.record_replies(db, [item("<g2@x>", "Gfbeispiel Bewerbung <bewerbung@gfbeispiel.de>", "AW: Ihre Bewerbung", QUOTED)])
    assert db.get_job(j["id"])["docs_requested"] == "Führerschein, Berufsabschluss"
