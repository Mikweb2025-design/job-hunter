"""KI letter batches ("Alle Vorlagen schreiben", the daily run, `python -m jobhunter letters`):
one job after the other, never in parallel (the LLM lock in jobhunter.llm serializes every
generation anyway), best score first, capped at llm.max_per_run per batch.

Candidates are open jobs (neu/interessant) whose letter is missing, the fixed template
("vorlage") or still contains "[...]" placeholders. Letters the user wrote or edited
(letter_origin "manuell") are never overwritten. Jobs without real posting text (e.g. from
job-alert e-mails, < 300 characters) are skipped until the user pastes the text."""
from __future__ import annotations
import dataclasses

import logging
import threading
from datetime import datetime, timezone

from . import actions
from .alerts import has_posting_text
from .config import Settings
from .db import Database
from .llm import LLMError, generation_busy, template_letter
from .outbox import ACTIVE_STATUSES, has_placeholder
from .scoring import CVProfile
from .views import annotate, filter_view, real_sent_ids

log = logging.getLogger(__name__)

_lock = threading.Lock()
_state: dict = {"running": False, "total": 0, "done": 0, "failed": 0, "current": None,
                "started_at": None, "finished_at": None, "errors": [], "job_ids": []}


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def status() -> dict:
    with _lock:
        return {**_state, "errors": list(_state["errors"]), "job_ids": list(_state["job_ids"]),
                "busy": _state["running"] or generation_busy()}


def is_running() -> bool:
    with _lock:
        return _state["running"]


def needs_letter(job: dict) -> bool:
    letter = (job.get("letter") or "").strip()
    if not letter:
        return True
    if job.get("letter_origin") == "manuell":
        return False  # written/edited by the user: never replaced automatically
    return job.get("letter_origin") == "vorlage" or has_placeholder(letter)


def candidates(settings: Settings, db: Database, view: str | None = None, limit: int | None = None,
               capped: bool = True) -> list[dict]:
    """Open jobs (neu/interessant, score > 0, posting text >= 300 chars) without a real letter
    (empty, template or "[...]"),
    best score first; optionally only one view (auto/manual/today). At most llm.max_per_run
    (or `limit`, also capped) unless capped=False."""
    cap = max(1, settings.llm.max_per_run)
    if capped:
        limit = cap if not limit else max(1, min(limit, cap))
    jobs = annotate(db.list_jobs(limit=100000), real_sent_ids(db), settings.send.blocklist)
    if view:
        jobs = filter_view(jobs, view, limit=100000)
    jobs = [j for j in jobs if j.get("status") in ACTIVE_STATUSES and needs_letter(j) and (j.get("score") or 0) > 0
            and has_posting_text(j)]  # no posting text: "Anzeigentext einfügen, dann KI-Anschreiben"
    # E-mail jobs first (they are the ones that can actually be sent), then best score.
    jobs.sort(key=lambda j: (bool(j.get("apply_email")), j.get("score") or 0, j.get("fetched_at") or ""), reverse=True)
    return jobs[:limit] if limit else jobs


def fix_old_templates(settings: Settings, db: Database, dry_run: bool = False) -> list[int]:
    """One-off migration: old template letters with "[...]" placeholders (origin "vorlage" or
    none) get the new complete template (still origin "vorlage", so the KI rewrites them and the
    send rules keep treating them as templates). "manuell" and KI letters stay untouched.
    Returns the affected job ids."""
    cv = CVProfile.load(settings.cv_path, settings.profile.keyword_weights)
    ids = []
    for job in db.list_jobs(limit=100000):
        if job.get("letter_origin") in (None, "", "vorlage") and has_placeholder(job.get("letter")):
            ids.append(job["id"])
            if not dry_run:
                db.update_job(job["id"], letter=template_letter(cv, job), letter_origin="vorlage",
                              letter_updated_at=_now())
    return ids


def start(settings: Settings, db: Database, jobs: list[dict], only_needed: bool = False) -> bool:
    """Write letters for `jobs` in a background thread. False if a batch is already running
    or nothing to do. only_needed: skip jobs that got a real letter meanwhile."""
    if not jobs or not _begin(jobs):
        return False
    threading.Thread(target=_run, args=(settings, db, [j["id"] for j in jobs], None, only_needed), daemon=True,
                     name="letters").start()
    return True


def run_sync(settings: Settings, db: Database, jobs: list[dict], progress=None) -> dict | None:
    """Same as start(), but in the calling thread (daily run, CLI). Returns the final status,
    or None if another batch is running. `progress(job, error_or_None)` after each job."""
    if not jobs or not _begin(jobs):
        return None
    _run(settings, db, [j["id"] for j in jobs], progress, True)
    return status()


def _begin(jobs: list[dict]) -> bool:
    with _lock:
        if _state["running"]:
            return False
        _state.update(running=True, total=len(jobs), done=0, failed=0, current=None, started_at=_now(),
                      finished_at=None, errors=[], job_ids=[j["id"] for j in jobs])
    return True


def _attempt_settings(settings: Settings) -> list[Settings]:
    """Settings per attempt: the configured model (1 + retries times), then the fallback model if set."""
    attempts = [settings] * (1 + max(0, settings.llm.retries))
    fb = (settings.llm.fallback_model or "").strip()
    if fb and fb != settings.llm.model:
        attempts.append(dataclasses.replace(settings, llm=dataclasses.replace(settings.llm, model=fb)))
    return attempts


def _run(settings: Settings, db: Database, job_ids: list[int], progress=None, only_needed: bool = False) -> None:
    try:
        for job_id in job_ids:
            job = db.get_job(job_id)
            if not job or (only_needed and not needs_letter(job)):  # e.g. edited by the user meanwhile
                continue
            with _lock:
                _state["current"] = {"id": job_id, "title": job.get("title"), "company": job.get("company")}
            error = None
            for attempt, attempt_settings in enumerate(_attempt_settings(settings), start=1):
                try:
                    actions.write_letter(attempt_settings, db, job)
                    with _lock:
                        _state["done"] += 1
                    error = None
                    break
                except actions.LLMNotConfigured as exc:
                    error = str(exc)
                    break
                except LLMError as exc:  # timeout or rejected output: output varies, so retry
                    log.info("letter for job %s failed (attempt %s, %s): %s",
                             job_id, attempt, attempt_settings.llm.model, exc)
                    error = str(exc)
                except Exception as exc:  # never leave the batch "running" forever
                    log.exception("letter for job %s crashed", job_id)
                    error = str(exc)
                    break
            if error:
                with _lock:
                    _state["failed"] += 1
                    _state["errors"].append({"id": job_id, "title": job.get("title"), "error": error})
            if progress:
                progress(job, error)
    finally:
        with _lock:
            _state.update(running=False, current=None, finished_at=_now())
