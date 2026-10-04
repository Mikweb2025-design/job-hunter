"""Editable search profile, job sources and CV profile ("Suchprofil & Profil").

config.yaml stays the base (it is never written by the app and never overwritten by deploys);
changes made in the dashboard / macOS app are stored as overrides in the DB table `settings`:

  search_profile  {field: value}           only the edited fields of `search:`
  sources         {source: {option: value}} per-source enable/options (`sources:`)
  cv_profile      {text, saved_at, file_sha} the CV profile text (also written to data/cv_profile.md)

Effective values = config.yaml merged with the override (`apply_overrides`, called at startup
and after every save). The settings object is shared, so the pipeline, scoring and letters use
the new values immediately.
"""
from __future__ import annotations

import copy
import dataclasses
import hashlib
import logging
import re
import threading
import time
from collections import Counter
from datetime import datetime, timezone
from typing import Any, Callable

from .config import SearchProfile, Settings
from .db import Database
from .dedup import _GENDER_RE, dedup_key
from .scoring import CVProfile, find_keywords
from .sources import OPT_IN, REGISTRY, Source
from .sources.ats import ATS_TYPES, TOKEN_RE
from .sources.base import place_ok, remote_geo_ok, title_matches

log = logging.getLogger(__name__)

KEY_PROFILE, KEY_SOURCES, KEY_CV = "search_profile", "sources", "cv_profile"

# ---- search profile ----------------------------------------------------------------------
LIST_FIELDS = ("queries", "target_titles", "excluded_title_keywords", "excluded_keywords", "extra_locations")
EDITABLE = ("queries", "location", "radius_km", "remote_ok", "days_back", "min_salary", "target_titles",
            "excluded_title_keywords", "excluded_keywords", "keyword_weights", "keyword_saturation",
            "extra_locations")
LIMITS = {
    "queries": {"min_items": 1, "max_items": 30, "max_len": 80},
    "target_titles": {"max_items": 60, "max_len": 80},
    "excluded_title_keywords": {"max_items": 100, "max_len": 60},
    "excluded_keywords": {"max_items": 100, "max_len": 60},
    "extra_locations": {"max_items": 10, "max_len": 60},
    "location": {"max_len": 80},
    "radius_km": {"min": 0, "max": 200},
    "days_back": {"min": 1, "max": 100},
    "min_salary": {"min": 0, "max": 300000},
    "keyword_weights": {"max_items": 200, "min": 0, "max": 10, "max_len": 60},
    "keyword_saturation": {"min": 1, "max": 100},
}


class ProfileError(ValueError):
    """Validation failed; `errors` maps field → German message."""

    def __init__(self, errors: dict[str, str]):
        super().__init__("; ".join(f"{k}: {v}" for k, v in errors.items()))
        self.errors = errors


def profile_dict(p: SearchProfile) -> dict[str, Any]:
    return {k: copy.deepcopy(getattr(p, k)) for k in EDITABLE}


def _clean_list(values: Any, field: str, errors: dict[str, str]) -> list[str]:
    lim = LIMITS[field]
    if not isinstance(values, list):
        errors[field] = "Liste erwartet"
        return []
    out: list[str] = []
    seen: set[str] = set()
    for v in values:
        if not isinstance(v, str):
            errors[field] = "nur Text erlaubt"
            return []
        v = " ".join(v.split())
        if not v:
            continue
        if len(v) > lim["max_len"]:
            errors[field] = f"„{v[:30]}…“ ist zu lang (max. {lim['max_len']} Zeichen)"
            return []
        if v.lower() not in seen:
            seen.add(v.lower())
            out.append(v)
    if len(out) < lim.get("min_items", 0):
        errors[field] = "mindestens ein Suchbegriff nötig"
    if len(out) > lim["max_items"]:
        errors[field] = f"höchstens {lim['max_items']} Einträge"
    return out


def _num(value: Any, field: str, errors: dict[str, str], integer: bool = True):
    lim = LIMITS[field]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        try:
            value = float(str(value).replace(",", "."))
        except ValueError:
            errors[field] = "Zahl erwartet"
            return None
    if integer:
        value = int(round(value))
    if not lim["min"] <= value <= lim["max"]:
        errors[field] = f"muss zwischen {lim['min']} und {lim['max']} liegen"
        return None
    return value


