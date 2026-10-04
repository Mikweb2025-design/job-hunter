"""Working links for jobs (same rules as the macOS app's JobLinks.swift).

Job-alert mails from StepStone only carry tracking redirects (click.stepstone.de/…) that often
stop working outside the mail. For those we offer a StepStone search for title + company, a web
search and the company's careers page instead.
"""
from __future__ import annotations

import re
from urllib.parse import quote_plus, urlparse

TRACKING_HOSTS = ("click.stepstone.de", "email.stepstone.de", "jobagent.stepstone.de")


def is_tracking(url: str | None) -> bool:
    host = (urlparse(url or "").hostname or "").lower()
    return any(host == h or host.endswith("." + h) for h in TRACKING_HOSTS)


def slug(s: str) -> str:
    t = (s or "").lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        t = t.replace(a, b)
    t = re.sub(r"\([^)]*\)", " ", t)
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


def _city(location: str | None) -> str:
    first = (location or "").split(",")[0].strip()
    return re.sub(r"^\d{5}\s*", "", first)


def stepstone_search(job: dict) -> str | None:
    kw = slug(f"{job.get('title') or ''} {job.get('company') or ''}")
    if not kw:
        return None
    url = f"https://www.stepstone.de/jobs/{kw}"
    city = slug(_city(job.get("location")))
    return url + (f"/in-{city}" if city else "")


def _search(q: str) -> str:
    return "https://www.google.com/search?q=" + quote_plus(q)


def apply_link(job: dict) -> str | None:
    """Best link for 'Jetzt manuell bewerben': the original, unless it is a tracking redirect."""
    url = job.get("url")
    if url and not is_tracking(url):
        return url
    if job.get("source") == "stepstone-alert" or is_tracking(url):
        return stepstone_search(job) or url
    return url


def alternatives(job: dict) -> list[dict]:
    out: list[dict] = []
    url, title, company = job.get("url"), job.get("title") or "", job.get("company") or ""
    if job.get("source") == "stepstone-alert" or is_tracking(url):
        s = stepstone_search(job)
        if s:
            out.append({"title": "Auf StepStone suchen", "url": s})
    out.append({"title": "Im Web suchen (Titel + Firma)", "url": _search(f'"{title}" {company} Stellenanzeige')})
    if company:
        out.append({"title": "Karriereseite der Firma suchen", "url": _search(f"{company} Karriere {title}")})
    if url and is_tracking(url):
        out.append({"title": "Link aus der E-Mail (Tracking, evtl. abgelaufen)", "url": url})
    return out
