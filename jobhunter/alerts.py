"""Jobs from job-alert e-mails (LinkedIn, StepStone, Indeed).

The job boards have no usable public API and their terms forbid bots/scraping, so the server
never contacts them. Instead the macOS app reads the alert e-mails the user receives in Apple
Mail (read-only), parses title/company/location/link and posts them to
`POST /api/v1/jobs/import`.

Alert jobs carry no posting text: they are scored on title + location only, are always
"apply manually" (no address), get no letter at import and no automatic KI letter until the
user pastes the posting text ("Anzeigentext einfügen", see `set_description`).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlsplit

from .config import Settings
from .db import Database
from .dedup import dedup_key
from .models import JobPosting
from .scoring import CVProfile, score_job

ALERT_SOURCES = {
    "linkedin-alert": "LinkedIn (Job-Alert)",
    "stepstone-alert": "StepStone (Job-Alert)",
    "indeed-alert": "Indeed (Job-Alert)",
}
SOURCE_LABELS = {
    "arbeitsagentur": "Arbeitsagentur",
    "adzuna": "Adzuna",
    "rss": "RSS",
    "arbeitnow": "Arbeitnow",
    "remotive": "Remotive",
    "jobicy": "Jobicy",
    "berlinstartupjobs": "Berlin Startup Jobs",
    "greenhouse": "Karriereseite (Greenhouse)",
    "lever": "Karriereseite (Lever)",
    "personio": "Karriereseite (Personio)",
    "smartrecruiters": "Karriereseite (SmartRecruiters)",
    **ALERT_SOURCES,
}
# Below this many characters of posting text no KI letter is written automatically.
MIN_DESCRIPTION_FOR_KI = 300
KI_NEEDS_POSTING_HINT = "Anzeigentext einfügen, dann KI-Anschreiben"


def source_label(source: str | None) -> str:
    s = source or ""
    return SOURCE_LABELS.get(s, s[:1].upper() + s[1:])


def is_alert_source(source: str | None) -> bool:
    return (source or "") in ALERT_SOURCES


def has_posting_text(job: dict) -> bool:
    return len((job.get("description") or "").strip()) >= MIN_DESCRIPTION_FOR_KI


_LINKEDIN_ID = re.compile(r"/jobs/view/(?:[^/?#]*?-)?(\d{6,})")
_STEPSTONE_ID = re.compile(r"--(\d{5,})(?:-inline)?\.html")
_INDEED_JK = re.compile(r"^[0-9a-f]{10,20}$", re.I)


def canonical_url(source: str, url: str, external_id: str = "") -> str:
    """Stable link without tracking parameters (or "" if it is not a link of that board)."""
    url = (url or "").strip()
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()
    if source == "linkedin-alert":
        m = _LINKEDIN_ID.search(parts.path) if host.endswith("linkedin.com") else None
        job_id = m.group(1) if m else (external_id if external_id.isdigit() else "")
        return f"https://www.linkedin.com/jobs/view/{job_id}/" if job_id else ""
    if source == "stepstone-alert":
        if host.endswith("stepstone.de") and _STEPSTONE_ID.search(parts.path):
            return f"https://www.stepstone.de{parts.path}"
        return ""
    if source == "indeed-alert":
        jk = (parse_qs(parts.query).get("jk") or [""])[0] if host.endswith("indeed.com") else ""
        jk = jk or external_id
        return f"https://de.indeed.com/viewjob?jk={jk}" if _INDEED_JK.match(jk or "") else ""
    return ""


@dataclass
class AlertItem:
    source: str
    external_id: str
    title: str
    company: str = ""
    location: str = ""
    url: str = ""
    received_at: str = ""
    description: str = ""


@dataclass
class ImportReport:
    received: int = 0
    imported: list[int] = field(default_factory=list)
    duplicates: list[int] = field(default_factory=list)
    corrected: list[int] = field(default_factory=list)
    invalid: int = 0
    items: list[dict] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {"received": self.received, "imported": len(self.imported), "duplicates": len(self.duplicates),
                "corrected": len(self.corrected), "corrected_ids": self.corrected,
                "invalid": self.invalid, "imported_ids": self.imported, "duplicate_ids": self.duplicates,
                "items": self.items}


def _published(received_at: str) -> str:
    if not received_at:
        return ""
    try:
        dt = datetime.fromisoformat(received_at.replace("Z", "+00:00"))
    except ValueError:
        return ""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).date().isoformat()


def _existing_by_source_id(db: Database, source: str, source_id: str) -> dict | None:
    with db.conn() as c:
        row = c.execute("SELECT id FROM jobs WHERE source=? AND source_id=?", (source, source_id)).fetchone()
    return db.get_job(row["id"]) if row else None


def _existing_by_key(db: Database, key: str) -> dict | None:
    with db.conn() as c:
        row = c.execute("SELECT id FROM jobs WHERE dedup_key=?", (key,)).fetchone()
    return db.get_job(row["id"]) if row else None


def _correctable(job: dict) -> bool:
    """Only untouched jobs are corrected: still "neu", no letter written/edited by the user."""
    return job.get("status") == "neu" and job.get("letter_origin") != "manuell"


def import_alert_jobs(settings: Settings, db: Database, items: list[AlertItem]) -> ImportReport:
    """Insert new alert jobs (rule-scored, apply manually, no letter). A job we already have
    (same board id, or same normalized title + company from any source) is not inserted again:
    the alert source is added to `also_seen_on` instead."""
    rep = ImportReport(received=len(items))
    cv = CVProfile.load(settings.cv_path, settings.profile.keyword_weights)
    seen_keys: set[str] = set()
    for it in items:
        title, company = (it.title or "").strip(), (it.company or "").strip()
        url = canonical_url(it.source, it.url, it.external_id)
        ext = (it.external_id or "").strip()
        if it.source not in ALERT_SOURCES or not title or not (url or ext):
            rep.invalid += 1
            rep.items.append({"external_id": ext, "source": it.source, "result": "invalid"})
            continue
        key = dedup_key(title, company)
        p = JobPosting(source=it.source, source_id=ext, title=title, company=company,
                       location=(it.location or "").strip(), url=url,
                       description=(it.description or "").strip(), published=_published(it.received_at))
        existing = _existing_by_source_id(db, it.source, ext) if ext else None
        if existing and existing["dedup_key"] != key and _correctable(existing) and not _existing_by_key(db, key):
            # Same board id, but an older app version parsed the mail wrongly (e.g. title
            # "Neue Jobs entsprechen Ihren Einstellungen." / "Passt hervorragend"): correct it.
            db.update_job(existing["id"], title=title, company=company, location=p.location,
                          dedup_key=key, url=url or existing.get("url"))
            fixed = db.get_job(existing["id"]) or existing
            res = score_job(JobPosting(source=it.source, source_id=ext, title=title, company=company,
                                       location=p.location, url=url,
                                       description=fixed.get("description") or p.description), settings.profile, cv)
            db.set_rule_score(existing["id"], res.score, res.breakdown)
            rep.corrected.append(existing["id"])
            rep.items.append({"external_id": ext, "source": it.source, "result": "corrected", "job_id": existing["id"]})
            seen_keys.add(key)
            continue
        existing = existing or _existing_by_key(db, key)
        if existing or key in seen_keys:
            if existing:
                if existing["dedup_key"] == key:
                    db.note_duplicate(p)  # adds the alert source to also_seen_on, fills gaps
                rep.duplicates.append(existing["id"])
            rep.items.append({"external_id": ext, "source": it.source, "result": "duplicate",
                              "job_id": existing["id"] if existing else None})
            continue
        seen_keys.add(key)
        res = score_job(p, settings.profile, cv)
        job_id = db.insert_job(p, res.score, res.breakdown)
        if job_id is None:  # raced with another insert of the same key
            rep.items.append({"external_id": ext, "source": it.source, "result": "duplicate"})
            continue
        # Alerts never carry an application address: always "apply manually".
        db.update_job(job_id, apply_email=None, apply_method="manual", apply_email_source=None)
        rep.imported.append(job_id)
        rep.items.append({"external_id": ext, "source": it.source, "result": "new", "job_id": job_id})
    return rep


def set_description(settings: Settings, db: Database, job: dict, text: str) -> dict:
    """"Anzeigentext einfügen": store the pasted posting text and re-score the job.
    The application address is NOT re-detected here (the user sets it in the e-mail box if
    he wants an e-mail application). Returns the updated job."""
    text = (text or "").strip()
    db.update_job(job["id"], description=text)
    job = db.get_job(job["id"])
    cv = CVProfile.load(settings.cv_path, settings.profile.keyword_weights)
    p = JobPosting(source=job["source"], source_id=job["source_id"] or "", title=job["title"],
                   company=job["company"] or "", location=job["location"] or "", description=text,
                   remote=bool(job["remote"]), salary_min=job["salary_min"], salary_max=job["salary_max"],
                   salary_predicted=bool(job["salary_predicted"]))
    res = score_job(p, settings.profile, cv)
    db.set_rule_score(job["id"], res.score, res.breakdown)
    return db.get_job(job["id"])