def validate_profile(data: dict[str, Any]) -> dict[str, Any]:
    """Validates a partial profile (only the given fields). Returns the cleaned dict or raises
    ProfileError."""
    if not isinstance(data, dict):
        raise ProfileError({"profile": "Objekt erwartet"})
    errors: dict[str, str] = {}
    out: dict[str, Any] = {}
    for key, value in data.items():
        if key not in EDITABLE:
            errors[key] = "unbekanntes Feld"
        elif key in LIST_FIELDS:
            out[key] = _clean_list(value, key, errors)
        elif key == "location":
            v = " ".join(str(value or "").split())
            if not v:
                errors[key] = "Ort darf nicht leer sein"
            elif len(v) > LIMITS[key]["max_len"]:
                errors[key] = "zu lang"
            out[key] = v
        elif key == "remote_ok":
            if not isinstance(value, bool):
                errors[key] = "true/false erwartet"
            out[key] = bool(value)
        elif key in ("radius_km", "days_back", "min_salary"):
            out[key] = _num(value, key, errors)
        elif key == "keyword_saturation":
            out[key] = _num(value, key, errors, integer=False)
        elif key == "keyword_weights":
            lim = LIMITS[key]
            if not isinstance(value, dict):
                errors[key] = "Objekt {Keyword: Gewicht} erwartet"
                continue
            if len(value) > lim["max_items"]:
                errors[key] = f"höchstens {lim['max_items']} Keywords"
                continue
            weights: dict[str, float] = {}
            for kw, w in value.items():
                kw = " ".join(str(kw).split())
                if not kw or len(kw) > lim["max_len"]:
                    errors[key] = f"ungültiges Keyword „{kw[:30]}“"
                    break
                try:
                    w = float(w)
                except (TypeError, ValueError):
                    errors[key] = f"Gewicht für „{kw}“ ist keine Zahl"
                    break
                if not lim["min"] <= w <= lim["max"]:
                    errors[key] = f"Gewicht für „{kw}“ muss zwischen {lim['min']} und {lim['max']} liegen"
                    break
                weights[kw] = w
            out[key] = weights
    if errors:
        raise ProfileError(errors)
    return out


def merge_profile(base: SearchProfile, override: dict[str, Any]) -> SearchProfile:
    return dataclasses.replace(base, **{k: copy.deepcopy(v) for k, v in (override or {}).items() if k in EDITABLE})


# ---- sources -----------------------------------------------------------------------------
# Options the UI may change per source (type, limits). Secrets (Adzuna keys) are never editable.
SOURCE_INFO: dict[str, dict[str, Any]] = {
    "arbeitsagentur": {"label": "Arbeitsagentur (Jobbörse der BA)", "kind": "Suche",
                       "info": "Offizielle, öffentliche Such-API der Bundesagentur für Arbeit.",
                       "options": {"max_pages": ("int", 1, 5), "remote_search": ("bool",)}},
    "adzuna": {"label": "Adzuna", "kind": "Suche",
               "info": "Braucht kostenlose Schlüssel ADZUNA_APP_ID / ADZUNA_APP_KEY in der .env des Servers "
                       "(selbst eintragen, nie hier).",
               "url": "https://developer.adzuna.com/signup",
               "options": {"max_pages": ("int", 1, 3)}},
    "arbeitnow": {"label": "Arbeitnow", "kind": "Feed",
                  "info": "Freie Job-API (viele Berliner Tech-Firmen). Lokal nach Titel und Ort gefiltert.",
                  "url": "https://www.arbeitnow.com/blog/job-board-api",
                  "options": {"max_pages": ("int", 1, 3)}},
    "remotive": {"label": "Remotive (Remote)", "kind": "Feed",
                 "info": "Remote-Stellen, die für Deutschland/Europa offen sind. Max. 1 Abruf pro Lauf.",
                 "url": "https://remotive.com/api-documentation",
                 "options": {"category": ("choice", "", "customer-support", "devops", "software-dev",
                                          "all-others")}},
    "jobicy": {"label": "Jobicy (Remote)", "kind": "Feed",
               "info": "Remote-Stellen mit Region Deutschland/EMEA/Europa/weltweit.",
               "url": "https://jobicy.com/jobs-rss-feed",
               "options": {"geo": ("choice", "germany", "emea", "europe")}},
    "berlinstartupjobs": {"label": "Berlin Startup Jobs", "kind": "Feed",
                          "info": "Öffentliche RSS-Feeds (Engineering + alle). Nur Berlin.",
                          "url": "https://berlinstartupjobs.com/", "options": {}},
    "ats": {"label": "Karriereseiten von Firmen", "kind": "Firmen",
            "info": "Öffentliche Job-Feeds der Bewerbermanagement-Systeme (Greenhouse, Lever, Personio, "
                    "SmartRecruiters) – ein Abruf pro Firma. Kürzel = Teil der Karriere-URL, z. B. "
                    "boards.greenhouse.io/<kürzel>.",
            "options": {"companies": ("companies",)}},
    "rss": {"label": "Eigene RSS-Feeds", "kind": "Feed", "info": "Beliebige RSS/Atom-Job-Feeds.",
            "options": {"feeds": ("feeds",)}},
}
# Verified 04.10.2026 (one request each): these tokens return live postings.
ATS_EXAMPLES = [
    {"ats": "greenhouse", "token": "sumup", "name": "SumUp"},
    {"ats": "greenhouse", "token": "n26", "name": "N26"},
    {"ats": "greenhouse", "token": "getyourguide", "name": "GetYourGuide"},
    {"ats": "greenhouse", "token": "contentful", "name": "Contentful"},
    {"ats": "greenhouse", "token": "hellofresh", "name": "HelloFresh"},
    {"ats": "smartrecruiters", "token": "DeliveryHero", "name": "Delivery Hero"},
]


