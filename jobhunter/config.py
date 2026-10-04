"""Configuration: config.yaml (search profile) + environment variables (secrets)."""
from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


def _env(name: str, default: str | None = None) -> str | None:
    val = os.environ.get(name)
    return val if val not in (None, "") else default


def _bool(env_value: str | None, default) -> bool:
    if env_value is None:
        return bool(default)
    return env_value.strip().lower() in ("1", "true", "yes", "on")


@dataclass
class SearchProfile:
    queries: list[str] = field(default_factory=lambda: ["Support Engineer"])
    location: str = "Berlin"
    radius_km: int = 30
    remote_ok: bool = True
    days_back: int = 7
    min_salary: int = 44000
    target_titles: list[str] = field(default_factory=list)
    excluded_keywords: list[str] = field(default_factory=list)
    excluded_title_keywords: list[str] = field(default_factory=list)
    keyword_weights: dict[str, float] = field(default_factory=dict)
    keyword_saturation: float = 15.0
    extra_locations: list[str] = field(default_factory=list)


@dataclass
class LLMConfig:
    provider: str = "none"  # none | anthropic | openai | opencode
    model: str = ""
    base_url: str = ""
    api_key: str = ""
    threshold: int = 55
    max_per_run: int = 10   # keep small: generations run one at a time
    timeout_s: float = 120.0
    anthropic_fallbacks: bool = True
    effort: str | None = None
    opencode_bin: str = ""  # provider=opencode: path of the opencode CLI (OPENCODE_BIN)
    retries: int = 1        # extra attempts per letter after a timeout / rejected output
    fallback_model: str = ""  # optional: model for the last attempt (e.g. another opencode model)

    @property
    def enabled(self) -> bool:
        if self.provider == "anthropic":
            return bool(self.api_key)
        if self.provider == "openai":
            return bool(self.base_url and self.model)
        if self.provider == "opencode":
            return bool(self.opencode_bin and os.path.isfile(self.opencode_bin)
                        and os.access(self.opencode_bin, os.X_OK) and self.model)
        return False


DEFAULT_OPENCODE_MODEL = "opencode/big-pickle"  # free opencode model, runs remotely (no local CPU load)


def resolve_opencode_bin(configured: str | None) -> str:
    """OPENCODE_BIN / llm.opencode_bin, else `opencode` on PATH, else ~/.opencode/bin/opencode."""
    if configured:
        return os.path.expanduser(configured)
    found = shutil.which("opencode")
    if found:
        return found
    return os.path.expanduser("~/.opencode/bin/opencode")


DEFAULT_BLOCKLIST = ["IONOS", "STRATO", "1&1", "United Internet", "IONOS SE", "STRATO AG"]
DEFAULT_BODY_TEMPLATE = """Sehr geehrte Damen und Herren,

{letter}

Meinen Lebenslauf finden Sie im Anhang.

Mit freundlichen Grüßen
{sender_name}
{from_address}"""


@dataclass
class SendConfig:
    """E-mail applications (`send:` in config.yaml). The server only decides and logs;
    the macOS app does the actual sending through Apple Mail."""
    mode: str = "approve"            # off | approve | auto
    dry_run: bool = True             # True: nothing is ever sent, only previewed/logged as test
    auto_min_score: int = 80
    daily_cap: int = 5
    company_cooldown_days: int = 90
    blocklist: list[str] = field(default_factory=lambda: list(DEFAULT_BLOCKLIST))
    require_letter: bool = True
    kill_switch: bool = False
    from_address: str = "info@daniele-michelin.com"
    sender_name: str = "Daniele Michelin"
    subject_template: str = "Bewerbung als {title}"
    body_template: str = DEFAULT_BODY_TEMPLATE
    cv_attachment: str = "~/Bewerbung/Lebenslauf_Daniele_Michelin.pdf"

    def __post_init__(self) -> None:
        if self.mode not in ("off", "approve", "auto"):
            raise ValueError(f"send.mode muss off|approve|auto sein, nicht {self.mode!r}")


