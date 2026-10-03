"""Adzuna Jobs API (country de). Needs free ADZUNA_APP_ID / ADZUNA_APP_KEY."""
from __future__ import annotations

import os
from typing import Any

from ..config import SearchProfile
from ..models import JobPosting, html_to_text
from .base import Source, SourceError, http_get

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

    def is_configured(self):
        if not (self.app_id and self.app_key):
            return False, "ADZUNA_APP_ID/ADZUNA_APP_KEY fehlen"
        return True, ""

    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        country = self.options.get("country", "de")
        per_page = int(self.options.get("results_per_page", 50))
        max_pages = int(self.options.get("max_pages", 2))
        searches = [{"what": q, "where": profile.location, "distance": profile.radius_km}
                    for q in profile.queries]
        if profile.remote_ok and self.options.get("remote_search", True):
            searches += [{"what": f"{q} remote"} for q in profile.queries]
        out: list[JobPosting] = []
        for s in searches:
            for page in range(1, max_pages + 1):
                params = {"app_id": self.app_id, "app_key": self.app_key, "results_per_page": per_page,
                          "max_days_old": profile.days_back, "content-type": "application/json", **s}
                resp = http_get(self.client, BASE.format(country=country, page=page), params=params)
                if resp.status_code != 200:
                    raise SourceError(f"Adzuna HTTP {resp.status_code}: {resp.text[:200]}")
                batch = parse_response(resp.json())
                out.extend(batch)
                if len(batch) < per_page:
                    break
        return out