def validate_sources(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    if not isinstance(data, dict):
        raise ProfileError({"sources": "Objekt erwartet"})
    errors: dict[str, str] = {}
    out: dict[str, dict[str, Any]] = {}
    for name, opts in data.items():
        if name not in SOURCE_INFO:
            errors[name] = "unbekannte Quelle"
            continue
        if not isinstance(opts, dict):
            errors[name] = "Objekt erwartet"
            continue
        clean: dict[str, Any] = {}
        spec = SOURCE_INFO[name]["options"]
        for key, value in opts.items():
            f = f"{name}.{key}"
            if key == "enabled":
                if not isinstance(value, bool):
                    errors[f] = "true/false erwartet"
                clean[key] = bool(value)
                continue
            if key not in spec:
                errors[f] = "nicht änderbar"
                continue
            kind = spec[key][0]
            if kind == "int":
                lo, hi = spec[key][1], spec[key][2]
                if isinstance(value, bool) or not isinstance(value, int) or not lo <= value <= hi:
                    errors[f] = f"Zahl {lo}–{hi} erwartet"
                clean[key] = value
            elif kind == "bool":
                if not isinstance(value, bool):
                    errors[f] = "true/false erwartet"
                clean[key] = bool(value)
            elif kind == "choice":
                if value not in spec[key][1:]:
                    errors[f] = "unbekannter Wert"
                clean[key] = value
            elif kind == "companies":
                clean[key] = _clean_companies(value, f, errors)
            elif kind == "feeds":
                clean[key] = _clean_feeds(value, f, errors)
        out[name] = clean
    if errors:
        raise ProfileError(errors)
    return out


def _clean_companies(value: Any, f: str, errors: dict[str, str]) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > 40:
        errors[f] = "Liste mit höchstens 40 Firmen erwartet"
        return []
    out, seen = [], set()
    for c in value:
        if not isinstance(c, dict):
            errors[f] = "Firma als Objekt erwartet"
            return []
        ats = str(c.get("ats") or "").lower().strip()
        token = str(c.get("token") or "").strip()
        name = " ".join(str(c.get("name") or token).split())[:80]
        if ats not in ATS_TYPES:
            errors[f] = f"System „{ats}“ unbekannt (greenhouse, lever, personio, smartrecruiters)"
            return []
        if not TOKEN_RE.match(token):
            errors[f] = f"Kürzel „{token[:30]}“ ungültig (nur Buchstaben, Ziffern, . _ -)"
            return []
        if (ats, token.lower()) in seen:
            continue
        seen.add((ats, token.lower()))
        out.append({"ats": ats, "token": token, "name": name, "enabled": bool(c.get("enabled", True))})
    return out


def _clean_feeds(value: Any, f: str, errors: dict[str, str]) -> list[dict[str, str]]:
    if not isinstance(value, list) or len(value) > 10:
        errors[f] = "Liste mit höchstens 10 Feeds erwartet"
        return []
    out = []
    for feed in value:
        feed = {"url": feed} if isinstance(feed, str) else feed
        url = str((feed or {}).get("url") or "").strip()
        if not re.match(r"^https?://[^\s/]+\.[^\s]+$", url) or len(url) > 500:
            errors[f] = f"ungültige Feed-URL „{url[:40]}“"
            return []
        item = {"url": url}
        for k in ("name", "title_separator", "location"):
            if (feed or {}).get(k):
                item[k] = str(feed[k])[:60]
        out.append(item)
    return out


def merge_sources(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(base or {})
    for name, opts in (override or {}).items():
        out[name] = {**(out.get(name) or {}), **copy.deepcopy(opts)}
    return out


def source_enabled(name: str, opts: dict[str, Any] | None) -> bool:
    if opts is None:
        return name == "arbeitsagentur"
    return bool(opts.get("enabled", name not in OPT_IN))


def sources_payload(settings: Settings) -> list[dict[str, Any]]:
    out = []
    for name, info in SOURCE_INFO.items():
        opts = (settings.sources or {}).get(name)
        src = REGISTRY[name](opts or {})
        configured, reason = src.is_configured()
        options = {k: (opts or {}).get(k, _default_option(name, k)) for k in info["options"]}
        out.append({"id": name, "label": info["label"], "kind": info["kind"], "info": info["info"],
                    "url": info.get("url"), "enabled": source_enabled(name, opts),
                    "configured": configured, "reason": reason or None, "options": options,
                    "option_types": {k: list(v) for k, v in info["options"].items()}})
    return out


def _default_option(source: str, key: str) -> Any:
    return {"max_pages": 2 if source == "arbeitsagentur" else 1, "remote_search": True, "category": "",
            "geo": "germany", "companies": [], "feeds": []}.get(key)


# ---- apply / save / reset ------------------------------------------------------------------
_apply_lock = threading.Lock()


KEY_SEND = "send_overrides"
AUTO_SCORE_MIN, AUTO_SCORE_MAX = 50, 100
_send_base: dict[int, int] = {}  # id(settings) -> auto_min_score from config.yaml


def validate_auto_min_score(value: Any) -> int:
    try:
        v = int(value)
    except (TypeError, ValueError):
        raise ProfileError({"auto_min_score": "Bitte eine ganze Zahl angeben."}) from None
    if not AUTO_SCORE_MIN <= v <= AUTO_SCORE_MAX:
        raise ProfileError({"auto_min_score": f"Erlaubt: {AUTO_SCORE_MIN}–{AUTO_SCORE_MAX}."})
    return v


def set_auto_min_score(settings: Settings, db: Database, value: Any | None) -> None:
    """Minimum score for automatic e-mail sending (UI override; None = back to config.yaml).
    Only this one value is editable – mode, dry_run, daily cap and blocklist stay in config.yaml."""
    over = dict(db.get_setting(KEY_SEND) or {})
    if value is None:
        over.pop("auto_min_score", None)
    else:
        over["auto_min_score"] = validate_auto_min_score(value)
    db.set_setting(KEY_SEND, over)
    apply_overrides(settings, db)


def auto_min_score_info(settings: Settings, db: Database) -> dict[str, Any]:
    base = _send_base.get(id(settings), settings.send.auto_min_score)
    over = (db.get_setting(KEY_SEND) or {}).get("auto_min_score")
    return {"auto_min_score": settings.send.auto_min_score, "config_value": base,
            "overridden": over is not None, "min": AUTO_SCORE_MIN, "max": AUTO_SCORE_MAX}


def apply_overrides(settings: Settings, db: Database) -> None:
    """settings.profile/sources = config.yaml (kept in profile_base/sources_base) + DB override."""
    with _apply_lock:
        if settings.profile_base is None:
            settings.profile_base = copy.deepcopy(settings.profile)
        if settings.sources_base is None:
            settings.sources_base = copy.deepcopy(settings.sources or {})
        override = db.get_setting(KEY_PROFILE) or {}
        src_override = db.get_setting(KEY_SOURCES) or {}
        try:
            override = validate_profile(override)
        except ProfileError as exc:  # stored data from an older version: keep the valid fields only
            log.warning("search profile override partly invalid: %s", exc)
            override = {k: v for k, v in override.items() if k in EDITABLE and k not in exc.errors}
        settings.profile = merge_profile(settings.profile_base, override)
        settings.sources = merge_sources(settings.sources_base, src_override)
        base_score = _send_base.setdefault(id(settings), settings.send.auto_min_score)
        send_over = db.get_setting(KEY_SEND) or {}
        try:
            settings.send.auto_min_score = validate_auto_min_score(send_over.get("auto_min_score", base_score))
        except ProfileError:
            settings.send.auto_min_score = base_score


def payload(settings: Settings, db: Database) -> dict[str, Any]:
    base = profile_dict(settings.profile_base or settings.profile)
    eff = profile_dict(settings.profile)
    override = db.get_setting(KEY_PROFILE) or {}
    return {
        "profile": eff, "base": base, "override": override,
        "overridden": sorted(k for k in override if k in EDITABLE and override[k] != base.get(k)),
        "sources": sources_payload(settings), "sources_override": db.get_setting(KEY_SOURCES) or {},
        "ats_examples": ATS_EXAMPLES, "ats_types": ATS_TYPES, "limits": LIMITS,
        "updated_at": db.setting_updated_at(KEY_PROFILE), "rescore": rescore_status(),
    }


def save(settings: Settings, db: Database, profile: dict[str, Any] | None,
         sources: dict[str, Any] | None) -> None:
    """Validate and store (partial) changes, then apply them. Raises ProfileError."""
    clean_p = validate_profile(profile or {})
    clean_s = validate_sources(sources or {})
    base = profile_dict(settings.profile_base or settings.profile)
    if clean_p:
        override = {**(db.get_setting(KEY_PROFILE) or {}), **clean_p}
        # values equal to config.yaml are not overrides (so a later config change still applies)
        override = {k: v for k, v in override.items() if v != base.get(k)}
        db.set_setting(KEY_PROFILE, override)
    if clean_s:
        cur = db.get_setting(KEY_SOURCES) or {}
        base_src = settings.sources_base if settings.sources_base is not None else (settings.sources or {})
        for name, opts in clean_s.items():
            merged = {**cur.get(name, {}), **opts}
            base_opts = base_src.get(name)
            base_eff = {"enabled": source_enabled(name, base_opts),
                        **{k: (base_opts or {}).get(k, _default_option(name, k)) for k in SOURCE_INFO[name]["options"]}}
            # only real differences from config.yaml are stored (a later config change still applies)
            merged = {k: v for k, v in merged.items() if v != base_eff.get(k, object())}
            if merged:
                cur[name] = merged
            else:
                cur.pop(name, None)
        db.set_setting(KEY_SOURCES, cur)
    apply_overrides(settings, db)


def reset(settings: Settings, db: Database, what: str = "all") -> None:
    if what in ("all", "profile"):
        db.delete_setting(KEY_PROFILE)
    if what in ("all", "sources"):
        db.delete_setting(KEY_SOURCES)
    apply_overrides(settings, db)


# ---- rescore in the background ---------------------------------------------------------------
_rescore_lock = threading.Lock()
_rescore_state: dict[str, Any] = {"busy": False, "done": None, "finished_at": None, "error": None}


def rescore_status() -> dict[str, Any]:
    return dict(_rescore_state)


def start_rescore(settings: Settings, db: Database) -> bool:
    if not _rescore_lock.acquire(blocking=False):
        return False
    _rescore_state.update(busy=True, error=None)

    def work():
        from .pipeline import rescore_all
        try:
            _rescore_state["done"] = rescore_all(settings, db)
        except Exception as exc:  # pragma: no cover - logged for the UI
            log.exception("rescore failed")
            _rescore_state["error"] = str(exc)
        finally:
            _rescore_state.update(busy=False, finished_at=datetime.now(timezone.utc).replace(microsecond=0).isoformat())
            _rescore_lock.release()

    threading.Thread(target=work, daemon=True).start()
    return True


# ---- CV profile --------------------------------------------------------------------------------
CV_MAX = 50000
CV_WARNING = ("Nur wahre Angaben eintragen: Die KI schreibt die Anschreiben ausschließlich aus diesem Profil "
              "(und der Anzeige). Was hier steht, kann in Bewerbungen landen.")
MAX_BACKUPS = 20


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_cv(settings: Settings) -> str:
    return settings.cv_path.read_text(encoding="utf-8") if settings.cv_path.exists() else ""


def cv_backups(settings: Settings) -> list[str]:
    return sorted((p.name for p in settings.data_dir.glob("cv_profile.backup-*.md")), reverse=True)


def _backup(settings: Settings, text: str, tag: str = "backup") -> str | None:
    if not text.strip():
        return None
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = settings.data_dir / f"cv_profile.{tag}-{stamp}.md"
    n = 1
    while path.exists():
        n += 1
        path = settings.data_dir / f"cv_profile.{tag}-{stamp}-{n}.md"
    path.write_text(text, encoding="utf-8")
    for old in sorted(settings.data_dir.glob(f"cv_profile.{tag}-*.md"), reverse=True)[MAX_BACKUPS:]:
        old.unlink(missing_ok=True)
    return path.name


def cv_payload(settings: Settings, db: Database) -> dict[str, Any]:
    text = read_cv(settings)
    cv = CVProfile.parse(text, settings.profile.keyword_weights)
    stored = db.get_setting(KEY_CV) or {}
    return {"text": text, "path": str(settings.cv_path), "saved_at": stored.get("saved_at"),
            "keywords": len(cv.keywords), "results": len(cv.results), "backups": cv_backups(settings)[:10],
            "warning": CV_WARNING, "max_length": CV_MAX}


def save_cv(settings: Settings, db: Database, text: str) -> str | None:
    """Writes data/cv_profile.md (old version → data/cv_profile.backup-<zeit>.md) and keeps a copy
    in the DB so the edit survives a deploy. Returns the backup file name."""
    text = text.replace("\r\n", "\n")
    if not text.strip():
        raise ProfileError({"text": "Das Profil darf nicht leer sein"})
    if len(text) > CV_MAX:
        raise ProfileError({"text": f"höchstens {CV_MAX} Zeichen"})
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    old = read_cv(settings)
    backup = _backup(settings, old) if old != text else None
    settings.cv_path.write_text(text, encoding="utf-8")
    db.set_setting(KEY_CV, {"text": text, "saved_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
                            "file_sha": _sha(text)})
    return backup


def sync_cv_on_start(settings: Settings, db: Database) -> str:
    """After a deploy data/cv_profile.md may be the repo version again. Rule: if the file was not
    changed by someone else since the last UI save, the UI version (DB) wins and is written back;
    if the file was changed (new repo version on purpose), the file wins and the UI version is
    kept as data/cv_profile.ui-<zeit>.md. Returns "db", "file" or "same"."""
    stored = db.get_setting(KEY_CV) or {}
    text = stored.get("text")
    if not text:
        return "same"
    current = read_cv(settings)
    if current == text:
        return "same"
    if not current or _sha(current) == stored.get("file_sha") or not settings.cv_path.exists():
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        if current:
            _backup(settings, current)
        settings.cv_path.write_text(text, encoding="utf-8")
        log.info("cv_profile.md restored from the UI version (DB)")
        return "db"
    _backup(settings, text, tag="ui")
    db.delete_setting(KEY_CV)
    log.warning("cv_profile.md was changed outside the UI – using the file, UI version saved as backup")
    return "file"


# ---- suggestions ---------------------------------------------------------------------------------
# Role families for CV keywords (only suggested when the keyword is in the CV profile).
KEYWORD_ROLES: dict[str, list[str]] = {
    "Support": ["IT-Support", "Technischer Support", "Systembetreuer"],
    "2nd Level": ["2nd Level Support"], "Second Level": ["Second Level Support"],
    "3rd Level": ["3rd Level Support"],
    "Linux": ["Linux Administrator", "Linux Support"],
    "Nextcloud": ["Nextcloud"],
    "Cloud": ["Cloud Engineer", "Cloud Operations"],
    "Hosting": ["Hosting Support", "Webhosting"],
    "Docker": ["DevOps Engineer"], "Kubernetes": ["DevOps Engineer"],
    "S3": ["Storage Engineer"], "Object Storage": ["Storage Engineer"],
    "SaaS": ["Customer Success Engineer", "Customer Success Manager"],
    "Microsoft 365": ["Microsoft 365 Administrator", "Modern Workplace"],
    "Ticket": ["Service Desk", "IT Support Specialist"],
    "Troubleshooting": ["Technical Support Engineer"],
    "Incident": ["Incident Manager", "IT Operations"],
    "Monitoring": ["IT Operations"],
    "Automatisierung": ["Automatisierung"], "Automation": ["Automation Engineer"],
    "KI": ["KI"], "AI": ["AI Support"], "LLM": ["AI Engineer"], "MCP": ["AI Automation"],
    "API": ["Integration Engineer", "Solutions Engineer"],
    "SQL": ["Application Support"],
    "Jira": ["Application Support"],
    "Server": ["Systemadministrator"],
}
LIKED_STATUSES = ("interessant", "beworben", "gespraech", "angebot")
ROLE_WORDS = ("engineer", "specialist", "spezialist", "support", "manager", "administrator", "consultant",
              "berater", "architect", "analyst", "developer", "entwickler", "operator", "techniker",
              "betreuer", "admin", "lead", "agent")


def clean_title(title: str, company: str = "") -> str:
    t = title or ""
    if company and t.lower().startswith(company.lower()):   # "Firma GmbH: Titel" (Arbeitsagentur)
        t = t[len(company):].lstrip(" :–-")
    t = _GENDER_RE.sub(" ", t)
    t = re.split(r"\s+[-–|/]\s*|\s*[-–|]\s+|\s*\(|\s*,", t)[0]
    t = re.sub(r"\b(Senior|Junior|Sr\.?|Jr\.?|Lead)\b", " ", t, flags=re.I)
    return " ".join(t.split())[:60]


def _norm(s: str) -> str:
    return " ".join(re.sub(r"[^a-z0-9äöüß+#]+", " ", s.lower()).split())


def suggestions(settings: Settings, db: Database, limit: int = 20) -> dict[str, Any]:
    p = settings.profile
    have_q = {_norm(q) for q in p.queries}
    have_t = {_norm(t) for t in p.target_titles}
    excluded = p.excluded_title_keywords + p.excluded_keywords
    out: dict[tuple[str, str], dict[str, Any]] = {}

    def add(value: str, kind: str, reason: str, weight: float) -> None:
        value = " ".join(value.split())
        n = _norm(value)
        if not n or len(value) < 3 or find_keywords(value, excluded):
            return
        if (kind == "query" and n in have_q) or (kind == "title" and n in have_t):
            return
        key = (kind, n)
        if key in out:
            out[key]["weight"] += weight
            if reason not in out[key]["reasons"]:
                out[key]["reasons"].append(reason)
            return
        out[key] = {"value": value, "kind": kind, "reasons": [reason], "weight": weight}

    # 1) jobs the user liked (interessant/beworben/…): their titles
    liked = [j for j in db.list_jobs(limit=5000) if j["status"] in LIKED_STATUSES]
    counts = Counter(clean_title(j["title"], j.get("company") or "") for j in liked)
    for title, n in counts.most_common(30):
        if not title or len(title.split()) > 5 or not any(w in title.lower() for w in ROLE_WORDS):
            continue
        reason = f"{n} Stelle{'n' if n > 1 else ''} als interessant/beworben markiert"
        add(title, "query", reason, 3 + n)
        add(title, "title", reason, 3 + n)

    # 2) target roles in the CV profile ("## Zielrollen")
    cv_text = read_cv(settings)
    m = re.search(r"^##\s*Zielrollen\s*$(.*?)(?=^##\s)", cv_text, flags=re.M | re.S)
    if m:
        for part in re.split(r"[,\n]", re.sub(r"<!--.*?-->", "", m.group(1), flags=re.S)):
            part = part.strip(" .-*")
            if part and len(part.split()) <= 4 and not re.search(r"\d|EUR|Berlin|remote|/", part, re.I):
                add(part, "query", "Zielrolle im CV-Profil", 4)
                add(part, "title", "Zielrolle im CV-Profil", 4)

    # 3) role families of the strongest CV keywords
    cv = CVProfile.parse(cv_text, p.keyword_weights)
    for kw, w in sorted(cv.keywords.items(), key=lambda kv: -kv[1]):
        for role in KEYWORD_ROLES.get(kw, []):
            add(role, "query", f"CV-Keyword „{kw}“ (Gewicht {w:g})", w)

    items = sorted(out.values(), key=lambda s: (-s["weight"], s["kind"], s["value"]))
    queries = [s for s in items if s["kind"] == "query"][:limit]
    titles = [s for s in items if s["kind"] == "title"][:limit]
    for s in queries + titles:
        s["reason"] = "; ".join(s.pop("reasons"))
        s["weight"] = round(s["weight"], 1)
    return {"queries": queries, "titles": titles, "liked_jobs": len(liked), "llm": False}


# ---- preview (no jobs are saved) ------------------------------------------------------------------
PREVIEW_TTL = 600.0
PREVIEW_PAGE = 25
PREVIEW_REMOTE_SCAN = 100   # home office: share of the first 100 nationwide hits
_preview_lock = threading.Lock()
_cache: dict[str, tuple[float, Any]] = {}


class PreviewBusy(RuntimeError):
    pass


def _cached(key: str, fn: Callable[[], Any]) -> tuple[Any, bool]:
    now = time.monotonic()
    hit = _cache.get(key)
    if hit and now - hit[0] < PREVIEW_TTL:
        return hit[1], True
    value = fn()
    _cache[key] = (now, value)
    for k in [k for k, (t, _) in _cache.items() if now - t >= PREVIEW_TTL]:
        _cache.pop(k, None)
    return value, False


def clear_preview_cache() -> None:
    _cache.clear()


def _ba_count(src: Source, params: dict[str, Any], remote_only: bool = False) -> dict[str, Any]:
    from .sources.arbeitsagentur import parse_search_response
    size = PREVIEW_REMOTE_SCAN if remote_only else PREVIEW_PAGE
    data = src._search({**params, "angebotsart": 1, "size": size, "page": 1, "pav": "false"})
    jobs = parse_search_response(data)
    if remote_only:  # home office: nationwide search, keep homeofficemoeglich (see ArbeitsagenturSource)
        jobs = [j for j in jobs if j.remote]
        total = len(jobs)
    else:
        total = int(data.get("maxErgebnisse") or len(jobs))
    return {"total": total, "jobs": [{"title": j.title, "company": j.company, "location": j.location,
                                      "key": dedup_key(j.title, j.company)} for j in jobs[:PREVIEW_PAGE]]}


def _feed_jobs(name: str, src: Source) -> list[dict[str, Any]]:
    got = src.fetch_all()
    jobs = got[0] if isinstance(got, tuple) else got
    return [{"title": j.title, "company": j.company, "location": j.location, "remote": j.remote,
             "geo": j.extra.get("geo", ""), "key": dedup_key(j.title, j.company)} for j in jobs]


def preview(settings: Settings, db: Database, profile: dict[str, Any] | None = None,
            sources: dict[str, Any] | None = None,
            make_source: Callable[[str, dict[str, Any]], Source] | None = None) -> dict[str, Any]:
    """How many postings would the proposed profile find right now? Runs the Arbeitsagentur search
    (page 1 per query, local + Germany-wide home office) and fetches each enabled feed source once;
    nothing is stored. Max. 1 preview at a time (PreviewBusy), results cached for 10 minutes."""
    prof = merge_profile(settings.profile, validate_profile(profile or {}))
    srcs = merge_sources(settings.sources, validate_sources(sources or {}))
    make_source = make_source or (lambda name, opts: REGISTRY[name](opts))
    if not _preview_lock.acquire(blocking=False):
        raise PreviewBusy("Eine Vorschau läuft bereits – bitte kurz warten.")
    try:
        existing_cache: dict[str, bool] = {}

        def is_new(keys: list[str]) -> int:
            unknown = [k for k in keys if k not in existing_cache]
            if unknown:
                have = db.existing_keys(unknown)
                existing_cache.update({k: k in have for k in unknown})
            return sum(1 for k in keys if not existing_cache[k])

        result: dict[str, Any] = {"queries": [], "sources": [], "cached": True,
                                  "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat()}
        ba_opts = srcs.get("arbeitsagentur")
        ba = make_source("arbeitsagentur", ba_opts or {}) if source_enabled("arbeitsagentur", ba_opts) else None
        remote_search = bool((ba_opts or {}).get("remote_search", True)) and prof.remote_ok

        feeds: dict[str, list[dict[str, Any]]] = {}
        for name in SOURCE_INFO:
            if name in ("arbeitsagentur", "adzuna"):
                continue
            opts = srcs.get(name)
            if not source_enabled(name, opts):
                continue
            src = make_source(name, opts or {})
            ok, why = src.is_configured()
            entry: dict[str, Any] = {"id": name, "label": SOURCE_INFO[name]["label"]}
            if not ok:
                result["sources"].append({**entry, "error": why})
                continue
            key = f"feed:{name}:{repr(sorted((opts or {}).items()))}"
            try:
                jobs, hit = _cached(key, lambda: _feed_jobs(name, src))
                result["cached"] &= hit
            except Exception as exc:
                result["sources"].append({**entry, "error": str(exc)[:300]})
                continue
            feeds[name] = jobs
            remote_only = name in ("remotive", "jobicy")
            matching = [j for j in jobs if _feed_keep(j, prof, prof.queries + prof.target_titles, remote_only)]
            result["sources"].append({**entry, "fetched": len(jobs), "matching": len(matching),
                                      "new": is_new([j["key"] for j in matching]),
                                      "samples": [_sample(j) for j in matching[:3]]})

        for q in prof.queries:
            row: dict[str, Any] = {"query": q, "arbeitsagentur": None, "feeds": {}}
            if ba is not None:
                try:
                    local, hit1 = _cached(f"ba:{q}|{prof.location}|{prof.radius_km}|{prof.days_back}",
                                          lambda: _ba_count(ba, {"was": q, "wo": prof.location, "umkreis": prof.radius_km,
                                                                 "veroeffentlichtseit": prof.days_back}))
                    remote = {"total": 0, "jobs": []}
                    hit2 = True
                    if remote_search:
                        remote, hit2 = _cached(f"ba-ho:{q}|{prof.days_back}",
                                               lambda: _ba_count(ba, {"was": q, "veroeffentlichtseit": prof.days_back},
                                                                 remote_only=True))
                    result["cached"] &= hit1 and hit2
                    page = local["jobs"] + [j for j in remote["jobs"] if j["key"] not in {x["key"] for x in local["jobs"]}]
                    row["arbeitsagentur"] = {"local": local["total"], "remote": remote["total"],
                                             "new_in_page": is_new(list(dict.fromkeys(j["key"] for j in page))),
                                             "page_size": PREVIEW_PAGE, "remote_scanned": PREVIEW_REMOTE_SCAN}
                    row["samples"] = [_sample(j) for j in page[:3]]
                except Exception as exc:
                    row["error"] = str(exc)[:300]
            for name, jobs in feeds.items():
                row["feeds"][name] = sum(1 for j in jobs if _feed_keep(j, prof, [q], name in ("remotive", "jobicy")))
            row["total"] = ((row["arbeitsagentur"] or {}).get("local", 0) + (row["arbeitsagentur"] or {}).get("remote", 0)
                            + sum(row["feeds"].values()))
            result["queries"].append(row)
        return result
    finally:
        _preview_lock.release()


def _feed_keep(j: dict[str, Any], prof: SearchProfile, phrases: list[str], remote_only: bool) -> bool:
    if not title_matches(j["title"], phrases):
        return False
    if remote_only:
        return prof.remote_ok and remote_geo_ok(j.get("geo", ""))
    return place_ok(j["location"], j["remote"], prof)


def _sample(j: dict[str, Any]) -> dict[str, str]:
    return {"title": j["title"], "company": j.get("company") or "", "location": j.get("location") or ""}


__all__ = ["ProfileError", "PreviewBusy", "apply_overrides", "payload", "save", "reset", "preview", "suggestions",
           "save_cv", "cv_payload", "sync_cv_on_start", "start_rescore", "rescore_status"]
