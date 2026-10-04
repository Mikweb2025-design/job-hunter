"""Bundesagentur für Arbeit – Jobsuche API (unofficial, documented by bundesAPI/jobsuche-api).

Search:  GET /pc/v6/jobs  (fallback: /pc/v4/app/jobs, /pc/v4/jobs – older shapes)
Details: GET /pc/v4/jobdetails/{base64(refnr)}
Header:  X-API-Key: jobboerse-jobsuche (public client id, no personal credentials)
"""
from __future__ import annotations

import base64
import logging
from typing import Any

from ..config import SearchProfile
from ..models import JobPosting, html_to_text
from .base import Source, SourceError, http_get

log = logging.getLogger(__name__)

BASE = "https://rest.arbeitsagentur.de/jobboerse/jobsuche-service"
SEARCH_PATHS = ["/pc/v6/jobs", "/pc/v4/app/jobs", "/pc/v4/jobs"]
DETAIL_PATHS = ["/pc/v4/jobdetails/{code}", "/pc/v3/jobdetails/{code}"]
REMOTE_ONLY = "_remote_only"
HOURS_PER_YEAR = 1720  # conservative full-time estimate for hourly wages


def _b64(refnr: str) -> str:
    return base64.b64encode(refnr.encode("utf-8")).decode("ascii")


def parse_salary(item: dict[str, Any]) -> tuple[float | None, float | None]:
    kind = (item.get("verguetungsangabe") or "").upper()
    lo = item.get("gehaltsspanneVon")
    hi = item.get("gehaltsspanneBis")
    fixed = item.get("festgehalt")
    if lo is None and hi is None and fixed is not None:
        lo = hi = fixed
    if lo is None and hi is None:
        return None, None
    factor = {"JAHRESGEHALT": 1, "MONATSGEHALT": 12, "STUNDENLOHN": HOURS_PER_YEAR}.get(kind)
    if factor is None:
        return None, None
    return (float(lo) * factor if lo is not None else None,
            float(hi) * factor if hi is not None else None)


def parse_search_item(item: dict[str, Any]) -> JobPosting | None:
    refnr = item.get("referenznummer") or item.get("refnr")
    title = item.get("stellenangebotsTitel") or item.get("titel") or item.get("beruf")
    if not refnr or not title:
        return None
    company = item.get("firma") or item.get("arbeitgeber") or ""
    location = ""
    locs = item.get("stellenlokationen") or []
    if locs:
        addr = (locs[0] or {}).get("adresse") or {}
        location = " ".join(filter(None, [addr.get("plz"), addr.get("ort")]))
    elif isinstance(item.get("arbeitsort"), dict):
        ao = item["arbeitsort"]
        location = " ".join(filter(None, [ao.get("plz"), ao.get("ort")]))
    smin, smax = parse_salary(item)
    url = item.get("externeURL") or f"https://www.arbeitsagentur.de/jobsuche/jobdetail/{refnr}"
    published = (item.get("datumErsteVeroeffentlichung")
                 or item.get("aktuelleVeroeffentlichungsdatum")
                 or (item.get("veroeffentlichungszeitraum") or {}).get("von") or "")
    return JobPosting(
        source="arbeitsagentur",
        source_id=str(refnr),
        title=str(title).strip(),
        company=str(company).strip(),
        location=location,
        url=url,
        description=html_to_text(item.get("stellenangebotsBeschreibung") or ""),
        remote=bool(item.get("homeofficemoeglich")),
        salary_min=smin,
        salary_max=smax,
        published=str(published)[:10],
        extra={"ba_url": f"https://www.arbeitsagentur.de/jobsuche/jobdetail/{refnr}",
               "hauptberuf": item.get("hauptberuf") or item.get("beruf")},
    )


def parse_search_response(data: dict[str, Any]) -> list[JobPosting]:
    items = data.get("ergebnisliste") or data.get("stellenangebote") or []
    return [p for p in (parse_search_item(i) for i in items) if p]


def apply_detail(job: JobPosting, detail: dict[str, Any]) -> JobPosting:
    desc = html_to_text(detail.get("stellenangebotsBeschreibung") or detail.get("stellenbeschreibung") or "")
    if desc:
        job.description = desc
    if detail.get("externeURL") and "arbeitsagentur.de" in job.url:
        job.url = detail["externeURL"]
    smin, smax = parse_salary(detail)
    if smin or smax:
        job.salary_min, job.salary_max = smin, smax
    if detail.get("homeofficemoeglich"):
        job.remote = True
    return job


class ArbeitsagenturSource(Source):
    name = "arbeitsagentur"

    def __init__(self, options=None, client=None):
        super().__init__(options, client)
        self.headers = {"X-API-Key": self.options.get("api_key", "jobboerse-jobsuche")}
        self._search_path: str | None = None

    def _search(self, params: dict[str, Any]) -> dict[str, Any]:
        paths = [self._search_path] if self._search_path else SEARCH_PATHS
        errors = []
        for path in paths:
            resp = http_get(self.client, BASE + path, params=params, headers=self.headers)
            if resp.status_code == 200:
                self._search_path = path
                return resp.json()
            errors.append(f"{path}: HTTP {resp.status_code}")
            if resp.status_code not in (403, 404, 410):
                break
        raise SourceError("Arbeitsagentur search failed (" + "; ".join(errors) + ")")

    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        size = int(self.options.get("page_size", 50))
        max_pages = int(self.options.get("max_pages", 2))
        searches: list[dict[str, Any]] = []
        for q in profile.queries:
            searches.append({"was": q, "wo": profile.location, "umkreis": profile.radius_km})
            if profile.remote_ok and self.options.get("remote_search", True):
                # Home office, Germany-wide. The v6 API ignores/zeroes the old `arbeitszeit=ho`
                # filter (always 0 hits, checked 04.10.2026) → search nationwide and keep only
                # postings with homeofficemoeglich=true.
                searches.append({"was": q, REMOTE_ONLY: True})
        out: list[JobPosting] = []
        for base_params in searches:
            remote_only = bool(base_params.get(REMOTE_ONLY))
            base_params = {k: v for k, v in base_params.items() if k != REMOTE_ONLY}
            for page in range(1, max_pages + 1):
                params = {**base_params, "angebotsart": 1, "veroeffentlichtseit": profile.days_back,
                          "size": size, "page": page, "pav": "false"}
                data = self._search(params)
                batch = parse_search_response(data)
                out.extend(p for p in batch if p.remote or not remote_only)
                total = int(data.get("maxErgebnisse") or 0)
                if len(batch) < size or page * size >= total:
                    break
        return out

    def enrich(self, job: JobPosting) -> JobPosting:
        code = _b64(job.source_id)
        for path in DETAIL_PATHS:
            try:
                resp = http_get(self.client, BASE + path.format(code=code), headers=self.headers, retries=2)
            except SourceError as exc:
                log.info("BA detail %s failed: %s", job.source_id, exc)
                return job
            if resp.status_code == 200:
                try:
                    return apply_detail(job, resp.json())
                except ValueError:
                    return job
        return job
