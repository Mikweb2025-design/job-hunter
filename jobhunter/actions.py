"""Write operations shared by the HTML dashboard and the JSON API.

Nothing here sends e-mails: actions only change local state (tracker fields, draft letters,
send approvals, the sent log) or start a search run. Sending is done by the macOS app.
"""
from __future__ import annotations

import threading
from datetime import date, datetime, timezone

from . import pipeline
from .config import Settings
from .db import Database
from .llm import get_llm, template_letter
from .apply_email import valid_email
from .models import STATUSES
from .outbox import BLOCKER_TEXT, Gate, render_email
from .scoring import CVProfile

_UNSET = object()


def update_tracker(db: Database, job: dict, status: str | None = None, notes=_UNSET,
                   applied_date=_UNSET) -> dict:
    """Validate and apply status/notes/applied_date changes.

    Raises ValueError for an unknown status or a malformed date. When the status becomes
    "beworben" without an applied date, today's date (or the existing one) is used.
    Returns the updated job.
    """
    status = status or job["status"]
    if status not in STATUSES:
        raise ValueError("status")
    if applied_date is _UNSET:
        applied_date = job.get("applied_date")
    if applied_date:
        try:
            date.fromisoformat(applied_date)
        except (TypeError, ValueError):
            raise ValueError("applied_date") from None
    if status == "beworben" and not applied_date:
        applied_date = job.get("applied_date") or date.today().isoformat()
    fields: dict = {"applied_date": applied_date or None}
    if notes is not _UNSET:
        fields["notes"] = notes or ""
    if status != job["status"]:
        fields.update(status=status, status_updated_at=datetime.now(timezone.utc).isoformat())
    db.update_job(job["id"], **fields)
    return db.get_job(job["id"])


def save_letter(db: Database, job_id: int, letter: str, origin: str = "manuell") -> None:
    db.update_job(job_id, letter=letter, letter_origin=origin,
                  letter_updated_at=datetime.now(timezone.utc).isoformat())


def regenerate_letter(settings: Settings, db: Database, job: dict) -> None:
    """Re-run the LLM (or the fixed template without LLM). Raises LLMError on LLM failure."""
    cv = CVProfile.load(settings.cv_path, settings.profile.keyword_weights)
    llm = get_llm(settings.llm)
    if llm:
        r = llm.evaluate(cv.text, job, settings.profile.min_salary)
        db.set_llm_result(job["id"], r.score, r.reason, r.letter, r.origin)
        return
    db.set_llm_result(job["id"], None, None, template_letter(cv, job), "vorlage")


class LLMNotConfigured(Exception):
    pass


def write_letter(settings: Settings, db: Database, job: dict) -> dict:
    """Write the cover letter with the configured LLM (e.g. opencode). Never falls back to the
    template. Raises LLMNotConfigured, or LLMError on failure / unusable output."""
    llm = get_llm(settings.llm)
    if not llm:
        raise LLMNotConfigured("Keine KI konfiguriert (llm.provider)")
    cv = CVProfile.load(settings.cv_path, settings.profile.keyword_weights)
    r = llm.write_letter(cv.text, job, settings.profile.min_salary)
    db.set_llm_result(job["id"], r.score, r.reason or None, r.letter, r.origin)
    return db.get_job(job["id"])


def start_run(settings: Settings) -> bool:
    """Start a search run in the background. Returns False if one is already running."""
    if pipeline.is_running():
        return False
    threading.Thread(target=pipeline.run_cycle, args=(settings,), daemon=True).start()
    return True


class SendBlocked(Exception):
    def __init__(self, blockers: list[str]):
        super().__init__(", ".join(BLOCKER_TEXT.get(b, b) for b in blockers))
        self.blockers = blockers


def set_apply_email(db: Database, job_id: int, email: str | None) -> None:
    """Manual override of the detected address ("" / None = apply manually)."""
    email = (email or "").strip().lower()
    if email and not valid_email(email):
        raise ValueError("apply_email")
    db.update_job(job_id, apply_email=email or None, apply_method="email" if email else "manual",
                  apply_email_source="manuell")


def approve(settings: Settings, db: Database, job: dict) -> dict:
    """Mark a job as approved for sending. Raises SendBlocked if a rule forbids it."""
    dec = Gate(settings, db).evaluate(job)
    if not dec.can_send:
        raise SendBlocked(dec.blockers)
    db.update_job(job["id"], send_approved_at=datetime.now(timezone.utc).replace(microsecond=0).isoformat())
    return db.get_job(job["id"])


def unapprove(db: Database, job_id: int) -> None:
    db.update_job(job_id, send_approved_at=None)


def record_sent(settings: Settings, db: Database, job: dict, *, dry_run: bool, sent_at: str | None = None,
                message_id: str | None = None, to: str | None = None, subject: str | None = None,
                body: str | None = None, trigger: str | None = None) -> dict:
    """Log a send reported by a client. A real send marks the job "beworben" (applied today)."""
    now = datetime.now(timezone.utc)
    when = now
    if sent_at:
        try:
            when = datetime.fromisoformat(sent_at.replace("Z", "+00:00"))
        except ValueError:
            raise ValueError("sent_at") from None
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
    when = when.astimezone(timezone.utc).replace(microsecond=0)
    email = render_email(job, settings.send)
    sent_id = db.add_sent(job, to or email["to"] or "", subject or email["subject"], body or email["body"],
                          when.isoformat(), dry_run, message_id, trigger)
    if not dry_run:
        from zoneinfo import ZoneInfo
        try:
            day = when.astimezone(ZoneInfo(settings.timezone)).date().isoformat()
        except Exception:
            day = when.date().isoformat()
        job = update_tracker(db, job, status="beworben", applied_date=job.get("applied_date") or day)
        db.update_job(job["id"], send_approved_at=None)
    return db.get_sent(sent_id)
