"""Adzuna Jobs API (country de). Needs ADZUNA_APP_ID / ADZUNA_APP_KEY.

Call budget (one search page = one API call): the free account ("Pending activation") allows only
25 test calls in total; more needs the paid plan. So this source never spends more than
`max_calls_per_run` (default 2) per run, only in the first run of the day (`once_per_day`, default on –
"Jetzt suchen" does not use extra calls) and `max_calls_total` (default 25, 0 = no limit) overall.
The counter lives in the settings table (`adzuna_calls`, needs attach_db); each run continues with
the next search terms, so over the days all terms get a turn. On 401/403/429 it stops for good
(`adzuna_blocked`) until the counter is reset (e.g. after upgrading the plan).
"""
from __future__ import annotations

import os
from datetime import datetime
from zoneinfo import ZoneInfo
from typing import Any

from ..config import SearchProfile
from ..models import JobPosting, html_to_text
from .base import Source, SourceError, http_get

COUNTER_KEY = "adzuna_calls"


def _today() -> str:
    return datetime.now(ZoneInfo("Europe/Berlin")).date().isoformat()


BLOCKED_KEY = "adzuna_blocked"

BASE = "https://api.adzuna.com/v1/api/jobs/{country}/search/{page}"
REMOTE_WORDS = ("remote", "homeoffice", "home office", "home-office", "mobiles arbeiten", "fernarbeit")


def parse_result(item: dict[str, Any]) -> JobPosting | None:
    title = html_to_text(item.get("title") or "")
    if not title:
        return None
    desc = html_to_text(item.get("description") or "")
    loc = (item.get("location") or {}).get("display_name") or ""
    smin, smax = item.get("salary_min"), item.get("salary_max")
    text = f"{title} {desc} {loc}".lower()
    return JobPosting(
        source="adzuna",
        source_id=str(item.get("id") or item.get("adref") or title),
        title=title,
        company=html_to_text((item.get("company") or {}).get("display_name") or ""),
        location=loc,
        url=item.get("redirect_url") or "",
        description=desc,
        remote=any(w in text for w in REMOTE_WORDS),
        salary_min=float(smin) if smin else None,
        salary_max=float(smax) if smax else None,
        salary_predicted=str(item.get("salary_is_predicted", "0")) == "1",
        published=(item.get("created") or "")[:10],
    )


def parse_response(data: dict[str, Any]) -> list[JobPosting]:
    return [p for p in (parse_result(r) for r in data.get("results") or []) if p]


class AdzunaSource(Source):
    name = "adzuna"

    def __init__(self, options=None, client=None):
        super().__init__(options, client)
        self.app_id = self.options.get("app_id") or os.environ.get("ADZUNA_APP_ID", "")
        self.app_key = self.options.get("app_key") or os.environ.get("ADZUNA_APP_KEY", "")

        self.db = None

    def attach_db(self, db) -> None:
        """Persistent call counter (settings table). Without a db the per-run limit still applies."""
        self.db = db

    @property
    def per_run(self) -> int:
        return max(0, int(self.options.get("max_calls_per_run", 2)))

    @property
    def total(self) -> int:
        return max(0, int(self.options.get("max_calls_total", 25)))

    def _counter(self) -> dict:
        return (self.db.get_setting(COUNTER_KEY, {}) or {}) if self.db else {}

    def calls_used(self) -> int:
        return int(self._counter().get("used", 0))

    def _count(self, used: int) -> None:
        if self.db:
            self.db.set_setting(COUNTER_KEY, {"used": used, "day": _today()})

    def is_configured(self):
        if not (self.app_id and self.app_key):
            return False, "ADZUNA_APP_ID/ADZUNA_APP_KEY fehlen"
        if self.db and self.db.get_setting(BLOCKED_KEY):
            return False, f"gesperrt: {self.db.get_setting(BLOCKED_KEY)} (Zähler zurücksetzen nach Tarifwechsel)"
        if self.total and self.calls_used() >= self.total:
            return False, f"Kontingent aufgebraucht ({self.calls_used()}/{self.total} Aufrufe)"
        if not self.per_run:
            return False, "max_calls_per_run = 0"
        if self.options.get("once_per_day", True) and self._counter().get("day") == _today():
            return False, f"heute schon abgefragt ({self.calls_used()}/{self.total or '∞'} Aufrufe verbraucht)"
        return True, ""

    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        country = self.options.get("country", "de")
        per_page = int(self.options.get("results_per_page", 50))
        max_pages = int(self.options.get("max_pages", 1))
        searches = [{"what": q, "where": profile.location, "distance": profile.radius_km}
                    for q in profile.queries]
        if profile.remote_ok and self.options.get("remote_search", False):  # off: saves calls
            searches += [{"what": f"{q} remote"} for q in profile.queries]
        used = self.calls_used()
        budget = self.per_run
        if self.total:
            budget = min(budget, self.total - used)
        out: list[JobPosting] = []
        if budget <= 0 or not searches:
            return out
        start = used % len(searches)  # rotate: every run continues with the next terms
        order = searches[start:] + searches[:start]
        calls = 0
        for s in order:
            for page in range(1, max_pages + 1):
                if calls >= budget:
                    return out
                params = {"app_id": self.app_id, "app_key": self.app_key, "results_per_page": per_page,
                          "max_days_old": profile.days_back, "content-type": "application/json", **s}
                resp = http_get(self.client, BASE.format(country=country, page=page), params=params)
                calls += 1
                used += 1
                self._count(used)
                if resp.status_code in (401, 403, 429):
                    if self.db:
                        self.db.set_setting(BLOCKED_KEY, f"HTTP {resp.status_code}")
                    raise SourceError(f"Adzuna HTTP {resp.status_code} – Kontingent/Zugang erschöpft, "
                                      f"Quelle pausiert: {resp.text[:120]}")
                if resp.status_code != 200:
                    raise SourceError(f"Adzuna HTTP {resp.status_code}: {resp.text[:200]}")
                batch = parse_response(resp.json())
                out.extend(batch)
                if len(batch) < per_page:
                    break
        return out
