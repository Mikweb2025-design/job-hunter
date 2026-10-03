"""FastAPI dashboard (server-rendered Jinja2) + daily scheduler."""
from __future__ import annotations

import os
import base64
import binascii
import logging
import secrets
import threading
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode

from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from . import actions, letters, pipeline
from .api import build_api_router
from .config import Settings, load_settings
from .db import Database
from .export import to_csv, to_xlsx
from .i18n import translator
from .llm import LLMError
from .models import STATUSES
from .outbox import BLOCKER_TEXT, Gate, render_email, send_state, status_summary
from .views import VIEW_LABELS, VIEWS, annotate, filter_view, outbox_rows, real_sent_ids, view_counts

log = logging.getLogger(__name__)
HERE = Path(__file__).parent


def _start_scheduler(settings: Settings):
    from apscheduler.schedulers.background import BackgroundScheduler
    from apscheduler.triggers.cron import CronTrigger

    sched = BackgroundScheduler(timezone=settings.timezone)
    sched.add_job(lambda: pipeline.run_cycle(settings),
                  CronTrigger.from_crontab(settings.cron, timezone=settings.timezone),
                  id="daily-run", max_instances=1, coalesce=True, misfire_grace_time=3600)
    sched.start()
    log.info("scheduler started: cron=%r tz=%s next=%s", settings.cron, settings.timezone,
             sched.get_job("daily-run").next_run_time)
    if settings.run_on_start:
        threading.Thread(target=pipeline.run_cycle, args=(settings,), daemon=True).start()
    return sched


