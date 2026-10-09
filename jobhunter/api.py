"""JSON API (/api/v1) for native clients (e.g. the macOS app).

Protected by the same HTTP Basic Auth middleware as the dashboard. Read/write access to
jobs, tracker fields and draft letters, plus starting a search run.

E-mail applications: the server never sends anything itself. `/outbox`, `/email-preview`,
`/approve` and `/send-settings` expose the gating decisions (jobhunter.outbox); the macOS app
sends through Apple Mail and reports back with `POST /jobs/{id}/sent`.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import actions, alerts, letter_doc, letters, pipeline, search_profile, tracker
from .config import Settings
from .db import Database
from .llm import LLMError, generation_busy
from .models import STATUSES
from .outbox import BLOCKER_TEXT, Gate, render_email, send_state
from .views import VIEW_LABELS, VIEWS, annotate, filter_view, outbox_rows, real_sent_ids, view_counts

API_VERSION = 1

SUMMARY_FIELDS = ("id", "title", "company", "location", "url", "source", "published", "fetched_at",
                  "score", "rule_score", "llm_score", "status", "status_updated_at", "applied_date",
                  "salary_min", "salary_max", "letter_origin", "interview_at", "follow_up_at",
                  "close_reason")


def _bool(v: Any) -> bool:
    return bool(v) if v is not None else False


def job_summary(job: dict, send: dict | None = None) -> dict:
    out = {k: job.get(k) for k in SUMMARY_FIELDS}
    out["apply_email"] = job.get("apply_email")
    out["apply_method"] = job.get("apply_method") or ("email" if job.get("apply_email") else "manual")
    out["send_approved"] = bool(job.get("send_approved_at"))
    if send is not None:
        out["send_state"] = send
    out["remote"] = _bool(job.get("remote"))
    out["salary_predicted"] = _bool(job.get("salary_predicted"))
    out["also_seen_on"] = [s for s in (job.get("also_seen_on") or "").split(",") if s]
    out["has_letter"] = bool(job.get("letter"))
    out["source_label"] = alerts.source_label(job.get("source"))
    out["description_length"] = len((job.get("description") or "").strip())
    out["notes"] = job.get("notes") or ""
    if "view" in job:
        out["view"] = job["view"]
        out["apply_label"] = job["apply_label"]
    return out


def _breakdown(bd: dict | None) -> dict:
    bd = bd or {}
    return {
        "keywords": float(bd.get("keywords") or 0),
        "matched": list(bd.get("matched") or []),
        "title": float(bd.get("title") or 0),
        "title_match": bd.get("title_match"),
        "location": float(bd.get("location") or 0),
        "location_reason": bd.get("location_reason"),
        "salary": float(bd.get("salary") or 0),
        "salary_reason": bd.get("salary_reason"),
        "penalty": float(bd.get("penalty") or 0),
        "excluded_in_text": list(bd.get("excluded_in_text") or []),
        "excluded": list(bd.get("excluded") or []),
    }


def job_detail(job: dict, send: dict | None = None) -> dict:
    out = job_summary(job, send)
    out.update(
        description=job.get("description") or "",
        score_breakdown=_breakdown(job.get("score_breakdown")),
        reason=job.get("llm_reason"),
        letter=job.get("letter") or "",
        letter_updated_at=job.get("letter_updated_at"),
        notes=job.get("notes") or "",
        apply_email_source=job.get("apply_email_source"),
    )
    return out


def counters_dict(gate: Gate) -> dict:
    c = gate.counters()
    return {"sent_today": c.sent_today, "sent_total": c.sent_total, "dry_run_total": c.dry_run_total,
            "dry_run_today": c.dry_run_today, "remaining_today": c.remaining_today}


def send_settings_dict(settings: Settings, gate: Gate) -> dict:
    cfg = settings.send
    return {
        "mode": cfg.mode, "dry_run": cfg.dry_run, "kill_switch": cfg.kill_switch,
        "auto_min_score": cfg.auto_min_score, "daily_cap": cfg.daily_cap,
        "company_cooldown_days": cfg.company_cooldown_days, "blocklist": list(cfg.blocklist),
        "require_letter": cfg.require_letter, "from_address": cfg.from_address,
        "sender_name": cfg.sender_name, "subject_template": cfg.subject_template,
        "location_filter": cfg.location_filter,
        "cv_attachment": cfg.cv_attachment, **counters_dict(gate),
        "applicant": applicant_dict(settings),
    }


def applicant_dict(settings: Settings) -> dict:
    a = settings.applicant
    return {"name": a.name, "street": a.street, "city": a.city, "email": a.email, "phone": a.phone,
            "linkedin": a.linkedin, "enclosures": list(a.enclosures)}


def sent_dict(r: dict) -> dict:
    return {"id": r["id"], "job_id": r["job_id"], "company": r.get("company"), "title": r.get("title"),
            "to": r["to_addr"], "subject": r["subject"], "body": r["body"], "sent_at": r["sent_at"],
            "dry_run": bool(r["dry_run"]), "message_id": r.get("message_id"), "trigger": r.get("trigger")}


def email_preview(settings: Settings, db: Database, job: dict) -> dict:
    gate = Gate(settings, db)
    dec = gate.evaluate(job)
    return {
        "job_id": job["id"],
        "apply_email": job.get("apply_email"),
        "apply_method": job.get("apply_method") or ("email" if job.get("apply_email") else "manual"),
        "apply_email_source": job.get("apply_email_source"),
        "mode": settings.send.mode,
        "dry_run": settings.send.dry_run,
        "email": render_email(job, settings.send) if job.get("apply_email") else None,
        "can_send": dec.can_send,
        "auto_eligible": dec.auto_ok,
        "in_outbox": dec.reason is not None,
        "approved": dec.approved,
        "blockers": dec.blockers,
        "auto_blockers": dec.auto_blockers,
        "blocker_texts": [BLOCKER_TEXT.get(b, b) for b in dec.blockers],
        "send_state": send_state(job, gate, dec),
        "sent": [sent_dict(r) for r in db.sent_log(job_id=job["id"])],
        "counters": counters_dict(gate),
    }

class JobUpdate(BaseModel):
    """Partial tracker update. Omitted fields stay unchanged; applied_date=null clears it."""
    model_config = ConfigDict(extra="forbid")
    status: str | None = None
    notes: str | None = Field(default=None, max_length=20000)
    applied_date: str | None = None
    apply_email: str | None = Field(default=None, max_length=320)
    interview_at: str | None = Field(default=None, max_length=40)   # "YYYY-MM-DDTHH:MM", null clears
    follow_up_at: str | None = Field(default=None, max_length=10)   # "YYYY-MM-DD", null clears
    close_reason: str | None = Field(default=None, max_length=40)   # duplikat | kein_interesse | …


class BulkUpdate(BaseModel):
    """Multi-select in the lists: set a status (+ close reason) and/or start KI letters."""
    model_config = ConfigDict(extra="forbid")
    ids: list[int] = Field(min_length=1, max_length=500)
    status: str | None = None
    close_reason: str | None = Field(default=None, max_length=40)
    write_letters: bool = False


class AutoScoreIn(BaseModel):
    auto_min_score: int | None = None  # None = back to config.yaml


class SentReport(BaseModel):
    """What the client reports after sending (or test-sending) through Apple Mail."""
    model_config = ConfigDict(extra="forbid")
    dry_run: bool
    sent_at: str | None = None
    message_id: str | None = Field(default=None, max_length=1000)
    to: str | None = Field(default=None, max_length=320)
    subject: str | None = Field(default=None, max_length=1000)
    body: str | None = Field(default=None, max_length=50000)
    trigger: str | None = Field(default=None, max_length=20)  # manual | approved | auto


class ClientState(BaseModel):
    model_config = ConfigDict(extra="forbid")
    client: str = Field(default="macos", max_length=40)
    auto_send_enabled: bool
    app_version: str | None = Field(default=None, max_length=40)


class SentPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    message_id: str = Field(max_length=1000)


class LetterUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    letter: str = Field(max_length=20000)
    # Who wrote it, e.g. "KI (opencode)" when the Mac app generated it locally. Default "manuell".
    # "vorlage" is reserved for the server's fixed template.
    origin: str | None = Field(default=None, max_length=40)


class AppliedIn(BaseModel):
    """An application confirmation e-mail (StepStone "… ist raus", LinkedIn "… gesendet")."""
    model_config = ConfigDict(extra="ignore")
    source: str = Field(max_length=40)
    title: str = Field(max_length=500)
    company: str = Field(default="", max_length=300)
    location: str = Field(default="", max_length=300)
    url: str = Field(default="", max_length=2000)
    external_id: str = Field(default="", max_length=200)
    applied_at: str = Field(default="", max_length=40)


class AlertJobIn(BaseModel):
    """One job parsed from a job-alert e-mail by the macOS app. Over-long fields are truncated
    (never reject a whole batch because one mail had e.g. a very long list of cities)."""
    model_config = ConfigDict(extra="ignore")
    source: str = Field(max_length=40)              # linkedin-alert | stepstone-alert | indeed-alert
    external_id: str = ""
    title: str
    company: str = ""
    location: str = ""
    url: str = ""
    received_at: str = ""
    description: str | None = None

    @field_validator("external_id", "title", "company", "location", "url", "received_at", "description", mode="before")
    @classmethod
    def _truncate(cls, v, info):
        if v is None:
            return v
        limits = {"external_id": 200, "title": 500, "company": 300, "location": 300, "url": 2000,
                  "received_at": 40, "description": 50000}
        return str(v)[: limits[info.field_name]]


class DescriptionUpdate(BaseModel):
    """"Anzeigentext einfügen": pasted posting text; write_letter=true starts a KI letter
    (in the background) unless the letter was written/edited by the user."""
    model_config = ConfigDict(extra="forbid")
    description: str = Field(max_length=50000)
    write_letter: bool = True


class WriteAll(BaseModel):
    model_config = ConfigDict(extra="forbid")
    view: str | None = None          # auto | manual | today (default: all open jobs)
    limit: int | None = Field(default=None, ge=1, le=100)  # capped at llm.max_per_run


class SearchProfileUpdate(BaseModel):
    """Partial update of the search profile and/or the source settings (validated in
    jobhunter.search_profile). run_now starts a search afterwards, rescore re-scores stored jobs."""
    model_config = ConfigDict(extra="forbid")
    profile: dict[str, Any] | None = None
    sources: dict[str, Any] | None = None
    run_now: bool = False
    rescore: bool = True


class SearchProfilePreview(BaseModel):
    model_config = ConfigDict(extra="forbid")
    profile: dict[str, Any] | None = None
    sources: dict[str, Any] | None = None


class ResetRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    what: str = "all"          # all | profile | sources
    rescore: bool = True


class CVUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(max_length=search_profile.CV_MAX)
    rescore: bool = True


def _require_json(request: Request) -> None:
    # Writes only accept application/json: a cross-site HTML form cannot send it without a
    # CORS preflight, which this server never grants.
    ctype = request.headers.get("content-type", "").split(";")[0].strip().lower()
    if ctype != "application/json":
        raise HTTPException(415, "Content-Type must be application/json")


def _parse_since(value: str | None) -> str | None:
    """`since` is either a number of days (like the dashboard) or an ISO-8601 timestamp."""
    if not value:
        return None
    if value.isdigit():
        return (datetime.now(timezone.utc) - timedelta(days=int(value))).isoformat()
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(422, "since: days or ISO-8601 timestamp expected") from None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat()


def _last_finished_run(db: Database) -> dict | None:
    return next((r for r in db.last_runs(10) if r.get("finished_at")), None)


def build_api_router(settings: Settings, db: Database, t) -> APIRouter:
    router = APIRouter(prefix="/api/v1", tags=["api"])
    write = [Depends(_require_json)]

    def _get(job_id: int) -> dict:
        job = db.get_job(job_id)
        if not job:
            raise HTTPException(404, "job not found")
        return job

    @router.get("/health")
    def health():
        return {
            "ok": True,
            "api_version": API_VERSION,
            "running": pipeline.is_running(),
            "llm_enabled": settings.llm.enabled,
            "llm": f"{settings.llm.provider}:{settings.llm.model}" if settings.llm.enabled else None,
            "letters_running": letters.is_running(),
            "server_time": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        }

    @router.get("/statuses")
    def statuses():
        return [{"id": s, "label": t(f"st_{s}")} for s in STATUSES]

    @router.get("/jobs")
    def list_jobs(status: str | None = None, min_score: int | None = Query(None, ge=0, le=100),
                  source: str | None = None, since: str | None = None, q: str | None = None,
                  view: str | None = None, limit: int = Query(500, ge=1, le=5000)):
        if status and status != "aktiv" and status not in STATUSES:
            raise HTTPException(422, "unknown status")
        if view and view not in VIEWS:
            raise HTTPException(422, f"unknown view (one of {', '.join(VIEWS)})")
        jobs = db.list_jobs(status=status or None, min_score=min_score, source=source or None,
                            since=_parse_since(since), q=(q or "").strip() or None,
                            limit=100000 if view else limit)
        annotate(jobs, real_sent_ids(db), settings.send.blocklist)
        if view:
            jobs = filter_view(jobs, view)[:limit]
        gate = Gate(settings, db)
        items = [job_summary(j, send_state(j, gate, light=True)) for j in jobs]
        return {"count": len(items), "items": items}

    def _detail(job: dict) -> dict:
        annotate([job], real_sent_ids(db), settings.send.blocklist)
        return job_detail(job, send_state(job, Gate(settings, db)))

    @router.get("/views")
    def views():
        counts = view_counts(db, settings.send.blocklist)
        return {"counts": counts, "labels": VIEW_LABELS, "order": list(VIEWS), "today_limit": 10}

    @router.get("/jobs/{job_id}")
    def get_job(job_id: int):
        return _detail(_get(job_id))

    @router.patch("/jobs/{job_id}", dependencies=write)
    def update_job(job_id: int, body: JobUpdate):
        job = _get(job_id)
        kwargs: dict[str, Any] = {"status": body.status}
        if "notes" in body.model_fields_set:
            kwargs["notes"] = body.notes
        for name in ("applied_date", "interview_at", "follow_up_at", "close_reason"):
            if name in body.model_fields_set:
                kwargs[name] = getattr(body, name)
        try:
            if "apply_email" in body.model_fields_set:
                actions.set_apply_email(db, job_id, body.apply_email)
                job = _get(job_id)
            job = actions.update_tracker(db, job, **kwargs)
        except ValueError as exc:
            raise HTTPException(422, f"invalid {exc}") from None
        return _detail(job)

    @router.get("/jobs/{job_id}/history")
    def job_history(job_id: int):
        """Timeline: found, status changes (job_status_history), e-mail sends, interview."""
        job = _get(job_id)
        return {"job_id": job_id, "events": tracker.timeline(db, job)}

    @router.post("/jobs/bulk", dependencies=write)
    def bulk_update(body: BulkUpdate):
        if body.status is None and not body.write_letters:
            raise HTTPException(422, "status or write_letters required")
        if body.status is not None and body.status not in STATUSES:
            raise HTTPException(422, "unknown status")
        jobs = [j for j in (db.get_job(i) for i in dict.fromkeys(body.ids)) if j]
        updated = 0
        if body.status is not None:
            for j in jobs:
                kwargs: dict[str, Any] = {"status": body.status, "history_source": "bulk"}
                if body.status == "absage" and "close_reason" in body.model_fields_set:
                    kwargs["close_reason"] = body.close_reason
                try:
                    actions.update_tracker(db, j, **kwargs)
                except ValueError as exc:
                    raise HTTPException(422, f"invalid {exc}") from None
                updated += 1
        started, hint = False, None
        if body.write_letters:
            if not settings.llm.enabled:
                hint = "Keine KI konfiguriert (llm.provider / OPENCODE_BIN)"
            else:
                fresh = [db.get_job(j["id"]) for j in jobs]
                todo = [j for j in fresh if j and alerts.has_posting_text(j) and j.get("letter_origin") != "manuell"]
                started = letters.start(settings, db, todo) if todo else False
                if not todo:
                    hint = "Keine der Stellen braucht ein KI-Anschreiben (kein Anzeigentext oder eigenes Anschreiben)."
                elif not started:
                    hint = "Die KI ist gerade beschäftigt – bitte später erneut."
        return {"updated": updated, "missing": len(set(body.ids)) - len(jobs), "letters_started": started,
                "hint": hint}

    @router.get("/tracker")
    def get_tracker(q: str | None = None, source: str | None = None,
                    per_column: int = Query(60, ge=1, le=5000)):
        """Kanban columns for all statuses + KPIs/funnel + weekly/source charts + follow-ups
        + upcoming interviews (see jobhunter.tracker)."""
        jobs = db.list_jobs(source=source or None, q=(q or "").strip() or None, limit=100000)
        annotate(jobs, real_sent_ids(db), settings.send.blocklist)
        return tracker.build(db, jobs, settings.applicant.name, per_column=per_column)

    @router.get("/sources")
    def sources():
        """All sources (incl. the job-alert ones, even before the first import) with UI labels."""
        ids = list(dict.fromkeys([*db.sources(), *alerts.ALERT_SOURCES]))
        return [{"id": s, "label": alerts.source_label(s)} for s in ids]

    @router.post("/jobs/import", dependencies=write)
    def import_jobs(body: list[AlertJobIn] = Body(..., max_length=500)):
        """Jobs from job-alert e-mails (parsed by the macOS app from Apple Mail). Dedup against
        existing jobs, rule score, apply manually, no letter until the posting text is pasted."""
        items = [alerts.AlertItem(**it.model_dump(exclude={"description"}), description=it.description or "")
                 for it in body]
        return alerts.import_alert_jobs(settings, db, items).as_dict()

    @router.post("/jobs/applied-confirmations", dependencies=write)
    def applied_confirmations(body: list[AppliedIn] = Body(..., max_length=500)):
        """Applications the user sent himself on StepStone/LinkedIn (confirmation e-mails, read by
        the macOS app): the matching job becomes "beworben"; unknown jobs are added as "beworben"."""
        return alerts.record_applied(settings, db, [alerts.AppliedItem(**it.model_dump()) for it in body])

    @router.put("/jobs/{job_id}/description", dependencies=write)
    def put_description(job_id: int, body: DescriptionUpdate):
        job = alerts.set_description(settings, db, _get(job_id), body.description)
        started = False
        hint = None
        if not alerts.has_posting_text(job):
            hint = alerts.KI_NEEDS_POSTING_HINT
        elif body.write_letter and settings.llm.enabled and job.get("letter_origin") != "manuell":
            started = letters.start(settings, db, [job])
            if not started:
                hint = "Die KI ist gerade beschäftigt – Anschreiben später schreiben."
        return {**_detail(_get(job_id)), "letter_started": started, "hint": hint}

    @router.put("/jobs/{job_id}/letter", dependencies=write)
    def put_letter(job_id: int, body: LetterUpdate):
        _get(job_id)
        origin = (body.origin or "").strip()
        if origin.lower() == "vorlage":
            raise HTTPException(422, "origin 'vorlage' is reserved")
        actions.save_letter(db, job_id, body.letter, origin=origin or "manuell")
        return _detail(_get(job_id))

    # ---- KI letters (llm.provider, e.g. opencode) -------------------------------
    def _llm_info() -> dict:
        return {"provider": settings.llm.provider, "model": settings.llm.model,
                "enabled": settings.llm.enabled, "max_per_run": settings.llm.max_per_run,
                "timeout_s": settings.llm.timeout_s}

    @router.post("/jobs/{job_id}/write-letter", dependencies=write)
    def write_letter(job_id: int, wait: bool = True):
        """Writes the letter with the configured LLM. wait=true (default): synchronous, may take
        up to llm.timeout_s; wait=false: runs in the background (202, see /letters/status)."""
        job = _get(job_id)
        if not settings.llm.enabled:
            return JSONResponse({"detail": "Keine KI konfiguriert (llm.provider / OPENCODE_BIN)",
                                 "llm": _llm_info()}, status_code=503)
        if letters.is_running() or generation_busy():
            return JSONResponse({"detail": "Die KI schreibt gerade – bitte warten.",
                                 "letters": letters.status()}, status_code=409)
        if not wait:
            letters.start(settings, db, [job])
            return JSONResponse({"started": True, "letters": letters.status()}, status_code=202)
        try:
            actions.write_letter(settings, db, job)
        except actions.LLMNotConfigured as exc:
            return JSONResponse({"detail": str(exc)}, status_code=503)
        except LLMError as exc:
            return JSONResponse({"detail": f"KI-Fehler: {exc}"}, status_code=502)
        return _detail(_get(job_id))

    @router.post("/letters/write-all", status_code=202, dependencies=write)
    def write_all(body: WriteAll | None = None):
        body = body or WriteAll()
        if body.view and body.view not in VIEWS:
            raise HTTPException(422, "unknown view")
        if not settings.llm.enabled:
            return JSONResponse({"detail": "Keine KI konfiguriert (llm.provider / OPENCODE_BIN)",
                                 "llm": _llm_info()}, status_code=503)
        jobs = letters.candidates(settings, db, view=body.view, limit=body.limit)
        started = letters.start(settings, db, jobs, only_needed=True)
        return {"started": started, "queued": len(jobs) if started else 0,
                "letters": letters.status(), "llm": _llm_info()}

    @router.get("/letters/status")
    def letters_status():
        return {**letters.status(), "llm": _llm_info()}

    @router.post("/jobs/{job_id}/regenerate", dependencies=write)
    def regenerate(job_id: int):
        job = _get(job_id)
        try:
            actions.regenerate_letter(settings, db, job)
        except LLMError as exc:
            return JSONResponse({"detail": f"LLM-Fehler: {exc}"}, status_code=502)
        return _detail(_get(job_id))

    @router.post("/run", status_code=202, dependencies=write)
    def run():
        started = actions.start_run(settings)
        return {"started": started, "running": True}

    # ---- search profile / sources / CV profile ("Suchprofil & Profil") ------------------------
    def _profile_error(exc: search_profile.ProfileError) -> JSONResponse:
        return JSONResponse({"detail": str(exc), "errors": exc.errors}, status_code=422)

    @router.get("/search-profile")
    def get_search_profile():
        return search_profile.payload(settings, db)

    @router.put("/search-profile", dependencies=write)
    def put_search_profile(body: SearchProfileUpdate):
        try:
            search_profile.save(settings, db, body.profile, body.sources)
        except search_profile.ProfileError as exc:
            return _profile_error(exc)
        rescore = search_profile.start_rescore(settings, db) if body.rescore else False
        run = actions.start_run(settings) if body.run_now else False
        return {**search_profile.payload(settings, db), "rescore_started": rescore, "run_started": run}

    @router.post("/search-profile/reset", dependencies=write)
    def reset_search_profile(body: ResetRequest | None = None):
        body = body or ResetRequest()
        if body.what not in ("all", "profile", "sources"):
            raise HTTPException(422, "what: all | profile | sources")
        search_profile.reset(settings, db, body.what)
        rescore = search_profile.start_rescore(settings, db) if body.rescore else False
        return {**search_profile.payload(settings, db), "rescore_started": rescore}

    @router.post("/search-profile/preview", dependencies=write)
    def preview_search_profile(body: SearchProfilePreview | None = None):
        body = body or SearchProfilePreview()
        try:
            return search_profile.preview(settings, db, body.profile, body.sources)
        except search_profile.ProfileError as exc:
            return _profile_error(exc)
        except search_profile.PreviewBusy as exc:
            return JSONResponse({"detail": str(exc)}, status_code=429, headers={"Retry-After": "10"})

    @router.get("/search-profile/suggestions")
    def search_profile_suggestions():
        return search_profile.suggestions(settings, db)

    @router.post("/rescore", status_code=202, dependencies=write)
    def rescore():
        started = search_profile.start_rescore(settings, db)
        return {"started": started, **search_profile.rescore_status()}

    @router.get("/rescore")
    def rescore_status():
        return search_profile.rescore_status()

    @router.get("/cv-profile")
    def get_cv_profile():
        return search_profile.cv_payload(settings, db)

    @router.put("/cv-profile", dependencies=write)
    def put_cv_profile(body: CVUpdate):
        try:
            backup = search_profile.save_cv(settings, db, body.text)
        except search_profile.ProfileError as exc:
            return _profile_error(exc)
        rescore = search_profile.start_rescore(settings, db) if body.rescore else False
        return {**search_profile.cv_payload(settings, db), "backup": backup, "rescore_started": rescore}

    # ---- e-mail applications ---------------------------------------------------
    @router.get("/jobs/{job_id}/letter-document")
    def letter_document(job_id: int):
        """The full letter as structured fields (sender, recipient, date, subject, salutation,
        body paragraphs, closing) – the macOS app renders the same layout as the PDF."""
        return letter_doc.build_document(_get(job_id), settings.applicant)

    @router.get("/send-settings")
    def get_send_settings():
        return {**send_settings_dict(settings, Gate(settings, db)),
                "auto_min_score_info": search_profile.auto_min_score_info(settings, db)}

    @router.put("/send-settings/auto-min-score")
    def put_auto_min_score(body: AutoScoreIn):
        """Minimum score for automatic sending (50–100). Mode/dry_run/cap stay in config.yaml."""
        try:
            search_profile.set_auto_min_score(settings, db, body.auto_min_score)
        except search_profile.ProfileError as exc:
            return _profile_error(exc)
        return {**send_settings_dict(settings, Gate(settings, db)),
                "auto_min_score_info": search_profile.auto_min_score_info(settings, db)}

    @router.get("/outbox")
    def outbox():
        gate = Gate(settings, db)
        items = gate.outbox()
        return {"mode": settings.send.mode, "dry_run": settings.send.dry_run,
                "kill_switch": settings.send.kill_switch, **counters_dict(gate),
                "count": len(items), "items": items}

    @router.get("/jobs/{job_id}/email-preview")
    def get_email_preview(job_id: int):
        return email_preview(settings, db, _get(job_id))

    @router.post("/jobs/{job_id}/approve", dependencies=write)
    def approve(job_id: int):
        try:
            job = actions.approve(settings, db, _get(job_id))
        except actions.SendBlocked as exc:
            return JSONResponse({"detail": f"Senden nicht erlaubt: {exc}", "blockers": exc.blockers},
                                status_code=409)
        return email_preview(settings, db, job)

    @router.delete("/jobs/{job_id}/approve")
    def unapprove(job_id: int):
        _get(job_id)
        actions.unapprove(db, job_id)
        return email_preview(settings, db, _get(job_id))

    @router.post("/jobs/{job_id}/sent", dependencies=write)
    def sent(job_id: int, body: SentReport):
        job = _get(job_id)
        try:
            rec = actions.record_sent(settings, db, job, **body.model_dump())
        except ValueError as exc:
            raise HTTPException(422, f"invalid {exc}") from None
        return {"sent": sent_dict(rec), "job": _detail(_get(job_id))}

    @router.post("/client-state", dependencies=write)
    def client_state(body: ClientState):
        db.set_client_state(body.client, {"auto_send_enabled": body.auto_send_enabled,
                                          "app_version": body.app_version})
        return {"ok": True}

    @router.get("/outbox/log")
    def outbox_log(limit: int = Query(1000, ge=1, le=5000)):
        """Postausgang rows: waiting / error / sent / test, plus the summary header."""
        return outbox_rows(Gate(settings, db), db, limit=limit)

    @router.get("/sent")
    def sent_log(limit: int = Query(500, ge=1, le=5000), include_dry_run: bool = True):
        gate = Gate(settings, db)
        items = [sent_dict(r) for r in db.sent_log(limit=limit, include_dry_run=include_dry_run)]
        return {"count": len(items), "items": items, **counters_dict(gate)}

    @router.patch("/sent/{sent_id}", dependencies=write)
    def patch_sent(sent_id: int, body: SentPatch):
        if not db.get_sent(sent_id):
            raise HTTPException(404, "sent entry not found")
        db.set_sent_message_id(sent_id, body.message_id)
        return sent_dict(db.get_sent(sent_id))

    @router.get("/stats")
    def stats(min_score: int | None = Query(None, ge=0, le=100)):
        threshold = settings.notify_min_score if min_score is None else min_score
        counts = db.counts_by_status()
        by_status = {s: counts.get(s, 0) for s in STATUSES}
        last = _last_finished_run(db)
        new_high = 0
        if last:
            new_high = sum(1 for j in db.list_jobs(min_score=threshold, since=last["started_at"], limit=5000)
                           if j["fetched_at"] <= last["finished_at"])
        return {
            "total": sum(counts.values()),
            "by_status": by_status,
            "sources": db.sources(),
            "running": pipeline.is_running(),
            "new_since_last_run": last["new_jobs"] if last else 0,
            "new_since_last_run_above_threshold": new_high,
            "threshold": threshold,
            "last_run": ({k: last[k] for k in ("id", "started_at", "finished_at", "new_jobs", "errors")}
                         if last else None),
        }

    return router
