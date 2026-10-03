"""Workflow views shared by the dashboard and the API (same rules as the macOS app's ApplyCategory).

* auto     – "✉ Automatisch per E-Mail": status neu/interessant, application address known and the
             company is not on the send blocklist. (Whether it goes out *now* is decided by the
             outbox rules in jobhunter.outbox – this view does not change them.)
* manual   – "🖐 Manuell bewerben": status neu/interessant, no address (or blocked company):
             apply by hand through the posting / portal.
* applied  – "✅ Beworben": status beworben/gespraech/angebot, or a real send was logged.
* later    – "⏸ Später/Abgelehnt": status absage.
* today    – "Heute zu tun": the top 10 manual jobs by score (then newest).
"""
from __future__ import annotations

from .db import Database
from .outbox import BLOCKER_TEXT, Gate, is_blocked_company, render_email

VIEWS = ("today", "auto", "manual", "applied", "later")
CATEGORIES = ("auto", "manual", "applied", "later")
VIEW_LABELS = {
    "today": "Heute zu tun",
    "auto": "✉ Automatisch per E-Mail",
    "manual": "🖐 Manuell bewerben",
    "applied": "✅ Beworben",
    "later": "⏸ Später/Abgelehnt",
}
TODAY_LIMIT = 10
APPLIED = ("beworben", "gespraech", "angebot")


def real_sent_ids(db: Database) -> set[int]:
    with db.conn() as c:
        return {r[0] for r in c.execute("SELECT DISTINCT job_id FROM sent_log WHERE dry_run=0")}


def classify(job: dict, sent_ids: set[int], blocklist: list[str]) -> str:
    if job["id"] in sent_ids or job.get("status") in APPLIED:
        return "applied"
    if job.get("status") == "absage":
        return "later"
    email = (job.get("apply_email") or "").strip()
    if email and not is_blocked_company(job.get("company"), email, blocklist):
        return "auto"
    return "manual"


def apply_label(job: dict, category: str) -> str:
    if category == "auto":
        return f"Automatisch (E-Mail an {job.get('apply_email')})"
    if category == "manual":
        return "MANUELL – über Portal bewerben"
    if category == "applied":
        return "Beworben" + (f" am {job['applied_date']}" if job.get("applied_date") else "")
    return "Später/Abgelehnt"


def annotate(jobs: list[dict], sent_ids: set[int], blocklist: list[str]) -> list[dict]:
    """Adds `view` (category) and `apply_label` to each job (in place) and returns the list."""
    for j in jobs:
        j["view"] = classify(j, sent_ids, blocklist)
        j["apply_label"] = apply_label(j, j["view"])
    return jobs


def _today_sort(jobs: list[dict]) -> list[dict]:
    return sorted(jobs, key=lambda j: (j.get("score") or 0, j.get("fetched_at") or ""), reverse=True)


def filter_view(jobs: list[dict], view: str, limit: int = TODAY_LIMIT) -> list[dict]:
    """`jobs` must be annotated. today = top `limit` manual jobs by score."""
    if view == "today":
        return _today_sort([j for j in jobs if j["view"] == "manual"])[:limit]
    return [j for j in jobs if j["view"] == view]


def view_counts(db: Database, blocklist: list[str]) -> dict[str, int]:
    jobs = annotate(db.list_jobs(limit=100000), real_sent_ids(db), blocklist)
    counts = {v: 0 for v in CATEGORIES}
    for j in jobs:
        counts[j["view"]] += 1
    counts["today"] = min(TODAY_LIMIT, counts["manual"])
    counts["total"] = len(jobs)
    return counts


# ---- Postausgang: one row per state ------------------------------------------
STATE_LABELS = {"sent": "Gesendet ✅", "test": "Test 🧪", "waiting": "Wartet ⏳", "error": "Fehler ❌"}


def outbox_rows(gate: Gate, db: Database, limit: int = 1000) -> dict:
    """Rows for the Postausgang: waiting (in the outbox now), error (approved but blocked by a
    rule), sent (real) and test (dry run) – each with date, recipient and subject."""
    rows: list[dict] = []
    waiting_ids: set[int] = set()
    for o in gate.outbox():
        waiting_ids.add(o["job_id"])
        job = db.get_job(o["job_id"]) or {}
        rows.append({"state": "waiting", "label": STATE_LABELS["waiting"], "job_id": o["job_id"],
                     "title": o["title"], "company": o.get("company"),
                     "date": job.get("send_approved_at"), "to": o["email"]["to"],
                     "subject": o["email"]["subject"],
                     "detail": "freigegeben" if o["reason"] == "approved" else "automatisch (Regeln)"})
    for job in db.list_jobs(limit=100000):
        if not job.get("send_approved_at") or job["id"] in waiting_ids:
            continue
        dec = gate.evaluate(job)
        if "already_sent" in dec.blockers:
            continue
        email = render_email(job, gate.cfg)
        state = "error" if dec.blockers else "waiting"  # not blocked: only not picked yet (cap/company)
        rows.append({"state": state, "label": STATE_LABELS[state], "job_id": job["id"],
                     "title": job["title"], "company": job.get("company"),
                     "date": job.get("send_approved_at"), "to": email["to"], "subject": email["subject"],
                     "detail": ("; ".join(BLOCKER_TEXT.get(b, b) for b in dec.blockers) if dec.blockers
                                else "freigegeben – kommt in einer späteren Runde (Tageslimit / eine Firma pro Runde)")})
    for r in db.sent_log(limit=limit):
        state = "test" if r["dry_run"] else "sent"
        rows.append({"state": state, "label": STATE_LABELS[state], "job_id": r["job_id"],
                     "title": r.get("title"), "company": r.get("company"), "date": r["sent_at"],
                     "to": r["to_addr"], "subject": r["subject"], "sent_id": r["id"],
                     "detail": "Test – nicht gesendet" if r["dry_run"] else "Echt gesendet"})
    c = gate.counters()
    summary = {"sent_today": c.sent_today, "daily_cap": gate.cfg.daily_cap, "sent_total": c.sent_total,
               "test_total": c.dry_run_total, "test_today": c.dry_run_today,
               "remaining_today": c.remaining_today,
               "waiting": sum(1 for r in rows if r["state"] == "waiting"),
               "errors": sum(1 for r in rows if r["state"] == "error")}
    return {"summary": summary, "rows": rows}
