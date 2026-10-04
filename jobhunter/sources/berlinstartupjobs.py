"""Berlin Startup Jobs – public RSS feeds (WordPress), e.g. https://berlinstartupjobs.com/engineering/feed/

Entry titles look like "Title // Company". Feeds per category (`feeds`, default engineering +
the main feed); filtered locally by title. All jobs are in Berlin.
"""
from __future__ import annotations

from ..config import SearchProfile
from ..models import JobPosting
from .base import Source, SourceError, http_get, profile_phrases, title_matches
from .rss import parse_feed

DEFAULT_FEEDS = ["https://berlinstartupjobs.com/engineering/feed/", "https://berlinstartupjobs.com/feed/"]


def parse(content: bytes | str) -> list[JobPosting]:
    out = parse_feed(content, {"name": "berlinstartupjobs", "title_separator": " // ", "location": "Berlin"})
    for p in out:
        p.source = "berlinstartupjobs"
    return out


class BerlinStartupJobsSource(Source):
    name = "berlinstartupjobs"

    def fetch_all(self) -> list[JobPosting]:
        out: list[JobPosting] = []
        errors = []
        for url in self.options.get("feeds") or DEFAULT_FEEDS:
            resp = http_get(self.client, url, headers={"Accept": "application/rss+xml, */*"}, retries=2)
            if resp.status_code != 200:
                errors.append(f"{url}: HTTP {resp.status_code}")
                continue
            out.extend(parse(resp.content))
        if errors and not out:
            raise SourceError("; ".join(errors))
        return out

    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        phrases = profile_phrases(profile)
        return [p for p in self.fetch_all() if title_matches(p.title, phrases)]
