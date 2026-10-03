"""Fast, deterministic rule-based scoring (0-100).

Components (max points):
  keywords  40  weighted CV keywords found in title+description (saturating)
  title     25  posting title matches one of the target titles
  location  15  in configured location(s) or remote possible (if remote_ok)
  salary    20  salary vs. minimum; unknown salary = neutral (10)
  penalty  -30  excluded keywords in description (-10 each)
An excluded keyword in the *title* forces the score to 0.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

from .config import SearchProfile
from .dedup import normalize_title
from .models import JobPosting

MAX_KEYWORDS, MAX_TITLE, MAX_LOCATION, MAX_SALARY = 40, 25, 15, 20
SALARY_NEUTRAL = 10


@dataclass
class CVProfile:
    text: str = ""
    keywords: dict[str, float] = field(default_factory=dict)
    results: list[str] = field(default_factory=list)  # concrete results/achievements

    @classmethod
    def parse(cls, text: str, extra_weights: dict[str, float] | None = None) -> "CVProfile":
        sections: dict[str, list[str]] = {}
        current = ""
        for line in re.sub(r"<!--.*?-->", "", text, flags=re.S).splitlines():
            m = re.match(r"^#{2,3}\s+(.*)$", line.strip())
            if m:
                current = m.group(1).strip().lower()
                sections.setdefault(current, [])
            elif current:
                sections[current].append(line)

        def section(*names: str) -> list[str]:
            for key, lines in sections.items():
                if any(key.startswith(n) for n in names):
                    return lines
            return []

        keywords: dict[str, float] = {}
        for line in section("keywords", "schlüsselwörter", "skills"):
            line = line.strip().lstrip("-*").strip()
            if not line:
                continue
            for part in line.split(","):
                kw = part.strip()
                if not kw:
                    continue
                weight = 1.0
                m = re.match(r"^(.*?)\s*[:=]\s*([\d.]+)$", kw)
                if m:
                    kw, weight = m.group(1).strip(), float(m.group(2))
                keywords[kw] = weight
        for kw, w in (extra_weights or {}).items():
            keywords[kw] = float(w)

        results = [
            l.strip().lstrip("-*").strip()
            for l in section("kernergebnisse", "ergebnisse", "results", "erfolge")
            if l.strip().lstrip("-*").strip()
        ]
        return cls(text=text, keywords=keywords, results=results)

    @classmethod
    def load(cls, path: Path, extra_weights: dict[str, float] | None = None) -> "CVProfile":
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        return cls.parse(text, extra_weights)


@lru_cache(maxsize=2048)
def _kw_regex(keyword: str) -> re.Pattern[str]:
    # Word-ish boundaries that also work for terms like "C++", "S3", ".NET", "CI/CD".
    return re.compile(r"(?<![\w])" + re.escape(keyword.lower()) + r"(?![\w+#])")


def find_keywords(text: str, keywords: list[str] | dict[str, float]) -> list[str]:
    low = (text or "").lower()
    return [kw for kw in keywords if kw and _kw_regex(kw).search(low)]


@dataclass
class ScoreResult:
    score: int
    breakdown: dict

    @property
    def excluded(self) -> bool:
        return bool(self.breakdown.get("excluded"))


def _title_points(title: str, targets: list[str]) -> tuple[float, str | None]:
    nt = normalize_title(title)
    best, best_target = 0.0, None
    title_tokens = set(nt.split())
    for target in targets:
        tt = normalize_title(target)
        if not tt:
            continue
        if re.search(r"(?<![a-z0-9])" + re.escape(tt) + r"(?![a-z0-9])", nt):
            return float(MAX_TITLE), target
        tokens = set(tt.split())
        overlap = len(tokens & title_tokens) / len(tokens)
        if overlap >= 0.5 and overlap * MAX_TITLE * 0.6 > best:
            best, best_target = overlap * MAX_TITLE * 0.6, target
    return best, best_target


def _location_points(job: JobPosting, profile: SearchProfile) -> tuple[float, str]:
    loc = (job.location or "").lower()
    places = [profile.location, *profile.extra_locations]
    if any(p and p.lower() in loc for p in places):
        return float(MAX_LOCATION), "ort"
    if job.remote and profile.remote_ok:
        return float(MAX_LOCATION), "remote"
    if not loc:
        return 5.0, "unbekannt"
    return 0.0, "anderer Ort"


def _salary_points(job: JobPosting, min_salary: int) -> tuple[float, str]:
    top = job.salary_max or job.salary_min
    if not top or job.salary_predicted:
        return float(SALARY_NEUTRAL), "unbekannt" if not top else "geschätzt (neutral)"
    if top >= min_salary:
        return float(MAX_SALARY), "ok"
    if top >= min_salary * 0.9:
        return 5.0, "knapp darunter"
    return 0.0, "zu niedrig"


def score_job(job: JobPosting, profile: SearchProfile, cv: CVProfile) -> ScoreResult:
    text = f"{job.title}\n{job.description}"
    bd: dict = {}

    excl_title = find_keywords(job.title, profile.excluded_title_keywords + profile.excluded_keywords)
    if excl_title:
        bd = {"excluded": excl_title, "keywords": 0, "title": 0, "location": 0, "salary": 0,
              "penalty": 0, "matched": []}
        return ScoreResult(0, bd)

    matched = find_keywords(text, cv.keywords)
    raw = sum(cv.keywords[k] for k in matched)
    sat = max(profile.keyword_saturation, 1.0)
    kw_pts = MAX_KEYWORDS * min(raw / sat, 1.0)

    title_pts, title_target = _title_points(job.title, profile.target_titles)
    loc_pts, loc_reason = _location_points(job, profile)
    sal_pts, sal_reason = _salary_points(job, profile.min_salary)

    excl_desc = find_keywords(job.description, profile.excluded_keywords)
    penalty = min(10 * len(excl_desc), 30)

    total = kw_pts + title_pts + loc_pts + sal_pts - penalty
    score = int(round(max(0.0, min(100.0, total))))
    bd = {
        "keywords": round(kw_pts, 1),
        "matched": sorted(matched, key=lambda k: -cv.keywords[k]),
        "title": round(title_pts, 1),
        "title_match": title_target,
        "location": loc_pts,
        "location_reason": loc_reason,
        "salary": sal_pts,
        "salary_reason": sal_reason,
        "penalty": -penalty,
        "excluded_in_text": excl_desc,
        "excluded": [],
    }
    return ScoreResult(score, bd)


def combined_score(rule_score: int | None, llm_score: int | None) -> int:
    if llm_score is None:
        return int(rule_score or 0)
    return int(round(((rule_score or 0) + llm_score) / 2))
