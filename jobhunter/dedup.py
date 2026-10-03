"""Deduplication by normalized title + company."""
from __future__ import annotations

import re
import unicodedata

from .models import JobPosting

# Gender/diversity tags common in German postings: (m/w/d), [w/m/d], (all genders), (gn) ...
_GENDER_RE = re.compile(
    r"[\(\[\{]?\s*(?:"
    r"(?<![a-z])[mwfdxi]\s*/\s*[mwfdxi](?:\s*/\s*[mwfdxi])?(?:\s*/\s*[mwfdxi])?(?![a-z])"
    r"|all\s+genders?|alle\s+geschlechter|(?<![a-z])gn\*?(?![a-z])|m\*w\*d"
    r")\s*[\)\]\}]?",
    re.IGNORECASE,
)
_LEGAL_FORMS = {
    "gmbh", "mbh", "ag", "se", "kg", "kgaa", "co", "ohg", "ug", "haftungsbeschrankt",
    "ev", "inc", "ltd", "llc", "plc", "bv", "nv", "sarl", "srl", "spa", "gbr", "deutschland",
    "germany",
}


def _fold(text: str) -> str:
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    return text.lower().replace("ß", "ss")


def normalize_title(title: str) -> str:
    t = _GENDER_RE.sub(" ", title or "")
    t = _fold(t)
    t = re.sub(r"[^a-z0-9+#]+", " ", t)
    return " ".join(t.split())


def normalize_company(company: str) -> str:
    c = _fold(company or "")
    c = re.sub(r"[^a-z0-9]+", " ", c)
    words = [w for w in c.split() if w not in _LEGAL_FORMS]
    return " ".join(words)


def dedup_key(title: str, company: str) -> str:
    return f"{normalize_title(title)}|{normalize_company(company)}"


def merge_postings(a: JobPosting, b: JobPosting) -> JobPosting:
    """Keep `a`, fill gaps from `b` (longer description, salary, url)."""
    if len(b.description or "") > len(a.description or ""):
        a.description = b.description
    if a.salary_min is None and a.salary_max is None and (b.salary_min or b.salary_max):
        a.salary_min, a.salary_max, a.salary_predicted = b.salary_min, b.salary_max, b.salary_predicted
    if b.source != a.source:
        a.extra.setdefault("also_seen", set()).add(b.source)
    a.url = a.url or b.url
    a.location = a.location or b.location
    a.remote = a.remote or b.remote
    return a


def dedupe(postings: list[JobPosting]) -> list[JobPosting]:
    seen: dict[str, JobPosting] = {}
    for p in postings:
        key = dedup_key(p.title, p.company)
        if key in seen:
            merge_postings(seen[key], p)
        else:
            seen[key] = p
    return list(seen.values())
