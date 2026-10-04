"""Public job feeds of company applicant-tracking systems, for a user-edited list of companies.

These feeds are published by the companies for programmatic use (career pages, aggregators):
  greenhouse       https://boards-api.greenhouse.io/v1/boards/<token>/jobs?content=true
  lever            https://api.lever.co/v0/postings/<token>?mode=json
  personio         https://<token>.jobs.personio.de/xml
  smartrecruiters  https://api.smartrecruiters.com/v1/companies/<token>/postings (+ detail per match)

config / UI (`sources.ats.companies`):
  - {ats: greenhouse, token: sumup, name: SumUp}
One request per company and run; postings are filtered locally by title and place.
"""
from __future__ import annotations

import html
import logging
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from typing import Any

from ..config import SearchProfile
from ..models import JobPosting, html_to_text
from .base import Source, SourceError, http_get, keep

log = logging.getLogger(__name__)

ATS_TYPES = {
    "greenhouse": "Greenhouse",
    "lever": "Lever",
    "personio": "Personio",
    "smartrecruiters": "SmartRecruiters",
}
TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
REMOTE_WORDS = ("remote", "homeoffice", "home office", "home-office", "anywhere")


def _remote(*texts: str) -> bool:
    low = " ".join(t or "" for t in texts).lower()
    return any(w in low for w in REMOTE_WORDS)


def feed_url(ats: str, token: str) -> str:
    if not TOKEN_RE.match(token or ""):
        raise ValueError(f"ungültiger Firmen-Kürzel {token!r}")
    return {
        "greenhouse": f"https://boards-api.greenhouse.io/v1/boards/{token}/jobs?content=true",
        "lever": f"https://api.lever.co/v0/postings/{token}?mode=json",
        "personio": f"https://{token}.jobs.personio.de/xml",
        "smartrecruiters": f"https://api.smartrecruiters.com/v1/companies/{token}/postings?limit=100&country=de",
    }[ats]


# ---- parsers -----------------------------------------------------------------------------
def parse_greenhouse(data: dict[str, Any], company: str) -> list[JobPosting]:
    out = []
    for j in data.get("jobs") or []:
        loc = ((j.get("location") or {}).get("name") or "").strip()
        desc = html_to_text(html.unescape(j.get("content") or ""))
        out.append(JobPosting(
            source="greenhouse", source_id=str(j.get("id")), title=(j.get("title") or "").strip(),
            company=company, location=loc, url=j.get("absolute_url") or "", description=desc,
            remote=_remote(loc), published=(j.get("updated_at") or "")[:10]))
    return [p for p in out if p.title]


def parse_lever(data: list[dict[str, Any]], company: str) -> list[JobPosting]:
    out = []
    for j in data or []:
        cat = j.get("categories") or {}
        loc = cat.get("location") or ", ".join(cat.get("allLocations") or [])
        parts = [j.get("descriptionPlain") or html_to_text(j.get("description") or "")]
        for lst in j.get("lists") or []:
            parts.append(f"{lst.get('text', '')}\n{html_to_text(lst.get('content') or '')}")
        parts.append(j.get("additionalPlain") or "")
        created = j.get("createdAt")
        published = (datetime.fromtimestamp(int(created) / 1000, tz=timezone.utc).date().isoformat()
                     if isinstance(created, (int, float)) or str(created or "").isdigit() else "")
        out.append(JobPosting(
            source="lever", source_id=str(j.get("id")), title=(j.get("text") or "").strip(), company=company,
            location=loc, url=j.get("hostedUrl") or j.get("applyUrl") or "",
            description="\n\n".join(p.strip() for p in parts if p and p.strip()),
            remote=(j.get("workplaceType") == "remote") or _remote(loc), published=published))
    return [p for p in out if p.title]


def parse_personio(content: bytes | str, token: str, company: str) -> list[JobPosting]:
    try:
        root = ET.fromstring(content)
    except ET.ParseError as exc:
        raise SourceError(f"Personio {token}: kein gültiges XML ({exc})") from None
    out = []
    for pos in root.iter("position"):
        def t(tag: str) -> str:
            el = pos.find(tag)
            return (el.text or "").strip() if el is not None and el.text else ""
        offices = [t("office"), *[(o.text or "").strip() for o in pos.findall("additionalOffices/office")]]
        loc = ", ".join(o for o in offices if o)
        desc = "\n\n".join(
            f"{(d.findtext('name') or '').strip()}\n{html_to_text(d.findtext('value') or '')}".strip()
            for d in pos.findall("jobDescriptions/jobDescription"))
        pid = t("id")
        out.append(JobPosting(
            source="personio", source_id=f"{token}:{pid}", title=t("name"),
            company=company or t("subcompany"), location=loc,
            url=f"https://{token}.jobs.personio.de/job/{pid}", description=desc,
            remote=_remote(loc, t("schedule")), published=t("createdAt")[:10]))
    return [p for p in out if p.title]


