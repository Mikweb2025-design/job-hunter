"""Application tracker: Kanban columns for all statuses, KPIs/funnel, follow-ups, interviews,
status timeline. Shared by the dashboard (/tracker) and the API (GET /api/v1/tracker).

Rules (the macOS app mirrors them in JobHunterCore/Tracker.swift – keep both in sync):

* applied   – a real e-mail was sent, or status beworben/gespraech/angebot, or status absage with an
              applied date (rejected after applying). close_reason "duplikat" never counts.
* responded – applied and status gespraech/angebot, or absage that is an employer answer
              (close_reason empty, "absage_firma" or "stelle_besetzt").
* follow-up – status beworben and either follow_up_at <= today, or no follow_up_at and applied
              >= FOLLOW_UP_DAYS days ago ("Nachfassen").
* channel   – "email" (real send logged, with date) or "manual" (applied by hand / portal).

Nothing here sends anything: the follow-up text is only a draft the user opens in Mail.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from . import alerts, links
from .db import Database
from .models import STATUSES

FOLLOW_UP_DAYS = 14
APPLIED_STATUSES = ("beworben", "gespraech", "angebot")
RESPONSE_STATUSES = ("gespraech", "absage", "angebot")
EMPLOYER_ABSAGE = (None, "", "absage_firma", "stelle_besetzt")
CLOSE_REASON_LABELS = {
    "duplikat": "Duplikat",
    "kein_interesse": "Kein Interesse",
    "stelle_besetzt": "Stelle besetzt",
    "absage_firma": "Absage der Firma",
    "sonstiges": "Sonstiges",
}
STATUS_LABELS = {
    "neu": "Neu", "interessant": "Interessant", "beworben": "Beworben", "gespraech": "Gespräch",
    "absage": "Absage", "angebot": "Angebot", "zu_weit": "Zu weit",
}
# Kanban order: the pipeline from left to right, the closed ones at the end.
COLUMN_ORDER = ("neu", "interessant", "beworben", "gespraech", "angebot", "absage", "zu_weit")
HISTORY_SOURCES = {"tracker": "Tracker", "email": "E-Mail-Versand", "system": "Automatisch",
                   "backfill": "Übernommen", "bulk": "Mehrfachauswahl"}


def _day(value: str | None) -> date | None:
    if not value:
        return None
    try:
        return date.fromisoformat(value[:10])
    except ValueError:
        return None


def _dt(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        d = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def real_sends(db: Database) -> dict[int, dict]:
    """Latest real (not dry-run) send per job."""
    out: dict[int, dict] = {}
    for r in db.sent_log(limit=100000, include_dry_run=False):
        out.setdefault(r["job_id"], r)  # sent_log is newest first
    return out


def is_applied(job: dict, sent: dict[int, dict]) -> bool:
    if job.get("close_reason") == "duplikat":
        return False
    if job["id"] in sent or job.get("status") in APPLIED_STATUSES:
        return True
    return job.get("status") == "absage" and bool(job.get("applied_date"))


def has_response(job: dict, sent: dict[int, dict]) -> bool:
    if not is_applied(job, sent):
        return False
    st = job.get("status")
    if st in ("gespraech", "angebot"):
        return True
    return st == "absage" and job.get("close_reason") in EMPLOYER_ABSAGE


def applied_day(job: dict, sent: dict[int, dict]) -> date | None:
    d = _day(job.get("applied_date"))
    if d is None and job["id"] in sent:
        d = _day(sent[job["id"]]["sent_at"])
    return d


def channel(job: dict, sent: dict[int, dict]) -> dict | None:
    if job["id"] in sent:
        r = sent[job["id"]]
        return {"kind": "email", "label": f"✉ E-Mail gesendet am {_fmt_day(_day(r['sent_at']))}",
                "at": r["sent_at"], "to": r["to_addr"]}
    if is_applied(job, sent):
        d = _day(job.get("applied_date"))
        return {"kind": "manual", "label": "🖐 manuell beworben" + (f" am {_fmt_day(d)}" if d else ""),
                "at": job.get("applied_date"), "to": None}
    return None


def _fmt_day(d: date | None) -> str:
    return d.strftime("%d.%m.%Y") if d else "–"


def follow_up_due(job: dict, sent: dict[int, dict], today: date) -> bool:
    if job.get("status") != "beworben":
        return False
    fu = _day(job.get("follow_up_at"))
    if fu is not None:
        return fu <= today
    ad = applied_day(job, sent)
    return ad is not None and (today - ad).days >= FOLLOW_UP_DAYS


def follow_up_from(job: dict, sent: dict[int, dict]) -> date | None:
    """Date from which "Nachfassen" is suggested."""
    fu = _day(job.get("follow_up_at"))
    if fu is not None:
        return fu
    ad = applied_day(job, sent)
    return ad + timedelta(days=FOLLOW_UP_DAYS) if ad else None


def next_step(job: dict, sent: dict[int, dict], today: date, now: datetime | None = None) -> str:
    st = job.get("status")
    now = now or datetime.now(timezone.utc)
    if st in ("neu", "interessant"):
        view = job.get("view")
        if view == "auto":
            return "Wird per E-Mail beworben (Regeln im Postausgang)"
        if view == "far":
            return "Zu weit weg – nur bei Interesse manuell"
        return "Manuell über das Portal bewerben"
    if st == "beworben":
        if follow_up_due(job, sent, today):
            ad = applied_day(job, sent)
            days = (today - ad).days if ad else None
            return f"Nachfassen – seit {days} Tagen keine Antwort" if days is not None else "Nachfassen"
        fu = follow_up_from(job, sent)
        return f"Auf Antwort warten (Nachfassen ab {_fmt_day(fu)})" if fu else "Auf Antwort warten"
    if st == "gespraech":
        it = _local_dt(job.get("interview_at"))
        if it is None:
            return "Gesprächstermin eintragen"
        if it.date() >= today:
            return f"Gespräch am {it.strftime('%d.%m.%Y %H:%M')} vorbereiten"
        return "Rückmeldung nach dem Gespräch abwarten"
    if st == "angebot":
        return "Angebot prüfen und antworten"
    if st == "absage":
        reason = CLOSE_REASON_LABELS.get(job.get("close_reason") or "")
        return f"Abgeschlossen ({reason})" if reason else "Abgeschlossen"
    if st == "zu_weit":
        return "Kein Umzug – nicht bewerben"
    return ""


def _local_dt(value: str | None) -> datetime | None:
    """interview_at is stored as local wall time ("YYYY-MM-DDTHH:MM"); keep it naive."""
    if not value:
        return None
    try:
        d = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d.replace(tzinfo=None)


def follow_up_draft(job: dict, sent: dict[int, dict], applicant_name: str = "") -> dict:
    """German follow-up e-mail draft (opened in Mail as a compose window – never sent automatically)."""
    ad = applied_day(job, sent)
    title = job.get("title") or "die ausgeschriebene Stelle"
    when = f"am {_fmt_day(ad)} " if ad else ""
    body = (
        "Sehr geehrte Damen und Herren,\n\n"
        f"{when}habe ich mich bei Ihnen als {title} beworben. Ich interessiere mich weiterhin sehr "
        "für die Stelle und möchte mich erkundigen, ob Sie mir schon etwas zum weiteren Ablauf "
        "sagen können.\n\n"
        "Für Rückfragen stehe ich Ihnen gern zur Verfügung.\n\n"
        "Mit freundlichen Grüßen\n"
        f"{applicant_name}".rstrip()
    )
    to = sent[job["id"]]["to_addr"] if job["id"] in sent else (job.get("apply_email") or "")
    return {"to": to, "subject": f"Nachfrage zu meiner Bewerbung als {title}", "body": body}


def card(job: dict, sent: dict[int, dict], today: date) -> dict:
    ad = applied_day(job, sent)
    ch = channel(job, sent)
    notes = (job.get("notes") or "").strip()
    return {
        "id": job["id"], "title": job["title"], "company": job.get("company"), "location": job.get("location"),
        "score": job.get("score") or 0, "status": job["status"], "status_label": STATUS_LABELS.get(job["status"]),
        "source": job.get("source"), "source_label": alerts.source_label(job.get("source")),
        "view": job.get("view"), "applied_date": job.get("applied_date"),
        "days_since_applied": (today - ad).days if ad else None,
        "channel": ch, "interview_at": job.get("interview_at"), "follow_up_at": job.get("follow_up_at"),
        "follow_up_due": follow_up_due(job, sent, today), "close_reason": job.get("close_reason"),
        "close_reason_label": CLOSE_REASON_LABELS.get(job.get("close_reason") or ""),
        "notes": notes[:160], "next_step": next_step(job, sent, today),
        "status_updated_at": job.get("status_updated_at"), "url": links.apply_link(job),
    }


def _card_sort(status: str):
    if status in ("beworben", "gespraech", "angebot", "absage"):
        return lambda c: (c["applied_date"] or c["status_updated_at"] or "", c["score"])
    return lambda c: (c["score"], c["id"])


def _answer_day(job: dict, history: list[dict], applied: date) -> date | None:
    for h in history:
        if h["new_status"] in RESPONSE_STATUSES:
            d = _day(h["changed_at"])
            if d and d >= applied:
                return d
    if job.get("status") in RESPONSE_STATUSES:
        return _day(job.get("status_updated_at"))
    return None


def _week_start(d: date) -> date:
    return d - timedelta(days=d.weekday())


def build(db: Database, jobs: list[dict], applicant_name: str = "", today: date | None = None,
          per_column: int = 60, weeks: int = 12) -> dict:
    """`jobs` must be annotated (jobhunter.views.annotate) and already filtered."""
    today = today or date.today()
    sent = real_sends(db)
    hist: dict[int, list[dict]] = {}
    for h in db.status_history():
        hist.setdefault(h["job_id"], []).append(h)

    cards_by: dict[str, list[dict]] = {s: [] for s in COLUMN_ORDER}
    for j in jobs:
        cards_by.setdefault(j["status"], []).append(card(j, sent, today))
    columns = []
    for s in COLUMN_ORDER:
        cs = sorted(cards_by.get(s, []), key=_card_sort(s), reverse=True)
        columns.append({"status": s, "label": STATUS_LABELS[s], "count": len(cs),
                        "cards": cs[:per_column], "more": max(0, len(cs) - per_column)})

    applied = [j for j in jobs if is_applied(j, sent)]
    responded = [j for j in applied if has_response(j, sent)]
    week0 = _week_start(today)
    this_week = [j for j in applied if (applied_day(j, sent) or date.min) >= week0]
    days = []
    for j in responded:
        ad = applied_day(j, sent)
        ans = _answer_day(j, hist.get(j["id"], []), ad) if ad else None
        if ad and ans:
            days.append(max(0, (ans - ad).days))
    interviews_total = [j for j in applied if j["status"] in ("gespraech", "angebot") or j.get("interview_at")
                        or any(h["new_status"] == "gespraech" for h in hist.get(j["id"], []))]
    by_channel = {"email": sum(1 for j in applied if j["id"] in sent)}
    by_channel["manual"] = len(applied) - by_channel["email"]
    kpis = {
        "applied": len(applied), "this_week": len(this_week),
        "by_channel": by_channel,
        "responses": len(responded),
        "response_rate": round(100 * len(responded) / len(applied)) if applied else None,
        "interviews": len(interviews_total),
        "offers": sum(1 for j in applied if j["status"] == "angebot"),
        "rejections": sum(1 for j in responded if j["status"] == "absage"),
        "waiting": sum(1 for j in applied if j["status"] == "beworben"),
        "avg_days_to_answer": round(sum(days) / len(days), 1) if days else None,
        "follow_up_days": FOLLOW_UP_DAYS,
    }
    funnel = [
        {"key": "found", "label": "Gefunden", "value": len(jobs)},
        {"key": "interesting", "label": "In Bearbeitung",
         "value": sum(1 for j in jobs if j["status"] != "neu" and j["status"] != "zu_weit" and j.get("close_reason") != "duplikat")},
        {"key": "applied", "label": "Beworben", "value": len(applied)},
        {"key": "responses", "label": "Antwort", "value": len(responded)},
        {"key": "interviews", "label": "Gespräch", "value": len(interviews_total)},
        {"key": "offers", "label": "Angebot", "value": kpis["offers"]},
    ]

    starts = [week0 - timedelta(weeks=i) for i in range(weeks - 1, -1, -1)]
    weekly = {s: {"week": f"{s.isocalendar().year}-W{s.isocalendar().week:02d}", "start": s.isoformat(),
                  "applications": 0, "responses": 0} for s in starts}
    for j in applied:
        ad = applied_day(j, sent)
        if ad and _week_start(ad) in weekly:
            weekly[_week_start(ad)]["applications"] += 1
    for j in responded:
        ad = applied_day(j, sent)
        ans = _answer_day(j, hist.get(j["id"], []), ad) if ad else None
        if ans and _week_start(ans) in weekly:
            weekly[_week_start(ans)]["responses"] += 1

    src: dict[str, dict] = {}
    for j in applied:
        label = alerts.source_label(j.get("source"))
        e = src.setdefault(label, {"source": j.get("source"), "label": label, "applications": 0, "responses": 0})
        e["applications"] += 1
        e["responses"] += int(has_response(j, sent))
    by_source = sorted(src.values(), key=lambda e: (-e["applications"], e["label"]))

    follow_ups = []
    for j in jobs:
        if follow_up_due(j, sent, today):
            c = card(j, sent, today)
            c["draft"] = follow_up_draft(j, sent, applicant_name)
            follow_ups.append(c)
    follow_ups.sort(key=lambda c: -(c["days_since_applied"] or 0))

    upcoming = []
    for j in jobs:
        it = _local_dt(j.get("interview_at"))
        if it and it.date() >= today:
            upcoming.append(card(j, sent, today))
    upcoming.sort(key=lambda c: c["interview_at"])

    return {"columns": columns, "statuses": list(COLUMN_ORDER), "labels": STATUS_LABELS, "kpis": kpis,
            "funnel": funnel, "weekly": list(weekly.values()), "by_source": by_source,
            "follow_ups": follow_ups, "interviews": upcoming, "close_reasons": CLOSE_REASON_LABELS,
            "today": today.isoformat()}


def timeline(db: Database, job: dict) -> list[dict]:
    """Status changes + e-mail sends + found/interview events for one job, oldest first."""
    events = [{"at": job.get("fetched_at"), "kind": "found", "label": "Gefunden",
               "detail": alerts.source_label(job.get("source"))}]
    for h in db.status_history(job["id"]):
        frm = STATUS_LABELS.get(h["old_status"] or "", None)
        to = STATUS_LABELS.get(h["new_status"], h["new_status"])
        events.append({"at": h["changed_at"], "kind": "status", "from": h["old_status"], "to": h["new_status"],
                       "label": f"{frm} → {to}" if frm else f"Status: {to}",
                       "detail": HISTORY_SOURCES.get(h.get("source") or "", h.get("source") or "")})
    for r in db.sent_log(job_id=job["id"]):
        events.append({"at": r["sent_at"], "kind": "test" if r["dry_run"] else "sent",
                       "label": "Test – nicht gesendet" if r["dry_run"] else "✉ E-Mail gesendet",
                       "detail": r["to_addr"]})
    if job.get("interview_at"):
        events.append({"at": job["interview_at"], "kind": "interview", "label": "Gespräch (Termin)",
                       "detail": _local_dt(job["interview_at"]).strftime("%d.%m.%Y %H:%M")
                       if _local_dt(job["interview_at"]) else job["interview_at"]})

    def key(e):
        d = _dt(e["at"]) if e["kind"] != "interview" else (_local_dt(e["at"]) or datetime.min).replace(tzinfo=timezone.utc)
        return d or datetime.min.replace(tzinfo=timezone.utc)
    return sorted([e for e in events if e["at"]], key=key)


def relative_day(value: str | None, today: date | None = None) -> str:
    """"heute", "gestern", "vor 3 Tagen", "in 2 Tagen", "vor 2 Wochen" … (German)."""
    d = _day(value)
    if d is None:
        return ""
    today = today or date.today()
    n = (today - d).days
    if n == 0:
        return "heute"
    if n == 1:
        return "gestern"
    if n == -1:
        return "morgen"
    if n < 0:
        return f"in {-n} Tagen"
    if n < 14:
        return f"vor {n} Tagen"
    if n < 60:
        return f"vor {n // 7} Wochen"
    return f"vor {n // 30} Monaten"


__all__ = ["build", "timeline", "relative_day", "follow_up_draft", "STATUSES"]
