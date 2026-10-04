"""Arbeitnow job board API (free, public, no key): https://www.arbeitnow.com/api/job-board-api

Jobs in Germany/Europe (many Berlin tech companies), newest first, one large page per request.
No server-side search → filtered locally by title (queries/target titles) and place
(Berlin/extra locations or remote). Terms: free public API, "please do not abuse" → at most
`max_pages` (default 1) requests per run.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from ..config import SearchProfile
from ..models import JobPosting, html_to_text
from .base import Source, SourceError, http_get, keep

URL = "https://www.arbeitnow.com/api/job-board-api"


def parse_item(item: dict[str, Any]) -> JobPosting | None:
    title = (item.get("title") or "").strip()
    if not title:
        return None
    published = ""
    ts = item.get("created_at")
    if isinstance(ts, (int, float)) or (isinstance(ts, str) and ts.isdigit()):
        published = datetime.fromtimestamp(int(ts), tz=timezone.utc).date().isoformat()
    location = (item.get("location") or "").strip()
    remote = bool(item.get("remote")) or location.lower() in ("remote", "homeoffice")
    return JobPosting(
        source="arbeitnow", source_id=str(item.get("slug") or item.get("url") or title), title=title,
        company=(item.get("company_name") or "").strip(), location=location, url=item.get("url") or "",
        description=html_to_text(item.get("description") or ""), remote=remote, published=published,
    )


def parse_response(data: dict[str, Any]) -> list[JobPosting]:
    return [p for p in (parse_item(i) for i in data.get("data") or []) if p]


class ArbeitnowSource(Source):
    name = "arbeitnow"

    def fetch_all(self) -> list[JobPosting]:
        out: list[JobPosting] = []
        for page in range(1, max(1, int(self.options.get("max_pages", 1))) + 1):
            resp = http_get(self.client, URL, params={"page": page}, retries=2)
            if resp.status_code != 200:
                raise SourceError(f"Arbeitnow HTTP {resp.status_code}")
            data = resp.json()
            out.extend(parse_response(data))
            if not (data.get("links") or {}).get("next"):
                break
        return out

    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        return [p for p in self.fetch_all() if keep(p, profile)]
