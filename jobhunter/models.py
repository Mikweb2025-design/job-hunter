"""Plain data objects shared between sources, scoring and storage."""
from __future__ import annotations

import html
import re
from dataclasses import dataclass, field
from typing import Any

STATUSES = ["neu", "interessant", "beworben", "gespraech", "absage", "angebot", "zu_weit"]


@dataclass
class JobPosting:
    source: str
    source_id: str
    title: str
    company: str = ""
    location: str = ""
    url: str = ""
    description: str = ""
    remote: bool = False
    salary_min: float | None = None
    salary_max: float | None = None
    salary_predicted: bool = False
    published: str = ""  # ISO date
    extra: dict[str, Any] = field(default_factory=dict)


_TAG_RE = re.compile(r"<[^>]+>")


def html_to_text(value: str | None) -> str:
    """Strip HTML tags from feed/API content; we never render foreign HTML."""
    if not value:
        return ""
    text = re.sub(r"(?i)<br\s*/?>|</p>|</li>|</h\d>", "\n", value)
    text = re.sub(r"(?i)<li[^>]*>", "- ", text)
    text = _TAG_RE.sub("", text)
    text = html.unescape(text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n\s*\n+", "\n\n", text)
    return text.strip()
