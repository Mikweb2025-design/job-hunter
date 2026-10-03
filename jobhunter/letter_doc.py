"""Cover letter as a full document (DIN-5008-like): sender, recipient, date, subject, salutation,
body, closing, enclosures. Used by the print page `/jobs/{id}/anschreiben`, the PDF
`/jobs/{id}/anschreiben.pdf` and `GET /api/v1/jobs/{id}/letter-document` (the macOS app renders
the same fields with the same layout, see LetterDocument.swift).

Nothing here sends anything: it only formats the stored letter.
"""
from __future__ import annotations

import re
from datetime import date
from pathlib import Path

from .config import ApplicantConfig
from .dedup import _GENDER_RE
from .llm import paragraphs
from .outbox import has_placeholder

ACCENT_RGB = (0x1E, 0x5F, 0x66)  # same accent as the CV (#1E5F66)
FONT_DIR = Path(__file__).parent / "fonts"
DEFAULT_SALUTATION = "Sehr geehrte Damen und Herren,"
CLOSING = "Mit freundlichen Grüßen"

_NAME = r"[A-ZÄÖÜ][a-zäöüß]+(?:-[A-ZÄÖÜ][a-zäöüß]+)?"
# Conservative: only an explicit "Ansprechpartner(in) … Frau/Herr <Name>" counts.
_CONTACT_RE = re.compile(
    r"(?:Ansprechpartner(?:in)?|Ansprechperson|Kontaktperson)\b[^\n:]{0,40}?[:\-–]?\s*"
    r"(Frau|Herrn?)\s+((?:(?:Dr|Prof)\.\s*)*)(" + _NAME + r")(?:[ \t]+(" + _NAME + r"))?(?![\wäöüß])")
_ANOTHER_PERSON_RE = re.compile(r"\b(?:Frau|Herrn?)\s+[A-ZÄÖÜ]")
_NOT_NAMES = {"Damen", "Herren", "Kollegin", "Kollege", "Bewerber", "Bewerberin", "Ansprechpartner",
              "Ansprechpartnerin", "Personal", "Recruiting", "Team", "Frau", "Herr", "Herrn", "Oder", "Und"}


def letter_title(title: str, company: str | None = None) -> str:
    """Job title for subject/letter: without gender tags "(m/w/d)" and without a leading
    "<Company>: " prefix (Arbeitsagentur titles often have one)."""
    t = " ".join(_GENDER_RE.sub(" ", title or "").split()).strip(" -–|,:")
    comp = (company or "").strip()
    if comp and t.lower().startswith(comp.lower()):
        rest = t[len(comp):].lstrip()
        if rest[:1] in (":", "-", "–", "|"):
            t = rest[1:].strip()
    t = re.sub(r"\(\s*\)", "", t)
    return " ".join(t.split()).strip(" -–|,:")


def detect_salutation(description: str | None) -> str:
    """"Sehr geehrte Frau X," / "Sehr geehrter Herr X," if the posting clearly names exactly one
    contact person (e.g. "Ansprechpartnerin: Frau Anna Schmidt"); otherwise the neutral default."""
    people: set[tuple[str, str]] = set()
    text = description or ""
    for m in _CONTACT_RE.finditer(text):
        if _ANOTHER_PERSON_RE.search(text, m.end(), m.end() + 60):
            return DEFAULT_SALUTATION  # "Frau X oder Herr Y": not one clear person
        gender = "Frau" if m.group(1) == "Frau" else "Herr"
        last = m.group(4) or m.group(3)
        if last in _NOT_NAMES or (m.group(4) and m.group(3) in _NOT_NAMES):
            continue
        titles = " ".join(t.strip() for t in re.findall(r"(?:Dr|Prof)\.", m.group(2) or ""))
        people.add((gender, f"{titles} {last}".strip()))
    if len(people) != 1:
        return DEFAULT_SALUTATION
    gender, name = people.pop()
    return f"Sehr geehrte Frau {name}," if gender == "Frau" else f"Sehr geehrter Herr {name},"


def sanitize_filename_part(text: str, max_len: int = 60) -> str:
    """Letters/digits (incl. umlauts), '.', '-' stay; everything else becomes '_'."""
    out = re.sub(r"[^\w.\-]+", "_", text or "").replace("__", "_")
    out = re.sub(r"_+", "_", out).strip("_.-")
    return out[:max_len].rstrip("_.-") or "Unbekannt"


def pdf_filename(company: str | None, day: date) -> str:
    return f"Anschreiben_{sanitize_filename_part(company or '')}_{day.isoformat()}.pdf"


