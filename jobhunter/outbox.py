"""E-mail applications: rendering and the gating rules (single source of truth).

The server never sends anything itself. It decides which jobs may be sent *now*, renders the
e-mail, and records what a client (the macOS app, via Apple Mail) reports as sent.

Rules (all modes unless noted):
* kill_switch / mode=off      -> nothing is eligible
* dedup                       -> never a second real send for the same job
* status                      -> only jobs still at "neu"/"interessant"
* apply e-mail                -> needs a detected or manually entered address
* blocklist                   -> company (or recipient domain) matches an entry: never
* letter                      -> required (require_letter); "[...]" placeholders: never
* company cooldown            -> no real send / "beworben" at the same normalized company
                                 within company_cooldown_days
* daily cap                   -> at most daily_cap real sends per day (Europe/Berlin)
* auto only (not approved)    -> mode=auto, score >= auto_min_score, letter is not the
                                 fixed template ("vorlage")
Test sends (dry_run) are logged but never count for dedup, cooldown or cap.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .config import SendConfig, Settings
from .db import Database
from .dedup import _GENDER_RE, normalize_company

ACTIVE_STATUSES = ("neu", "interessant")
APPLIED_STATUSES = ("beworben", "gespraech", "absage", "angebot")
_PLACEHOLDER_RE = re.compile(r"\[[^\]\n]{0,200}\]|\.\.\.\]|\[\.\.\.")
_SALUTATION_RE = re.compile(r"^\s*(sehr geehrte|liebe[rs]?\b|hallo\b|guten tag|dear\b)", re.IGNORECASE)
_CLOSING_RE = re.compile(r"\bgrü(ß|ss)en?\b|kind regards|best regards", re.IGNORECASE)

BLOCKER_TEXT = {
    "kill_switch": "Not-Aus aktiv (send.kill_switch)",
    "mode_off": "Versand ist ausgeschaltet (send.mode = off)",
    "already_sent": "Für diese Stelle wurde bereits eine Bewerbung gesendet",
    "status": "Status ist nicht mehr „Neu“/„Interessant“",
    "no_email": "Keine Bewerbungs-E-Mail-Adresse gefunden (nur manuell bewerben)",
    "blocklist": "Firma steht auf der Sperrliste",
    "no_letter": "Kein Anschreiben vorhanden",
    "placeholder": "Anschreiben enthält noch Platzhalter [ … ]",
    "cooldown": "Bewerbung an dieselbe Firma innerhalb der Sperrfrist",
    "daily_cap": "Tageslimit erreicht",
    "not_approved": "Nicht freigegeben (Modus „approve“)",
    "score": "Score unter der Auto-Schwelle",
    "template_letter": "Vorlagen-Anschreiben wird nie automatisch gesendet",
    "auto_off": "Automatischer Versand nur im Modus „auto“",
}


def _tz(settings: Settings) -> ZoneInfo:
    try:
        return ZoneInfo(settings.timezone)
    except Exception:
        return ZoneInfo("Europe/Berlin")


def _parse(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def clean_title(title: str) -> str:
    t = _GENDER_RE.sub(" ", title or "")
    return " ".join(t.split()).strip(" -–|,")


def is_blocked_company(company: str | None, to_addr: str | None, blocklist: list[str]) -> bool:
    comp = (company or "").lower()
    comp_norm = normalize_company(company or "")
    domain = (to_addr or "").rsplit("@", 1)[-1].lower() if to_addr else ""
    domain_flat = re.sub(r"[^a-z0-9]", "", domain.rsplit(".", 1)[0]) if domain else ""
    for entry in blocklist:
        e = entry.strip().lower()
        if not e:
            continue
        if e in comp or (normalize_company(entry) and normalize_company(entry) in comp_norm):
            return True
        flat = re.sub(r"[^a-z0-9]", "", e)
        if domain_flat and len(flat) >= 4 and flat in domain_flat:
            return True
    return False


def has_placeholder(letter: str | None) -> bool:
    return bool(letter and _PLACEHOLDER_RE.search(letter))


def render_email(job: dict, cfg: SendConfig) -> dict:
    letter = (job.get("letter") or "").strip()
    values = {"title": clean_title(job.get("title") or ""), "title_raw": job.get("title") or "",
              "company": job.get("company") or "", "sender_name": cfg.sender_name,
              "from_address": cfg.from_address}
    subject = _format(cfg.subject_template, values)
    if _SALUTATION_RE.match(letter):
        body = letter
        if not _CLOSING_RE.search(letter):
            body += f"\n\nMit freundlichen Grüßen\n{cfg.sender_name}"
    else:
        body = _format(cfg.body_template, {**values, "letter": letter})
    return {
        "to": job.get("apply_email"),
        "from": cfg.from_address,
        "sender_name": cfg.sender_name,
        "sender": f"{cfg.sender_name} <{cfg.from_address}>",
        "subject": subject,
        "body": body.strip() + "\n",
        "attachment": cfg.cv_attachment,
    }


def _format(template: str, values: dict) -> str:
    class Safe(dict):
        def __missing__(self, key):
            return "{" + key + "}"
    return template.format_map(Safe(values))


@dataclass
class Counters:
    sent_today: int
    sent_total: int
    dry_run_total: int
    dry_run_today: int
    remaining_today: int


@dataclass
class Decision:
    job_id: int
    blockers: list[str] = field(default_factory=list)       # block a send in any mode
    auto_blockers: list[str] = field(default_factory=list)  # additionally block auto (unapproved) sends
    approved: bool = False

    @property
    def can_send(self) -> bool:
        """May be sent after an explicit approval (manual button / approve)."""
        return not self.blockers

    @property
    def auto_ok(self) -> bool:
        return not self.blockers and not self.auto_blockers

    @property
    def reason(self) -> str | None:
        """Why this job is in the outbox: approved (explicit) or auto (rules)."""
        if self.blockers:
            return None
        if self.approved:
            return "approved"
        return "auto" if not self.auto_blockers else None


class Gate:
    """Evaluates the rules against the current DB state."""

    def __init__(self, settings: Settings, db: Database, now: datetime | None = None):
        self.settings = settings
        self.cfg = settings.send
        self.db = db
        self.now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
        self.tz = _tz(settings)
        self._log = db.sent_log(limit=100000)
        with db.conn() as c:
            self._applied = [dict(r) for r in c.execute(
                "SELECT id, company, applied_date FROM jobs WHERE applied_date IS NOT NULL AND status IN "
                f"({','.join('?' * len(APPLIED_STATUSES))})", APPLIED_STATUSES)]

    # -- counters --------------------------------------------------------------
    def _today(self) -> date:
        return self.now.astimezone(self.tz).date()

    def _is_today(self, ts: str | None) -> bool:
        dt = _parse(ts)
        return bool(dt and dt.astimezone(self.tz).date() == self._today())

    def counters(self) -> Counters:
        real = [r for r in self._log if not r["dry_run"]]
        test = [r for r in self._log if r["dry_run"]]
        today = sum(1 for r in real if self._is_today(r["sent_at"]))
        return Counters(
            sent_today=today, sent_total=len(real), dry_run_total=len(test),
            dry_run_today=sum(1 for r in test if self._is_today(r["sent_at"])),
            remaining_today=max(0, self.cfg.daily_cap - today),
        )

    # -- per job ---------------------------------------------------------------
    def real_sends(self, job_id: int) -> list[dict]:
        return [r for r in self._log if r["job_id"] == job_id and not r["dry_run"]]

    def _in_cooldown(self, job: dict) -> bool:
        norm = normalize_company(job.get("company") or "")
        if not norm or self.cfg.company_cooldown_days <= 0:
            return False
        since = self.now - timedelta(days=self.cfg.company_cooldown_days)
        for r in self._log:
            if r["dry_run"] or r["company_norm"] != norm:
                continue
            dt = _parse(r["sent_at"])
            if dt and dt >= since:
                return True
        # Applications made by hand (status beworben & co. with an applied date) count too.
        since_day = since.astimezone(self.tz).date()
        for r in self._applied:
            if r["id"] == job["id"] or normalize_company(r["company"] or "") != norm:
                continue
            try:
                if date.fromisoformat(r["applied_date"][:10]) >= since_day:
                    return True
            except ValueError:
                continue
        return False

    def evaluate(self, job: dict, counters: Counters | None = None) -> Decision:
        cfg = self.cfg
        d = Decision(job_id=job["id"], approved=bool(job.get("send_approved_at")))
        b = d.blockers
        if cfg.kill_switch:
            b.append("kill_switch")
        if cfg.mode == "off":
            b.append("mode_off")
        if self.real_sends(job["id"]):
            b.append("already_sent")
        if job.get("status") not in ACTIVE_STATUSES:
            b.append("status")
        if not job.get("apply_email"):
            b.append("no_email")
        if is_blocked_company(job.get("company"), job.get("apply_email"), cfg.blocklist):
            b.append("blocklist")
        letter = (job.get("letter") or "").strip()
        if not letter and cfg.require_letter:
            b.append("no_letter")
        if has_placeholder(letter):
            b.append("placeholder")
        if self._in_cooldown(job):
            b.append("cooldown")
        counters = counters or self.counters()
        if counters.remaining_today <= 0:
            b.append("daily_cap")

        a = d.auto_blockers
        if cfg.mode != "auto":
            a.append("not_approved" if cfg.mode == "approve" else "auto_off")
        if (job.get("score") or 0) < cfg.auto_min_score:
            a.append("score")
        if job.get("letter_origin") == "vorlage":
            a.append("template_letter")
        if not letter:
            a.append("no_letter")
        return d

    # -- outbox ----------------------------------------------------------------
    def outbox(self) -> list[dict]:
        """Jobs to send now, best first; never two for the same company, never above the cap."""
        counters = self.counters()
        if self.cfg.kill_switch or self.cfg.mode == "off" or counters.remaining_today <= 0:
            return []
        candidates = self.db.list_jobs(limit=5000)
        items: list[dict] = []
        companies: set[str] = set()
        # Approved first (explicit wish), then by score.
        candidates.sort(key=lambda j: (not j.get("send_approved_at"), -(j.get("score") or 0)))
        for job in candidates:
            if job.get("status") not in ACTIVE_STATUSES or not job.get("apply_email"):
                continue
            dec = self.evaluate(job, counters)
            if not dec.reason:
                continue
            norm = normalize_company(job.get("company") or "") or f"#{job['id']}"
            if norm in companies:
                continue
            companies.add(norm)
            items.append({"job_id": job["id"], "title": job["title"], "company": job.get("company"),
                          "score": job.get("score"), "reason": dec.reason,
                          "email": render_email(job, self.cfg)})
            if len(items) >= counters.remaining_today:
                break
        return items


def send_state(job: dict, gate: Gate, decision: Decision | None = None, light: bool = False) -> dict:
    """Per-job badge data.

    state: sent (real send logged) | manual (no address) | ready (in the outbox now) |
    sendable (may be sent after approval) | blocked | test (only test sends, not sendable now) |
    email (list view: address known, rules not evaluated).
    """
    log = [r for r in gate._log if r["job_id"] == job["id"]]
    real = [r for r in log if not r["dry_run"]]
    if real:
        last = real[0]
        return {"state": "sent", "sent_at": last["sent_at"], "to": last["to_addr"], "sent_id": last["id"]}
    if not job.get("apply_email"):
        return {"state": "manual"}
    test = [r for r in log if r["dry_run"]]
    if light:
        state = {"state": "test" if test else "email", "approved": bool(job.get("send_approved_at"))}
        if test:
            state["test_at"] = test[0]["sent_at"]
        state["to"] = job.get("apply_email")
        return state
    decision = decision or gate.evaluate(job)
    state = {"state": "blocked"}
    if decision.reason:
        state = {"state": "ready"}
    elif decision.can_send:
        state = {"state": "sendable"}  # may be sent after approval / with the manual button
    if test:
        state["test_at"] = test[0]["sent_at"]
        if state["state"] != "ready":
            state["state"] = "test"
    state["to"] = job.get("apply_email")
    state["approved"] = decision.approved
    return state


def status_summary(settings: Settings, gate: Gate, clients: list[dict] | None = None) -> dict:
    """What the banner shows: is anything going out for real right now?"""
    cfg = settings.send
    c = gate.counters()
    app = next((x for x in (clients or []) if x.get("client") == "macos"), None)
    if cfg.kill_switch:
        kind, headline = "kill", "NOT-AUS – Versand gestoppt (send.kill_switch)"
    elif cfg.mode == "off":
        kind, headline = "off", "Versand aus"
    elif cfg.dry_run:
        kind, headline = "test", "TESTMODUS – es werden keine E-Mails versendet"
    elif cfg.mode == "auto":
        auto_on = bool(app and app.get("auto_send_enabled"))
        kind = "auto" if auto_on else "approve"
        headline = (f"AUTOMATISCHER VERSAND AKTIV – {c.sent_today} von {cfg.daily_cap} heute" if auto_on else
                    f"Echter Versand nur nach Freigabe (in der Mac-App ist „Automatisch senden“ aus) – "
                    f"{c.sent_today} von {cfg.daily_cap} heute")
    else:
        kind, headline = "approve", f"ECHTER VERSAND nach Freigabe – {c.sent_today} von {cfg.daily_cap} heute"
    return {
        "kind": kind, "headline": headline, "mode": cfg.mode, "dry_run": cfg.dry_run,
        "kill_switch": cfg.kill_switch, "daily_cap": cfg.daily_cap,
        "sent_today": c.sent_today, "sent_total": c.sent_total, "dry_run_total": c.dry_run_total,
        "remaining_today": c.remaining_today,
        "app_auto_send": None if app is None else bool(app.get("auto_send_enabled")),
        "app_seen_at": app.get("updated_at") if app else None,
    }
