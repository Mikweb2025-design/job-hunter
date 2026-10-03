"""CLI: python -m jobhunter {run,serve,rescore}"""
from __future__ import annotations

import argparse
import logging
import os
import sys

from .config import load_settings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="jobhunter", description="Self-hosted job-search assistant")
    parser.add_argument("--config", default=None, help="Pfad zu config.yaml (default: $CONFIG_PATH oder ./config.yaml)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_run = sub.add_parser("run", help="Einen Such- und Bewertungslauf ausführen")
    p_run.add_argument("--no-notify", action="store_true", help="Keine Telegram-Nachricht senden")
    p_serve = sub.add_parser("serve", help="Dashboard + täglichen Scheduler starten")
    p_serve.add_argument("--host", default=os.environ.get("HOST", "0.0.0.0"))
    p_serve.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8000")))
    p_serve.add_argument("--no-scheduler", action="store_true", help="Nur Dashboard, kein Zeitplan")
    sub.add_parser("rescore", help="Regel-Scores nach Änderung von config.yaml/cv_profile.md neu berechnen")
    args = parser.parse_args(argv)

    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    settings = load_settings(args.config)

    if args.cmd == "run":
        from .pipeline import run_cycle
        rep = run_cycle(settings, notify=not args.no_notify)
        print(rep.summary())
        for e in rep.errors:
            print("  !", e)
        # Exit non-zero only if every source failed
        return 1 if rep.errors and not any(rep.fetched.values()) else 0
    if args.cmd == "rescore":
        from .pipeline import rescore_all
        print(f"{rescore_all(settings)} Stellen neu bewertet")
        return 0
    if args.cmd == "serve":
        import uvicorn
        from .web import create_app
        app = create_app(settings, start_scheduler=not args.no_scheduler)
        uvicorn.run(app, host=args.host, port=args.port, proxy_headers=True, forwarded_allow_ips="*")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
