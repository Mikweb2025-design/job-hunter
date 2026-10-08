"""One fetch → dedup → score → (LLM) → notify cycle.

Never submits applications and never logs in to job boards: it only reads public search
APIs/feeds and stores drafts locally. E-mail applications are sent by the macOS app
(Apple Mail) under the rules in jobhunter.outbox.
"""
from __future__ import annotations

import logging
import threading
from dataclasses import dataclass, field

from .config import Settings
from .db import Database
from .dedup import dedup_key, dedupe
from .llm import get_llm, template_letter
from .location import location_ok, location_label
from .models import JobPosting
from .notify import format_message, send_telegram
from .scoring import CVProfile, find_keywords, score_job
from .sources import Source, build_sources

log = logging.getLogger(__name__)
_run_lock = threading.Lock()


@dataclass
class RunReport:
    fetched: dict[str, int] = field(default_factory=dict)
    skipped: dict[str, str] = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)
    new_ids: list[int] = field(default_factory=list)
    llm_done: int = 0
    notified: int = 0

    def summary(self) -> str:
        parts = [f"{k}: {v}" for k, v in self.fetched.items()]
        parts += [f"{k}: übersprungen ({v})" for k, v in self.skipped.items()]
        return (f"Quellen [{', '.join(parts)}] · neu: {len(self.new_ids)} · LLM: {self.llm_done}"
                f" · benachrichtigt: {self.notified} · Fehler: {len(self.errors)}")


def is_running() -> bool:
    return _run_lock.locked()


def run_cycle(settings: Settings, db: Database | None = None,
              sources: list[Source] | None = None, notify: bool = True) -> RunReport:
    if not _run_lock.acquire(blocking=False):
        rep = RunReport()
        rep.errors.append("Ein Lauf ist bereits aktiv")
        return rep
    try:
        return _run(settings, db or Database(settings.db_path), sources, notify)
    finally:
        _run_lock.release()


def _run(settings: Settings, db: Database, sources: list[Source] | None, notify: bool) -> RunReport:
    rep = RunReport()
    run_id = db.start_run()
    profile = settings.profile
    cv = CVProfile.load(settings.cv_path, profile.keyword_weights)
    if not cv.text:
        rep.errors.append(f"CV-Profil fehlt: {settings.cv_path}")

    # 1) fetch
    sources = sources if sources is not None else build_sources(settings.sources)
    by_source: dict[str, Source] = {}
    postings: list[JobPosting] = []
    for src in sources:
        ok, why = src.is_configured()
        if not ok:
            rep.skipped[src.name] = why
            continue
        try:
            got = src.fetch(profile)
            rep.fetched[src.name] = len(got)
            postings.extend(got)
            for p in got:
                by_source.setdefault(p.source, src)
        except Exception as exc:  # a broken source must not stop the run
            log.exception("source %s failed", src.name)
            rep.errors.append(f"{src.name}: {exc}")
            rep.fetched[src.name] = 0

    # 2) dedup (within batch, then against DB)
    unique = dedupe(postings)
    existing = db.existing_keys([dedup_key(p.title, p.company) for p in unique])
    new: list[JobPosting] = []
    for p in unique:
        if dedup_key(p.title, p.company) in existing:
            db.note_duplicate(p)
        else:
            new.append(p)

    # 3) enrich (details) + rule score + store
    details_left = settings.max_details_per_run
    for p in new:
        src = by_source.get(p.source)
        title_excluded = find_keywords(p.title, profile.excluded_title_keywords + profile.excluded_keywords)
        if src is not None and details_left > 0 and len(p.description) < 400 and not title_excluded:
            try:
                src.enrich(p)
            except Exception as exc:
                log.info("enrich failed for %s: %s", p.source_id, exc)
            details_left -= 1
        res = score_job(p, profile, cv)
        job_id = db.insert_job(p, res.score, res.breakdown)
        if job_id:
            rep.new_ids.append(job_id)
            # No relocation: jobs outside Berlin/Brandenburg without explicit
            # 100% remote are filed as "zu weit weg" right away – they never
            # enter the automatic outbox.
            stored = db.get_job(job_id)
            if stored and stored.get("status") == "neu" and not location_ok(stored)[0]:
                db.update_job(job_id, status="zu_weit",
                              notes=((stored.get("notes") or "") + "\n" if stored.get("notes") else "")
                              + f"Automatisch als „Zu weit weg“ markiert ({location_label(stored)}).")

    # 4) letters. a) every new job (score > 0) gets the complete no-LLM template at once, so no
    #    job is ever without a letter; old "[...]" templates are replaced the same way.
    for job_id in rep.new_ids:
        job = db.get_job(job_id)
        if job and job["rule_score"] > 0 and not (job.get("letter") or "").strip():
            db.set_llm_result(job_id, None, None, template_letter(cv, job), "vorlage")
    from . import letters  # local import: letters -> actions -> pipeline
    letters.fix_old_templates(settings, db)
    #    b) KI: ALL open jobs whose letter is missing or still a template, best score first,
    #    one at a time, at most llm.max_per_run per run ("manuell" letters are never touched).
    if get_llm(settings.llm):
        todo = letters.candidates(settings, db)
        result = letters.run_sync(settings, db, todo) if todo else None
        if result:
            rep.llm_done += result["done"]
            rep.errors += [f"LLM ({e['id']}): {e['error']}" for e in result["errors"]]
        elif todo:
            rep.errors.append("KI-Anschreiben übersprungen: ein anderer Anschreiben-Lauf ist aktiv")

    # 5) notify
    if notify and settings.telegram_token and settings.telegram_chat_id:
        top = db.unnotified(settings.notify_min_score, settings.notify_max_items)
        if top and send_telegram(settings.telegram_token, settings.telegram_chat_id,
                                 format_message(top, _public_url())):
            db.mark_notified([j["id"] for j in top])
            rep.notified = len(top)

    db.finish_run(run_id, {"fetched": rep.fetched, "skipped": rep.skipped, "llm": rep.llm_done},
                  len(rep.new_ids), rep.errors)
    log.info("run finished: %s", rep.summary())
    return rep


def _public_url() -> str | None:
    import os
    return os.environ.get("PUBLIC_URL") or None


def rescore_all(settings: Settings, db: Database | None = None) -> int:
    """Recompute rule scores after editing config.yaml or cv_profile.md; re-detect
    application e-mail addresses (manual entries are kept). Also files still-open
    jobs outside the home region as "zu_weit" (the relocation filter)."""
    db = db or Database(settings.db_path)
    db.backfill_apply_email()
    cv = CVProfile.load(settings.cv_path, settings.profile.keyword_weights)
    n = 0
    for j in db.list_jobs(limit=100000):
        p = JobPosting(source=j["source"], source_id=j["source_id"] or "", title=j["title"],
                       company=j["company"] or "", location=j["location"] or "",
                       description=j["description"] or "", remote=bool(j["remote"]),
                       salary_min=j["salary_min"], salary_max=j["salary_max"],
                       salary_predicted=bool(j["salary_predicted"]))
        res = score_job(p, settings.profile, cv)
        db.set_rule_score(j["id"], res.score, res.breakdown)
        if j.get("status") == "neu" and not location_ok(j)[0]:
            db.update_job(j["id"], status="zu_weit",
                          notes=((j.get("notes") or "") + "\n" if j.get("notes") else "")
                          + f"Als „Zu weit weg“ markiert ({location_label(j)}).")
        n += 1
    return n
