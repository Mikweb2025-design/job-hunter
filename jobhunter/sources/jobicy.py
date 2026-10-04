"""Jobicy remote-jobs API (free, public): https://jobicy.com/api/v2/remote-jobs

Remote jobs; `geo=germany` returns jobs open to Germany (incl. "Europe", "EMEA", "Anywhere").
Terms: credit Jobicy with a direct link and send applications to the original job URL → we keep
the Jobicy job URL. One request per run (count ≤ 100).
"""
from __future__ import annotations

from typing import Any

from ..config import SearchProfile
from ..models import JobPosting, html_to_text
from .base import Source, SourceError, http_get, profile_phrases, remote_geo_ok, title_matches

URL = "https://jobicy.com/api/v2/remote-jobs"


def parse_item(item: dict[str, Any]) -> JobPosting | None:
    title = html_to_text(item.get("jobTitle") or "")
    if not title:
        return None
    geo = item.get("jobGeo") or ""
    smin, smax = item.get("annualSalaryMin"), item.get("annualSalaryMax")
    eur = (item.get("salaryCurrency") or "").upper() == "EUR"
    return JobPosting(
        source="jobicy", source_id=str(item.get("id") or item.get("url")), title=title,
        company=html_to_text(item.get("companyName") or ""), location=f"Remote ({geo})" if geo else "Remote",
        url=item.get("url") or "", description=html_to_text(item.get("jobDescription") or item.get("jobExcerpt") or ""),
        remote=True, published=(item.get("pubDate") or "")[:10],
        salary_min=float(smin) if eur and smin else None, salary_max=float(smax) if eur and smax else None,
        extra={"geo": geo},
    )


def parse_response(data: dict[str, Any]) -> list[JobPosting]:
    return [p for p in (parse_item(i) for i in data.get("jobs") or []) if p]


class JobicySource(Source):
    name = "jobicy"

    def fetch_all(self) -> list[JobPosting]:
        params = {"count": min(int(self.options.get("count", 100)), 100),
                  "geo": self.options.get("geo", "germany")}
        resp = http_get(self.client, URL, params=params, retries=2)
        if resp.status_code != 200:
            raise SourceError(f"Jobicy HTTP {resp.status_code}")
        return parse_response(resp.json())

    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        if not profile.remote_ok:
            return []
        phrases = profile_phrases(profile)
        return [p for p in self.fetch_all()
                if remote_geo_ok(p.extra.get("geo", "")) and title_matches(p.title, phrases)]
