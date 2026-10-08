"""Home-region gate: only jobs in Berlin/Brandenburg or 100% remote go out automatically.

The user does not want to relocate. Automatic e-mail applications are therefore
limited to:

* jobs in the home region (Berlin or Brandenburg), or
* jobs that are explicitly 100% remote.

Anything else (e.g. "Homeoffice möglich" / "mobiles Arbeiten möglich" for a job
in Köln, Kiel or Nürnberg – which is hybrid, not remote) is classified as
"zu weit weg" (too far) and never sent automatically. Manual applications
through the portal stay possible.
"""
from __future__ import annotations

import re

# Brandenburg towns/cities (selection – covers the places that actually appear
# in job ads; "Brandenburg" itself and the PLZ ranges below catch the rest).
BRANDENBURG_PLACES = [
    "brandenburg", "potsdam", "cottbus", "frankfurt (oder)", "frankfurt/oder",
    "oranienburg", "falkensee", "bernau", "königs wusterhausen", "eberwalde",
    "neuehagen", "eberswalde", "schwedt", "neuruppin", "luckenwalde",
    "fürstenwalde", "strausberg", "hennigsdorf", "senftenberg", "spremberg",
    "rathenow", "teltow", "werder", "jüterbog", "zossen", "wildau", "erkner",
    "grünheide", "schönefeld", "ludwigsfelde", "blankenfelde", "hohen neuendorf",
    "birkenwerder", "velten", "kremmen", "nauen", "kyritz", "wittstock",
    "pritzwalk", "perleberg", "wittenberge", "bad belzig", "beelitz",
    "treuenbrietzen", "lübben", "lübbenau", "herzberg", "finsterwalde",
    "elsterwerda", "eisenhüttenstadt", "guben", "forst", "prenzlau", "templin",
    "angermünde", "beeskow", "storkow", "petershagen", "fredersdorf",
    "hoppegarten", "rüdersdorf", "woltersdorf", "schöneiche", "kleinmachnow",
    "stahnsdorf", "michendorf", "nuthetal", "großbeeren", "rangsdorf",
    "mittenwalde", "bestensee", "eichwalde", "zeuthen", "schulzendorf",
    "schleife", "weißwasser", "schönow", "birkenwerder", "glienicke",
    "mühlenbeck", "schildow", "dallgow", "wustermark", "brieselang",
    "ottenhagen", "dahlewitz", "blankenfelde-mahlow", "mahlow",
]

_BERLIN_RE = re.compile(r"\bberlin\b", re.IGNORECASE)
# Berlin PLZ 10115–14199 + near Brandenburg around Berlin/Potsdam (14xxx) + Cottbus (03xxx).
_HOME_PLZ_RE = re.compile(r"\b(0[3]\d{3}|1[0-4]\d{3})\b")

_STANDORT_RE = re.compile(
    r"(?:standort|arbeitsort|dienstort|einsatzort)\s*[:\-–]?\s*([^\n,;|]{2,60})",
    re.IGNORECASE,
)


def _norm(text: str | None) -> str:
    return (text or "").strip().lower()


def in_home_region(job: dict) -> bool:
    """True if the job is in Berlin or Brandenburg.

    Primary source is the `location` field; if that is empty we fall back to a
    "Standort:" line in the description. Multi-location ads ("München, Berlin")
    count as home region – the Berlin office is an option.
    """
    loc = _norm(job.get("location"))
    if _BERLIN_RE.search(loc) or _HOME_PLZ_RE.search(loc):
        return True
    if any(place in loc for place in BRANDENBURG_PLACES):
        return True
    if not loc:
        # No location stored – look for an explicit place in the ad text.
        m = _STANDORT_RE.search(job.get("description") or "")
        if m:
            site = m.group(1).lower()
            if _BERLIN_RE.search(site):
                return True
            if any(place in site for place in BRANDENBURG_PLACES):
                return True
    return False


# Explicit "this job is fully remote" signals (title + description).
_FULL_REMOTE_RES = [
    re.compile(r"100\s*%\s*(remote|home[ -]?office|mobiles arbeiten|mobil)", re.I),
    re.compile(r"(vollst[äa]ndig|komplett|ausschlie[ßs]lich)\s+"
               r"(remote|im home[ -]?office|von zu ?hause|mobiles arbeiten)", re.I),
    re.compile(r"fully\s+remote|remote\s*-?\s*first", re.I),
    re.compile(r"ortsunabh[äa]ngig|work from anywhere", re.I),
    re.compile(r"arbeiten von [üu]berall|von [üu]berall arbeiten", re.I),
    re.compile(r"rein\w*\s+(remote|home[ -]?office)[- ]?(t[äa]tigkeit|stelle|arbeit|position|job)?", re.I),
    re.compile(r"deutschlandweit\s+(remote|im home[ -]?office)", re.I),
    re.compile(r"(remote|home[ -]?office)\s+deutschlandweit", re.I),
    re.compile(r"remote\s*\(deutschlandweit\)", re.I),
]

# Weak/hybrid signals – do NOT count as 100% remote on their own.
# (Kept for documentation; full-remote needs one of the explicit patterns above.)
_HYBRID_RES = [
    re.compile(r"home[ -]?office\s+m[öo]glich", re.I),
    re.compile(r"mobiles arbeiten(\s+m[öo]glich)?", re.I),
    re.compile(r"remote\s+m[öo]glich|\bm[öo]glichkeit.*remote", re.I),
    re.compile(r"hybrid", re.I),
]


def is_full_remote(job: dict) -> bool:
    """True only with an explicit 100%-remote statement.

    "Homeoffice möglich" or the Bundesagentur `remote` flag alone mean hybrid
    (1–2 days on site somewhere far away) – that is NOT enough.
    """
    text = f"{job.get('title') or ''}\n{job.get('description') or ''}"
    return any(r.search(text) for r in _FULL_REMOTE_RES)


def location_ok(job: dict) -> tuple[bool, str]:
    """(ok, reason) with reason in {"heimatregion", "remote100", "zu_weit"}."""
    if in_home_region(job):
        return True, "heimatregion"
    if is_full_remote(job):
        return True, "remote100"
    return False, "zu_weit"


def location_label(job: dict) -> str:
    """Short human-readable explanation for the UI."""
    ok, reason = location_ok(job)
    if reason == "heimatregion":
        return "Berlin/Brandenburg"
    if reason == "remote100":
        return "100 % Remote"
    if not (job.get("location") or "").strip():
        return "Ort unbekannt, kein 100 % Remote"
    return f"{(job.get('location') or '').strip()} – zu weit weg"