def create_app(settings: Settings | None = None, db: Database | None = None,
               start_scheduler: bool = False) -> FastAPI:
    settings = settings or load_settings()
    db = db or Database(settings.db_path)
    t = translator(settings.ui_lang)
    auth_enabled = bool(settings.dashboard_user and settings.dashboard_password)
    if not auth_enabled:
        log.warning("DASHBOARD_USER/DASHBOARD_PASSWORD not set – dashboard has NO authentication")

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        sched = _start_scheduler(settings) if start_scheduler else None
        app.state.scheduler = sched
        yield
        if sched:
            sched.shutdown(wait=False)

    app = FastAPI(title="Job-Hunter", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
    # Optional URL prefix when served behind a reverse proxy in a sub-folder (e.g. /jobs).
    base = "/" + os.environ.get("BASE_PATH", "").strip().strip("/")
    base = "" if base == "/" else base
    templates = Jinja2Templates(directory=HERE / "templates")
    templates.env.globals.update(base=base, t=t, STATUSES=STATUSES, auth_enabled=auth_enabled, lang=settings.ui_lang,
                                 BLOCKER_TEXT=BLOCKER_TEXT)
    # Evaluated on every page render: the send banner must always show the live state.
    templates.env.globals["send_status"] = lambda: status_summary(settings, Gate(settings, db), db.client_states())
    templates.env.globals["view_counts"] = lambda: view_counts(db, settings.send.blocklist)
    templates.env.globals.update(VIEW_LABELS=VIEW_LABELS, NAV_VIEWS=VIEWS)
    llm_name = f"{settings.llm.provider}:{settings.llm.model}"
    templates.env.globals["ki"] = lambda: {"enabled": settings.llm.enabled, "label": llm_name,
                                           "provider": settings.llm.provider,
                                           "max": settings.llm.max_per_run, **letters.status()}

    @app.middleware("http")
    async def basic_auth(request: Request, call_next):
        if not auth_enabled or request.url.path == "/healthz":
            return await call_next(request)
        header = request.headers.get("authorization", "")
        if header.lower().startswith("basic "):
            try:
                user, _, pwd = base64.b64decode(header[6:]).decode("utf-8").partition(":")
            except (binascii.Error, UnicodeDecodeError):
                user, pwd = "", ""
            if (secrets.compare_digest(user.encode(), settings.dashboard_user.encode())
                    and secrets.compare_digest(pwd.encode(), settings.dashboard_password.encode())):
                return await call_next(request)
        return Response("Authentication required", status_code=401,
                        headers={"WWW-Authenticate": 'Basic realm="job-hunter", charset="UTF-8"'})

    @app.middleware("http")
    async def same_origin_posts(request: Request, call_next):
        # Minimal CSRF guard for state-changing requests: Origin/Referer must match our host if present.
        if request.method in ("POST", "PUT", "PATCH", "DELETE"):
            origin = request.headers.get("origin") or request.headers.get("referer") or ""
            host = request.headers.get("host", "")
            if origin and host and f"//{host}" not in origin:
                return PlainTextResponse("Cross-origin POST rejected", status_code=403)
        return await call_next(request)

    def _filters(request: Request) -> dict:
        qp = request.query_params
        f = {
            "status": qp.get("status") or "",
            "min_score": qp.get("min_score") or "",
            "source": qp.get("source") or "",
            "since": qp.get("since") or "",
            "q": (qp.get("q") or "").strip(),
            "view": qp.get("view") if qp.get("view") in VIEWS and qp.get("view") != "today" else "",
        }
        return f

    def _query(f: dict) -> list[dict]:
        since_iso = None
        if f["since"].isdigit():
            since_iso = (datetime.now(timezone.utc) - timedelta(days=int(f["since"]))).isoformat()
        min_score = int(f["min_score"]) if f["min_score"].isdigit() else None
        jobs = db.list_jobs(status=f["status"] or None, min_score=min_score, source=f["source"] or None,
                            since=since_iso, q=f["q"] or None, limit=100000 if f.get("view") else 500)
        annotate(jobs, real_sent_ids(db), settings.send.blocklist)
        if f.get("view"):
            jobs = filter_view(jobs, f["view"])[:500]
        return jobs

    app.include_router(build_api_router(settings, db, t))

    @app.get("/healthz")
    def healthz():
        return {"ok": True, "running": pipeline.is_running()}

    @app.get("/", response_class=HTMLResponse)
    def index(request: Request):
        f = _filters(request)
        jobs = _query(f)
        gate = Gate(settings, db)
        for j in jobs:
            j["send"] = send_state(j, gate, light=True)
        qs = urlencode({k: v for k, v in f.items() if v})
        return templates.TemplateResponse(request, "index.html", {
            "jobs": jobs, "f": f, "sources": db.sources(), "counts": db.counts_by_status(),
            "runs": db.last_runs(5), "running": pipeline.is_running(), "qs": qs,
            "msg": request.query_params.get("msg"), "err": request.query_params.get("err"),
            "llm_label": settings.llm.provider, "active_view": f["view"],
        })

    @app.get("/today", response_class=HTMLResponse)
    def today(request: Request):
        jobs = annotate(db.list_jobs(limit=100000), real_sent_ids(db), settings.send.blocklist)
        todo = filter_view(jobs, "today")
        today_iso = date.today().isoformat()
        done = [j for j in jobs if j["view"] == "applied" and (j.get("applied_date") or "") == today_iso]
        return templates.TemplateResponse(request, "today.html", {
            "jobs": todo, "done": done, "msg": request.query_params.get("msg"),
            "err": request.query_params.get("err"), "active_view": "today",
        })

    def _back(target: str, job_id: int | None = None, **params) -> RedirectResponse:
        qs = ("?" + urlencode(params)) if params else ""
        if target == "today":
            return RedirectResponse(f"{base}/today{qs}", status_code=303)
        if target == "list":
            return RedirectResponse(f"{base}/{qs}", status_code=303)
        return RedirectResponse(f"{base}/jobs/{job_id}{qs}#letter", status_code=303)

    @app.post("/jobs/{job_id}/mark-applied")
    def mark_applied(job_id: int, back: str = Form("detail")):
        job = db.get_job(job_id)
        if not job:
            raise HTTPException(404)
        actions.update_tracker(db, job, status="beworben")  # notes stay untouched; nothing is sent
        return _back(back, job_id, msg="marked_applied")

    @app.post("/jobs/{job_id}/write-letter")
    def write_letter(job_id: int, back: str = Form("detail")):
        job = db.get_job(job_id)
        if not job:
            raise HTTPException(404)
        if not settings.llm.enabled:
            return _back(back, job_id, err="Keine KI konfiguriert (llm.provider / OPENCODE_BIN)")
        if not letters.start(settings, db, [job]):
            return _back(back, job_id, msg="letters_busy")
        return _back(back, job_id, msg="letter_started")

    @app.post("/letters/write-all")
    def write_all(view: str = Form(""), back: str = Form("list")):
        if not settings.llm.enabled:
            return _back(back, err="Keine KI konfiguriert (llm.provider / OPENCODE_BIN)")
        jobs = letters.candidates(settings, db, view=view if view in VIEWS else None)
        if not jobs:
            return _back(back, msg="letters_none")
        if not letters.start(settings, db, jobs):
            return _back(back, msg="letters_busy")
        return _back(back, msg="letters_started")

    @app.get("/jobs/{job_id}", response_class=HTMLResponse)
    def detail(request: Request, job_id: int):
        job = db.get_job(job_id)
        if not job:
            raise HTTPException(404)
        annotate([job], real_sent_ids(db), settings.send.blocklist)
        from .api import email_preview
        return templates.TemplateResponse(request, "detail.html", {
            "job": job, "msg": request.query_params.get("msg"), "mail": email_preview(settings, db, job),
            "err_mail": request.query_params.get("err_mail"),
            "err": request.query_params.get("err"), "llm_enabled": settings.llm.enabled,
            "llm_label": f"{settings.llm.provider}:{settings.llm.model}" if settings.llm.enabled else None,
        })

    @app.post("/jobs/{job_id}/status")
    def update_status(job_id: int, status: str = Form(...), notes: str = Form(""),
                      applied_date: str = Form("")):
        job = db.get_job(job_id)
        if not job or status not in STATUSES:
            raise HTTPException(400)
        try:
            actions.update_tracker(db, job, status=status, notes=notes, applied_date=applied_date)
        except ValueError as exc:
            raise HTTPException(400, str(exc))
        return RedirectResponse(f"{base}/jobs/{job_id}?msg=saved", status_code=303)

    @app.post("/jobs/{job_id}/letter")
    def save_letter(job_id: int, letter: str = Form("")):
        if not db.get_job(job_id):
            raise HTTPException(404)
        actions.save_letter(db, job_id, letter)
        return RedirectResponse(f"{base}/jobs/{job_id}?msg=saved#letter", status_code=303)

    @app.post("/jobs/{job_id}/regenerate")
    def regenerate(job_id: int):
        job = db.get_job(job_id)
        if not job:
            raise HTTPException(404)
        try:
            actions.regenerate_letter(settings, db, job)
        except LLMError as exc:
            return RedirectResponse(f"{base}/jobs/{job_id}?" + urlencode({"err": str(exc)}) + "#letter",
                                    status_code=303)
        return RedirectResponse(f"{base}/jobs/{job_id}?msg=regenerated#letter", status_code=303)

    @app.post("/jobs/{job_id}/apply-email")
    def set_apply_email(job_id: int, apply_email: str = Form("")):
        if not db.get_job(job_id):
            raise HTTPException(404)
        try:
            actions.set_apply_email(db, job_id, apply_email)
        except ValueError:
            return RedirectResponse(f"{base}/jobs/{job_id}?" + urlencode({"err_mail": "invalid_email"}) + "#mail",
                                    status_code=303)
        return RedirectResponse(f"{base}/jobs/{job_id}?msg=saved#mail", status_code=303)

    @app.post("/jobs/{job_id}/approve")
    def approve(job_id: int):
        job = db.get_job(job_id)
        if not job:
            raise HTTPException(404)
        try:
            actions.approve(settings, db, job)
        except actions.SendBlocked as exc:
            return RedirectResponse(f"{base}/jobs/{job_id}?" + urlencode({"err_mail": str(exc)}) + "#mail",
                                    status_code=303)
        return RedirectResponse(f"{base}/jobs/{job_id}?msg=approved#mail", status_code=303)

    @app.post("/jobs/{job_id}/unapprove")
    def unapprove(job_id: int):
        if not db.get_job(job_id):
            raise HTTPException(404)
        actions.unapprove(db, job_id)
        return RedirectResponse(f"{base}/jobs/{job_id}?msg=unapproved#mail", status_code=303)

    @app.get("/outbox", response_class=HTMLResponse)
    def outbox_page(request: Request):
        gate = Gate(settings, db)
        return templates.TemplateResponse(request, "outbox.html", {
            "log": outbox_rows(gate, db), "cfg": settings.send, "active_view": "outbox",
        })

    @app.post("/run")
    def run_now():
        actions.start_run(settings)
        return RedirectResponse(f"{base}/?msg=run_started", status_code=303)

    @app.get("/export.csv")
    def export_csv(request: Request):
        data = to_csv(_query(_filters(request)))
        return Response(data, media_type="text/csv; charset=utf-8",
                        headers={"Content-Disposition": f'attachment; filename="bewerbungen-{date.today()}.csv"'})

    @app.get("/export.xlsx")
    def export_xlsx(request: Request):
        data = to_xlsx(_query(_filters(request)))
        return Response(data, media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        headers={"Content-Disposition": f'attachment; filename="bewerbungen-{date.today()}.xlsx"'})

    return app