@dataclass
class ApplicantConfig:
    """Sender block of the cover-letter document (`applicant:` in config.yaml). Public contact
    data only – no secrets."""
    name: str = "Daniele Michelin"
    street: str = ""                 # optional; empty = not printed
    city: str = "Berlin"             # also used for "Berlin, <Datum>"
    email: str = "info@daniele-michelin.com"
    phone: str = "+49 160 7804710"
    linkedin: str = "linkedin.com/in/daniele-michelin-02863143b"
    enclosures: list[str] = field(default_factory=lambda: ["Lebenslauf"])


@dataclass
class Settings:
    profile: SearchProfile
    llm: LLMConfig
    sources: dict[str, Any]
    data_dir: Path
    cron: str = "30 6 * * *"
    timezone: str = "Europe/Berlin"
    run_on_start: bool = False
    notify_min_score: int = 70
    notify_max_items: int = 5
    max_details_per_run: int = 60
    dashboard_user: str | None = None
    dashboard_password: str | None = None
    telegram_token: str | None = None
    telegram_chat_id: str | None = None
    ui_lang: str = "de"
    send: SendConfig = field(default_factory=SendConfig)
    applicant: ApplicantConfig = field(default_factory=ApplicantConfig)
    # config.yaml values before the UI overrides (DB table `settings`) were applied;
    # set by search_profile.apply_overrides (None = no overrides applied yet).
    profile_base: SearchProfile | None = None
    sources_base: dict[str, Any] | None = None

    @property
    def db_path(self) -> Path:
        return self.data_dir / "jobhunter.db"

    @property
    def cv_path(self) -> Path:
        return self.data_dir / "cv_profile.md"