def build_document(job: dict, applicant: ApplicantConfig, today: date | None = None) -> dict:
    today = today or date.today()
    sender_lines = [x for x in (applicant.street, applicant.city) if x]
    contact = [x for x in (applicant.email, applicant.phone, applicant.linkedin) if x]
    company = (job.get("company") or "").strip()
    location = (job.get("location") or "").strip()
    letter = job.get("letter") or ""
    title = letter_title(job.get("title") or "", company)
    return {
        "job_id": job.get("id"),
        "sender": {"name": applicant.name, "street": applicant.street, "city": applicant.city,
                   "email": applicant.email, "phone": applicant.phone, "linkedin": applicant.linkedin,
                   "lines": sender_lines, "contact": contact},
        "recipient": {"company": company, "location": location,
                      "lines": [x for x in (company, location) if x]},
        "date": today.strftime("%d.%m.%Y"),
        "place_date": f"{applicant.city}, {today.strftime('%d.%m.%Y')}" if applicant.city else today.strftime("%d.%m.%Y"),
        "subject": f"Bewerbung als {title}" if title else "Bewerbung",
        "salutation": detect_salutation(job.get("description")),
        "body": paragraphs(letter),
        "closing": CLOSING,
        "signature": applicant.name,
        "enclosures": list(applicant.enclosures),
        "letter_origin": job.get("letter_origin"),
        "has_letter": bool(letter.strip()),
        "has_placeholder": has_placeholder(letter),
        "filename": pdf_filename(company, today),
    }


# ---- PDF (fpdf2, bundled Liberation Sans = Arial metrics, full umlaut support) ----------
def pdf_available() -> bool:
    try:
        import fpdf  # noqa: F401
    except ImportError:
        return False
    return (FONT_DIR / "LiberationSans-Regular.ttf").exists()


def render_pdf(doc: dict) -> bytes:
    """A4, one page: the body font shrinks in small steps if the letter would not fit."""
    for size in (11.0, 10.5, 10.0, 9.5, 9.0):
        pdf = _render(doc, size)
        if pdf.page_no() == 1:
            break
    return bytes(pdf.output())


def _render(doc: dict, size: float):
    from fpdf import FPDF

    left, right, width = 25.0, 20.0, 210.0 - 25.0 - 20.0
    pdf = FPDF(format="A4", unit="mm")
    pdf.set_margins(left, 15, right)
    pdf.set_auto_page_break(True, margin=15)
    pdf.add_font("Lib", "", str(FONT_DIR / "LiberationSans-Regular.ttf"))
    pdf.add_font("Lib", "B", str(FONT_DIR / "LiberationSans-Bold.ttf"))
    pdf.set_title(doc["subject"])
    pdf.set_author(doc["sender"]["name"])
    pdf.set_creator("Job-Hunter")
    pdf.add_page()
    ink, muted = (0x22, 0x22, 0x22), (0x55, 0x55, 0x55)

    # Header: name + contact line + accent rule (like the CV)
    pdf.set_xy(left, 16)
    pdf.set_font("Lib", "B", 20)
    pdf.set_text_color(*ACCENT_RGB)
    pdf.cell(width, 9, doc["sender"]["name"], new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Lib", "", 9)
    pdf.set_text_color(*muted)
    pdf.cell(width, 5, "  ·  ".join(doc["sender"]["lines"] + doc["sender"]["contact"]), new_x="LMARGIN", new_y="NEXT")
    pdf.set_draw_color(*ACCENT_RGB)
    pdf.set_line_width(0.6)
    pdf.line(left, pdf.get_y() + 2, 210 - right, pdf.get_y() + 2)

    # Recipient (DIN 5008 address field starts ~45 mm from the top)
    pdf.set_font("Lib", "", 7.5)
    pdf.set_text_color(*muted)
    pdf.set_xy(left, 45)
    back = ", ".join([doc["sender"]["name"]] + doc["sender"]["lines"])
    pdf.cell(85, 4, back, new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Lib", "", 11)
    pdf.set_text_color(*ink)
    pdf.set_y(51)
    for line in doc["recipient"]["lines"]:
        pdf.multi_cell(85, 5.2, line, new_x="LMARGIN", new_y="NEXT")

    # Date (right) + subject
    pdf.set_xy(left, 88)
    pdf.cell(width, 5, doc["place_date"], align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.set_y(98)
    pdf.set_font("Lib", "B", 12)
    pdf.multi_cell(width, 6, doc["subject"], new_x="LMARGIN", new_y="NEXT")
    pdf.ln(5)

    lh = size * 0.5  # ≈ 1.4 line height in mm
    pdf.set_font("Lib", "", size)
    pdf.multi_cell(width, lh, doc["salutation"], new_x="LMARGIN", new_y="NEXT")
    pdf.ln(lh * 0.7)
    for para in doc["body"]:
        pdf.multi_cell(width, lh, para, align="L", new_x="LMARGIN", new_y="NEXT")
        pdf.ln(lh * 0.7)
    pdf.multi_cell(width, lh, doc["closing"], new_x="LMARGIN", new_y="NEXT")
    pdf.ln(lh * 2.2)
    pdf.multi_cell(width, lh, doc["signature"], new_x="LMARGIN", new_y="NEXT")
    if doc["enclosures"]:
        pdf.ln(lh * 1.2)
        pdf.set_font("Lib", "", size - 1.5)
        pdf.set_text_color(*muted)
        pdf.multi_cell(width, lh, "Anlage: " + ", ".join(doc["enclosures"]), new_x="LMARGIN", new_y="NEXT")
    return pdf
