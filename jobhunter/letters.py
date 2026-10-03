"""Background letter writing ("Alle Vorlagen schreiben"): one job after the other, never in
parallel (the LLM lock in jobhunter.llm serializes every generation anyway), capped at
llm.max_per_run per batch."""
from __future__ import annotations

import logging
import threading
from datetime import datetime, timezone

from . import actions
from .config import Settings
from .db import Database
from .llm import LLMError, generation_busy
from .outbox import ACTIVE_STATUSES, has_placeholder
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
    return not letter or job.get("letter_origin") == "vorlage" or has_placeholder(letter)


def candidates(settings: Settings, db: Database, view: str | None = None, limit: int | None = None) -> list[dict]:
    """Open jobs (neu/interessant) without a real letter (empty, template or "[...]"), best
    score first; optionally only one view (auto/manual/today). At most llm.max_per_run."""
    cap = max(1, settings.llm.max_per_run)
    limit = cap if not limit else max(1, min(limit, cap))
    jobs = annotate(db.list_jobs(limit=100000), real_sent_ids(db), settings.send.blocklist)
    if view:
        jobs = filter_view(jobs, view, limit=100000)
    jobs = [j for j in jobs if j.get("status") in ACTIVE_STATUSES and needs_letter(j)]
    jobs.sort(key=lambda j: (j.get("score") or 0, j.get("fetched_at") or ""), reverse=True)
    return jobs[:limit]


def start(settings: Settings, db: Database, jobs: list[dict]) -> bool:
    """Write letters for `jobs` in a background thread. False if a batch is already running
    or nothing to do."""
    if not jobs:
        return False
    with _lock:
        if _state["running"]:
            return False
        _state.update(running=True, total=len(jobs), done=0, failed=0, current=None, started_at=_now(),
                      finished_at=None, errors=[], job_ids=[j["id"] for j in jobs])
    threading.Thread(target=_run, args=(settings, db, [j["id"] for j in jobs]), daemon=True,
                     name="letters").start()
    return True


def _run(settings: Settings, db: Database, job_ids: list[int]) -> None:
    try:
        for job_id in job_ids:
            job = db.get_job(job_id)
            if not job:
                continue
            with _lock:
                _state["current"] = {"id": job_id, "title": job.get("title"), "company": job.get("company")}
            try:
                actions.write_letter(settings, db, job)
                with _lock:
                    _state["done"] += 1
            except (LLMError, actions.LLMNotConfigured) as exc:
                log.info("letter for job %s failed: %s", job_id, exc)
                with _lock:
                    _state["failed"] += 1
                    _state["errors"].append({"id": job_id, "title": job.get("title"), "error": str(exc)})
            except Exception as exc:  # never leave the batch "running" forever
                log.exception("letter for job %s crashed", job_id)
                with _lock:
                    _state["failed"] += 1
                    _state["errors"].append({"id": job_id, "title": job.get("title"), "error": str(exc)})
    finally:
        with _lock:
            _state.update(running=False, current=None, finished_at=_now())
