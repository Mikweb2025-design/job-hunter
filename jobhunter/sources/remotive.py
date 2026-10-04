"""Remotive remote-jobs API (free, public): https://remotive.com/api/remote-jobs

Remote jobs only. Their terms: link back to the Remotive URL and name Remotive as the source
(we keep the Remotive link as the job URL and the source label "Remotive"), and request at most
a few times a day → one request per run (optionally narrowed by `category`, e.g.
"customer-support"). Kept: jobs open to candidates in Germany/Europe whose title fits the profile.
"""
from __future__ import annotations

from typing import Any

from ..config import SearchProfile
from ..models import JobPosting, html_to_text
from .base import Source, SourceError, http_get, profile_phrases, remote_geo_ok, title_matches

URL = "https://remotive.com/api/remote-jobs"


def parse_item(item: dict[str, Any]) -> JobPosting | None:
    title = (item.get("title") or "").strip()
    if not title:
        return None
    geo = item.get("candidate_required_location") or ""
    return JobPosting(
        source="remotive", source_id=str(item.get("id") or item.get("url")), title=title,
        company=(item.get("company_name") or "").strip(), location=f"Remote ({geo})" if geo else "Remote",
        url=item.get("url") or "", description=html_to_text(item.get("description") or ""), remote=True,
        published=(item.get("publication_date") or "")[:10], extra={"geo": geo},
    )


def parse_response(data: dict[str, Any]) -> list[JobPosting]:
    return [p for p in (parse_item(i) for i in data.get("jobs") or []) if p]


class RemotiveSource(Source):
    name = "remotive"

    def fetch_all(self) -> list[JobPosting]:
        params: dict[str, Any] = {}
        if self.options.get("category"):
            params["category"] = self.options["category"]
        resp = http_get(self.client, URL, params=params or None, retries=2)
        if resp.status_code != 200:
            raise SourceError(f"Remotive HTTP {resp.status_code}")
        return parse_response(resp.json())

    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        if not profile.remote_ok:
            return []
        phrases = profile_phrases(profile)
        return [p for p in self.fetch_all()
                if remote_geo_ok(p.extra.get("geo", "")) and title_matches(p.title, phrases)]
