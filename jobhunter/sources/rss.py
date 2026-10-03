"""Generic RSS/Atom feed source (user-configured feed URLs).

config.yaml:
  sources:
    rss:
      enabled: true
      feeds:
        - url: https://example.org/jobs.rss
          name: example            # optional, shown as source "rss:example"
          title_separator: " - "   # optional: "Title - Company" in entry titles
          location: Berlin         # optional default location for this feed
          remote: false            # optional: mark all entries as remote
"""
from __future__ import annotations

import hashlib
import time
from typing import Any

import feedparser

from ..config import SearchProfile
from ..models import JobPosting, html_to_text
from .base import Source, SourceError, http_get


def parse_feed(content: bytes | str, feed_cfg: dict[str, Any] | None = None) -> list[JobPosting]:
    cfg = feed_cfg or {}
    parsed = feedparser.parse(content)
    name = cfg.get("name") or (parsed.feed.get("title") if parsed.get("feed") else None) or "feed"
    sep = cfg.get("title_separator")
    out: list[JobPosting] = []
    for e in parsed.entries:
        title = html_to_text(e.get("title", ""))
        if not title:
            continue
        company = html_to_text(e.get("author", "") or "")
        if sep and sep in title:
            title, _, company_part = title.rpartition(sep)
            company = company or company_part.strip()
            title = title.strip()
        desc = ""
        if e.get("content"):
            desc = html_to_text(e["content"][0].get("value", ""))
        desc = desc or html_to_text(e.get("summary", ""))
        published = ""
        ts = e.get("published_parsed") or e.get("updated_parsed")
        if ts:
            published = time.strftime("%Y-%m-%d", ts)
        link = e.get("link", "")
        sid = e.get("id") or link or hashlib.sha1(title.encode()).hexdigest()
        low = f"{title} {desc}".lower()
        out.append(JobPosting(
            source=f"rss:{name}",
            source_id=str(sid),
            title=title,
            company=company,
            location=cfg.get("location", ""),
            url=link,
            description=desc,
            remote=bool(cfg.get("remote")) or "remote" in low or "homeoffice" in low,
            published=published,
        ))
    return out


class RSSSource(Source):
    name = "rss"

    def is_configured(self):
        if not self.options.get("feeds"):
            return False, "keine Feeds konfiguriert"
        return True, ""

    def fetch(self, profile: SearchProfile) -> list[JobPosting]:
        out: list[JobPosting] = []
        errors: list[str] = []
        for feed in self.options.get("feeds", []):
            if isinstance(feed, str):
                feed = {"url": feed}
            try:
                resp = http_get(self.client, feed["url"],
                                headers={"Accept": "application/rss+xml, application/atom+xml, */*"})
                if resp.status_code != 200:
                    raise SourceError(f"HTTP {resp.status_code}")
                out.extend(parse_feed(resp.content, feed))
            except Exception as exc:  # one broken feed must not kill the others
                errors.append(f"{feed.get('url')}: {exc}")
        if errors and not out:
            raise SourceError("; ".join(errors))
        return out