def load_settings(config_path: str | Path | None = None) -> Settings:
    config_path = Path(config_path or _env("CONFIG_PATH", "config.yaml"))
    raw: dict[str, Any] = {}
    if config_path.exists():
        raw = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}

    s = raw.get("search", {}) or {}
    profile = SearchProfile(
        queries=list(s.get("queries", SearchProfile().queries)),
        location=s.get("location", "Berlin"),
        radius_km=int(s.get("radius_km", 30)),
        remote_ok=bool(s.get("remote_ok", True)),
        days_back=int(s.get("days_back", 7)),
        min_salary=int(s.get("min_salary", 44000)),
        target_titles=list(s.get("target_titles", [])),
        excluded_keywords=list(s.get("excluded_keywords", [])),
        excluded_title_keywords=list(s.get("excluded_title_keywords", [])),
        keyword_weights={str(k): float(v) for k, v in (s.get("keyword_weights") or {}).items()},
        keyword_saturation=float(s.get("keyword_saturation", 15)),
        extra_locations=list(s.get("extra_locations", [])),
    )

    l = raw.get("llm", {}) or {}
    provider = (_env("LLM_PROVIDER") or l.get("provider") or "none").lower()
    if provider == "anthropic":
        cfg_model = str(l.get("model") or "")
        model = _env("LLM_MODEL") or (cfg_model if cfg_model.startswith("claude") else "claude-sonnet-5-5")
        api_key = _env("ANTHROPIC_API_KEY", "") or ""
        base_url = ""
    elif provider == "openai":
        model = _env("LLM_MODEL") or l.get("model") or ""
        api_key = _env("OPENAI_API_KEY", "") or ""
        base_url = _env("OPENAI_BASE_URL") or l.get("base_url") or ""
    elif provider == "opencode":
        # opencode model ids are always "<provider>/<model>"; a non-matching llm.model (e.g. a
        # leftover claude-* name) is ignored in favour of the free default.
        cfg_model = str(l.get("model") or "")
        model = _env("LLM_MODEL") or (cfg_model if "/" in cfg_model else DEFAULT_OPENCODE_MODEL)
        api_key, base_url = "", ""
    else:
        provider, model, api_key, base_url = "none", "", "", ""
    llm = LLMConfig(
        provider=provider,
        model=model,
        base_url=base_url,
        api_key=api_key,
        threshold=int(l.get("threshold", 55)),
        max_per_run=int(l.get("max_per_run", 20 if provider == "opencode" else 10)),
        timeout_s=float(_env("LLM_TIMEOUT_S") or l.get("timeout_s", 180 if provider == "opencode" else 120)),
        anthropic_fallbacks=bool(l.get("anthropic_fallbacks", True)),
        effort=l.get("effort"),
        retries=int(_env("LLM_RETRIES") or l.get("retries", 1)),
        fallback_model=str(_env("LLM_FALLBACK_MODEL") or l.get("fallback_model", "") or ""),
        opencode_bin=resolve_opencode_bin(_env("OPENCODE_BIN") or l.get("opencode_bin"))
        if provider == "opencode" else "",
    )

    sd = raw.get("send", {}) or {}
    defaults = SendConfig()
    send = SendConfig(
        mode=str(_env("SEND_MODE") or sd.get("mode", defaults.mode)).lower(),
        dry_run=_bool(_env("SEND_DRY_RUN"), sd.get("dry_run", defaults.dry_run)),
        auto_min_score=int(sd.get("auto_min_score", defaults.auto_min_score)),
        daily_cap=int(sd.get("daily_cap", defaults.daily_cap)),
        company_cooldown_days=int(sd.get("company_cooldown_days", defaults.company_cooldown_days)),
        blocklist=[str(b) for b in (sd.get("blocklist") if sd.get("blocklist") is not None else defaults.blocklist)],
        require_letter=bool(sd.get("require_letter", defaults.require_letter)),
        kill_switch=_bool(_env("SEND_KILL_SWITCH"), sd.get("kill_switch", defaults.kill_switch)),
        from_address=str(sd.get("from_address", defaults.from_address)),
        sender_name=str(sd.get("sender_name", defaults.sender_name)),
        subject_template=str(sd.get("subject_template", defaults.subject_template)),
        body_template=str(sd.get("body_template", defaults.body_template)),
        cv_attachment=str(sd.get("cv_attachment", defaults.cv_attachment)),
    )

    ad = raw.get("applicant", {}) or {}
    a_def = ApplicantConfig()
    applicant = ApplicantConfig(
        name=str(ad.get("name") or a_def.name), street=str(ad.get("street") or ""),
        city=str(ad.get("city") or a_def.city), email=str(ad.get("email") or a_def.email),
        phone=str(ad.get("phone") or a_def.phone), linkedin=str(ad.get("linkedin") or a_def.linkedin),
        enclosures=[str(e) for e in (ad.get("enclosures") if ad.get("enclosures") is not None else a_def.enclosures)],
    )

    sched = raw.get("schedule", {}) or {}
    notify = raw.get("notify", {}) or {}
    return Settings(
        profile=profile,
        llm=llm,
        sources=raw.get("sources", {}) or {},
        data_dir=Path(_env("DATA_DIR", raw.get("data_dir", "data"))),
        cron=_env("RUN_CRON") or sched.get("cron", "30 6 * * *"),
        timezone=_env("TZ") or sched.get("timezone", "Europe/Berlin"),
        run_on_start=bool(sched.get("run_on_start", False)),
        notify_min_score=int(notify.get("min_score", 70)),
        notify_max_items=int(notify.get("max_items", 5)),
        max_details_per_run=int(raw.get("max_details_per_run", 60)),
        dashboard_user=_env("DASHBOARD_USER"),
        dashboard_password=_env("DASHBOARD_PASSWORD"),
        telegram_token=_env("TELEGRAM_BOT_TOKEN"),
        telegram_chat_id=_env("TELEGRAM_CHAT_ID"),
        ui_lang=(_env("UI_LANG") or raw.get("ui_lang") or "de"),
        send=send,
        applicant=applicant,
    )
