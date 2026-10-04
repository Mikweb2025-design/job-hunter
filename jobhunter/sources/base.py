"""Pluggable job-source interface and a small HTTP helper with retries."""
from __future__ import annotations

import logging
import time
from abc import ABC, abstractmethod
from typing import Any

import httpx

from ..config import SearchProfile
from ..models import JobPosting

log = logging.getLogger(__name__)

USER_AGENT = "job-hunter/0.1 (+self-hosted personal job search; contact via repo owner)"
RETRY_STATUS = {429, 500, 502, 503, 504}


class SourceError(RuntimeError):
    pass


def http_get(client: httpx.Client, url: str, *, params: dict | None = None,
             headers: dict | None = None, retries: int = 3, backoff: float = 1.5) -> httpx.Response:
    """GET with retry on network errors / 429 / 5xx. Raises SourceError on final failure."""
    last: Exception | None = None
    for attempt in range(retries):
        try:
            resp = client.get(url, params=params, headers=headers)
            if resp.status_code in RETRY_STATUS and attempt < retries - 1:
                wait = backoff ** attempt
                ra = resp.headers.get("retry-after")
                if ra and ra.isdigit():
                    wait = min(float(ra), 30.0)
                log.warning("GET %s -> %s, retry in %.1fs", url, resp.status_code, wait)
                time.sleep(wait)
                continue
            return resp
        except httpx.HTTPError as exc:  # connect/read timeouts etc.
            last = exc
            if attempt < retries - 1:
                time.sleep(backoff ** attempt)
    raise SourceError(f"GET {url} failed: {last}")


class Source(ABC):
    """A job source. Implementations must not log in anywhere or submit anything."""

    name: str = "base"

    def __init__(self, options: dict[str, Any] | None = None, client: httpx.Client | None = None):
        self.options = options or {}
        self.client = client or httpx.Client(
            timeout=httpx.Timeout(30.0, connect=10.0),
            headers={"User-Agent": USER_AGENT, "Accept": "application/json, */*"},
            follow_redirects=True,
        )

    def is_configured(self) -> tuple[bool, str]:
        """Return (ok, reason). Sources missing credentials are skipped, not errors."""
        return True, ""

    @abstractmethod
    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        ...

    def enrich(self, job: JobPosting) -> JobPosting:
        """Optionally fetch full details for a *new* posting. Default: nothing."""
        return job


# ---- local filtering for sources without a usable server-side search -----------------------
# (Arbeitnow, Remotive, Jobicy, company ATS feeds deliver many unrelated postings; we keep only
# those whose title fits a search query / target title and whose place fits the profile.)
_STOP = {"m", "w", "d", "f", "x", "in", "und", "and", "the", "der", "die", "das", "for", "of", "mit", "with"}


def _tokens(text: str) -> list[str]:
    from ..dedup import normalize_title
    return [t for t in normalize_title(text).replace("-", " ").split() if t not in _STOP]


def title_matches(title: str, phrases: list[str]) -> str | None:
    """The first phrase whose words all appear in the title (word prefix match, so "Support"
    also matches "Supporter"/"Support-Engineer"), else None."""
    words = _tokens(title)
    if not words:
        return None
    for phrase in phrases:
        want = _tokens(phrase)
        # prefix match allows plural/inflection ("Engineers", "Supporter"), not other words
        # ("Engineering" ≠ "Engineer")
        if want and all(any(w.startswith(t) and len(w) - len(t) <= 2 for w in words) for t in want):
            return phrase
    return None


def profile_phrases(profile: SearchProfile) -> list[str]:
    return list(dict.fromkeys([*profile.queries, *profile.target_titles]))


REMOTE_GEO_OK = ("worldwide", "anywhere", "europe", "emea", "germany", "deutschland", "dach", "eu ",
                 "european union", "cet", "remote")


def remote_geo_ok(geo: str) -> bool:
    """Remote job open to someone living in Germany? Empty = unknown = yes."""
    g = f" {(geo or '').lower()} "
    if not g.strip():
        return True
    return any(k in g for k in REMOTE_GEO_OK) or " eu," in g or g.strip() == "eu"


def place_ok(location: str, remote: bool, profile: SearchProfile) -> bool:
    loc = (location or "").lower()
    places = [p.lower() for p in (profile.location, *profile.extra_locations) if p]
    if any(p in loc for p in places):
        return True
    return bool(remote and profile.remote_ok)


def keep(job: JobPosting, profile: SearchProfile, phrases: list[str] | None = None) -> bool:
    return bool(title_matches(job.title, phrases or profile_phrases(profile))) and place_ok(
        job.location, job.remote, profile)
