"""Learns from the real outcomes of past applications (bonus/malus on top of the rule score).

Every application with a decided outcome counts:
  positive – Gespräch/Angebot, or (still open) the employer asked back or wanted documents
  negative – Absage by the company after applying (not "kein Interesse"/"Duplikat")
Applications still without an answer teach nothing.

Features of a job: the words of its normalized title ("support", "cloud", "administrator" …),
the channel (agency vs. direct employer) and the place (Berlin on site vs. remote).
Each feature needs MIN_EVIDENCE decided outcomes; its weight is its smoothed success rate
minus the overall success rate (so the general rejection rate does not push every job down). A job's bonus is the average weight over all its features
(unknown = 0) times SCALE, capped at ±MAX_LEARNED. With few data the bonus stays small on purpose.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from .dedup import normalize_title

MAX_LEARNED = 10.0
SCALE = 20.0
MIN_EVIDENCE = 2
PRIOR = 2.0

POSITIVE_STATUS = ("gespraech", "angebot")
POSITIVE_REPLIES = ("einladung", "rueckfrage", "unterlagen")
EMPLOYER_REASONS = ("", "absage_firma", "stelle_besetzt")  # same as tracker.EMPLOYER_ABSAGE

# Staffing agencies / recruiters: applications there rarely led to a conversation.
AGENCY_RE = re.compile(
    r"personal[\s-]?(dienst|service|vermittlung|beratung|partner|management)|"
    r"zeitarbeit|arbeitnehmerüberlassung|recruiting|recruitment|staffing|headhunt|"
    r"\bpersonal gmbh|für unseren kunden|im auftrag unseres kunden|unser(en)? mandant",
    re.I)

STOP_WORDS = {"m", "w", "d", "f", "x", "gn", "all", "genders", "mwd", "in", "und", "and", "der", "die",
              "das", "für", "fur", "for", "mit", "im", "am", "zum", "zur", "vollzeit", "teilzeit", "de",
              "mensch", "berlin", "remote", "homeoffice", "the", "of", "a"}


def is_agency(company: str | None, description: str | None = "") -> bool:
    return bool(AGENCY_RE.search(f"{company or ''}\n{(description or '')[:1500]}"))


def features(job: dict) -> set[str]:
    words = {w for w in normalize_title(job.get("title") or "").split()
             if len(w) > 1 and w not in STOP_WORDS and not w.isdigit()}
    out = {f"t:{w}" for w in words}
    out.add("agency" if is_agency(job.get("company"), job.get("description")) else "direct")
    out.add("remote" if job.get("remote") else "onsite")
    return out


def outcome(job: dict) -> int | None:
    """+1 positive, -1 negative, None = no decided outcome (or never applied)."""
    status, reply = job.get("status"), job.get("reply_kind")
    applied = bool(job.get("applied_date") or reply)
    if status in POSITIVE_STATUS:
        return 1
    if status == "absage":
        # Only a rejection by the employer after applying; "kein Interesse"/"Duplikat" teach nothing.
        if applied and (job.get("close_reason") or "") in EMPLOYER_REASONS:
            return -1
        return None
    if status == "beworben" and reply in POSITIVE_REPLIES:
        return 1
    return None


@dataclass
class OutcomeModel:
    weights: dict[str, float] = field(default_factory=dict)
    counts: dict[str, tuple[int, int]] = field(default_factory=dict)
    samples: int = 0

    @classmethod
    def build(cls, jobs: list[dict]) -> "OutcomeModel":
        pos: dict[str, int] = {}
        neg: dict[str, int] = {}
        samples = 0
        for j in jobs:
            o = outcome(j)
            if o is None:
                continue
            samples += 1
            for f in features(j):
                (pos if o > 0 else neg)[f] = (pos if o > 0 else neg).get(f, 0) + 1
        weights, counts = {}, {}
        total_pos = sum(1 for j in jobs if outcome(j) == 1)
        base = total_pos / samples if samples else 0.5
        for f in set(pos) | set(neg):
            p, n = pos.get(f, 0), neg.get(f, 0)
            if p + n >= MIN_EVIDENCE:
                # Smoothed success rate of the feature minus the overall rate (×2 → about -1…+1):
                # with mostly rejections overall, only features that do *worse* than usual get a malus.
                weights[f] = 2 * ((p + PRIOR * base) / (p + n + PRIOR) - base)
                counts[f] = (p, n)
        return cls(weights, counts, samples)

    def score(self, job: dict) -> tuple[float, list[str]]:
        feats = features(job)
        known = [f for f in feats if f in self.weights]
        if not known:
            return 0.0, []
        # Unknown features count as 0: one known trait alone (e.g. "direkt") moves a job only a little.
        avg = sum(self.weights[f] for f in known) / len(feats)
        pts = max(-MAX_LEARNED, min(MAX_LEARNED, avg * SCALE))
        known.sort(key=lambda f: -abs(self.weights[f]))
        reasons = [f"{_label(f)} {self.counts[f][0]}✓/{self.counts[f][1]}✗" for f in known[:4]]
        return round(pts, 1), reasons


def _label(feature: str) -> str:
    return {"agency": "Agentur", "direct": "direkt", "remote": "remote", "onsite": "vor Ort"}.get(
        feature, feature[2:] if feature.startswith("t:") else feature)


def from_db(db) -> OutcomeModel:
    return OutcomeModel.build(db.list_jobs(limit=100000))


# The model in use: rebuilt at server start, before every search run and every re-score,
# so all scoring paths (search, alert import, pasted posting text) use the same outcomes.
_ACTIVE = OutcomeModel()


def active() -> OutcomeModel:
    return _ACTIVE


def refresh(db) -> OutcomeModel:
    global _ACTIVE
    _ACTIVE = from_db(db)
    return _ACTIVE
