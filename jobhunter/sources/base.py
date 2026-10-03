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