def parse_smartrecruiters_list(data: dict[str, Any], token: str, company: str) -> list[JobPosting]:
    out = []
    for j in data.get("content") or []:
        loc = j.get("location") or {}
        place = loc.get("fullLocation") or ", ".join(x for x in (loc.get("city"), loc.get("country")) if x)
        out.append(JobPosting(
            source="smartrecruiters", source_id=str(j.get("id")), title=(j.get("name") or "").strip(),
            company=company or (j.get("company") or {}).get("name") or "", location=place,
            url=f"https://jobs.smartrecruiters.com/{token}/{j.get('id')}", description="",
            remote=bool(loc.get("remote")), published=(j.get("releasedDate") or "")[:10],
            extra={"detail": f"https://api.smartrecruiters.com/v1/companies/{token}/postings/{j.get('id')}"}))
    return [p for p in out if p.title]


def apply_smartrecruiters_detail(job: JobPosting, detail: dict[str, Any]) -> JobPosting:
    sections = (detail.get("jobAd") or {}).get("sections") or {}
    parts = []
    for key in ("companyDescription", "jobDescription", "qualifications", "additionalInformation"):
        s = sections.get(key) or {}
        if s.get("text"):
            parts.append(f"{s.get('title') or ''}\n{html_to_text(s['text'])}".strip())
    if parts:
        job.description = "\n\n".join(parts)
    if detail.get("postingUrl"):
        job.url = detail["postingUrl"]
    return job


class ATSSource(Source):
    """All configured company feeds; one broken company never stops the others."""
    name = "ats"

    def companies(self) -> list[dict[str, str]]:
        out = []
        for c in self.options.get("companies") or []:
            ats = str(c.get("ats") or "").lower()
            token = str(c.get("token") or "").strip()
            if ats in ATS_TYPES and TOKEN_RE.match(token) and c.get("enabled", True):
                out.append({"ats": ats, "token": token, "name": str(c.get("name") or token)})
        return out

    def is_configured(self):
        if not self.companies():
            return False, "keine Firmen eingetragen"
        return True, ""

    def fetch_company(self, c: dict[str, str]) -> list[JobPosting]:
        resp = http_get(self.client, feed_url(c["ats"], c["token"]), retries=2)
        label = f"{ATS_TYPES[c['ats']]} {c['token']}"
        if c["ats"] == "personio" and ".jobs.personio." not in str(getattr(resp, "url", "") or feed_url("personio", c["token"])):
            raise SourceError(f"{label}: Firma nicht gefunden (Weiterleitung)")  # unknown → personio.com
        if resp.status_code == 404:
            raise SourceError(f"{label}: Firma nicht gefunden (404)")
        if resp.status_code != 200:
            raise SourceError(f"{label}: HTTP {resp.status_code}")
        if c["ats"] == "greenhouse":
            return parse_greenhouse(resp.json(), c["name"])
        if c["ats"] == "lever":
            return parse_lever(resp.json(), c["name"])
        if c["ats"] == "personio":
            return parse_personio(resp.content, c["token"], c["name"])
        return parse_smartrecruiters_list(resp.json(), c["token"], c["name"])

    def fetch_all(self) -> tuple[list[JobPosting], list[str]]:
        out: list[JobPosting] = []
        errors: list[str] = []
        for c in self.companies():
            try:
                out.extend(self.fetch_company(c))
            except Exception as exc:
                errors.append(f"{c['name']}: {exc}")
        return out, errors

    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        jobs, errors = self.fetch_all()
        for e in errors:
            log.warning("ATS: %s", e)
        if errors and not jobs:
            raise SourceError("; ".join(errors))
        return [p for p in jobs if keep(p, profile)]

    def enrich(self, job: JobPosting) -> JobPosting:
        url = job.extra.get("detail")
        if job.source == "smartrecruiters" and url:
            resp = http_get(self.client, url, retries=2)
            if resp.status_code == 200:
                return apply_smartrecruiters_detail(job, resp.json())
        return job
