"""Source registry. Add a new source by subclassing Source and registering it here."""
from __future__ import annotations

from typing import Any

from .adzuna import AdzunaSource
from .arbeitnow import ArbeitnowSource
from .arbeitsagentur import ArbeitsagenturSource
from .ats import ATSSource
from .base import Source, SourceError
from .berlinstartupjobs import BerlinStartupJobsSource
from .jobicy import JobicySource
from .remotive import RemotiveSource
from .rss import RSSSource

REGISTRY: dict[str, type[Source]] = {
    "arbeitsagentur": ArbeitsagenturSource,
    "adzuna": AdzunaSource,
    "rss": RSSSource,
    "arbeitnow": ArbeitnowSource,
    "remotive": RemotiveSource,
    "jobicy": JobicySource,
    "berlinstartupjobs": BerlinStartupJobsSource,
    "ats": ATSSource,
}
# Sources that are off unless enabled in config.yaml or in the "Suchprofil" UI.
OPT_IN = {"arbeitnow", "remotive", "jobicy", "berlinstartupjobs", "ats"}


def build_sources(config: dict[str, Any]) -> list[Source]:
    """Instantiate every source enabled in config.yaml (default: arbeitsagentur on, others on if listed)."""
    out: list[Source] = []
    for name, cls in REGISTRY.items():
        opts = config.get(name)
        if opts is None:
            opts = {"enabled": name == "arbeitsagentur"}
        elif name in OPT_IN and "enabled" not in opts:
            opts = {**opts, "enabled": False}
        if not opts.get("enabled", True):
            continue
        out.append(cls(opts))
    return out


__all__ = ["Source", "SourceError", "REGISTRY", "OPT_IN", "build_sources"]
