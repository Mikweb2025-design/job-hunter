"""Source registry. Add a new source by subclassing Source and registering it here."""
from __future__ import annotations

from typing import Any

from .adzuna import AdzunaSource
from .arbeitsagentur import ArbeitsagenturSource
from .base import Source, SourceError
from .rss import RSSSource

REGISTRY: dict[str, type[Source]] = {
    "arbeitsagentur": ArbeitsagenturSource,
    "adzuna": AdzunaSource,
    "rss": RSSSource,
}


def build_sources(config: dict[str, Any]) -> list[Source]:
    """Instantiate every source enabled in config.yaml (default: arbeitsagentur on, others on if listed)."""
    out: list[Source] = []
    for name, cls in REGISTRY.items():
        opts = config.get(name)
        if opts is None:
            opts = {"enabled": name == "arbeitsagentur"}
        if not opts.get("enabled", True):
            continue
        out.append(cls(opts))
    return out


__all__ = ["Source", "SourceError", "REGISTRY", "build_sources"]
