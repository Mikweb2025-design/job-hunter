"""CLI: python -m jobhunter {run,serve,rescore,letters}"""
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
    p_let = sub.add_parser("letters", help="KI-Anschreiben für Stellen ohne echtes Anschreiben (Vorlage/leer) schreiben")
    p_let.add_argument("--all", action="store_true", help="alle offenen Stellen ohne Obergrenze (sonst llm.max_per_run)")
    p_let.add_argument("--limit", type=int, default=None, help="höchstens N Stellen")
    p_let.add_argument("--dry-run", action="store_true", help="nur zählen, nichts ändern")
    p_let.add_argument("--ids", default="", help="nur diese Stellen (z.B. 18 oder 18,22) – nur wenn sie noch kein echtes Anschreiben haben")
    p_let.add_argument("--fix-templates-only", action="store_true",
                       help="nur alte Vorlagen mit [ … ] durch die neue Vorlage ersetzen, keine KI")
    args = parser.parse_args(argv)

    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    settings = load_settings(args.config)
    from .db import Database
    from .search_profile import apply_overrides, sync_cv_on_start
    _db = Database(settings.db_path)
    sync_cv_on_start(settings, _db)
    apply_overrides(settings, _db)   # Suchprofil/Quellen aus der UI (DB) über config.yaml

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
    if args.cmd == "letters":
        return _letters(settings, args)
    if args.cmd == "serve":
        import uvicorn
        from .web import create_app
        app = create_app(settings, start_scheduler=not args.no_scheduler)
        uvicorn.run(app, host=args.host, port=args.port, proxy_headers=True, forwarded_allow_ips="*")
        return 0
    return 2


def _letters(settings, args) -> int:
    import time

    from . import letters
    from .db import Database
    db = Database(settings.db_path)
    fixed = letters.fix_old_templates(settings, db, dry_run=args.dry_run)
    verb = "würden ersetzt" if args.dry_run else "ersetzt"
    print(f"Alte Vorlagen mit [ … ]: {len(fixed)} {verb}" + (f" (IDs {', '.join(map(str, fixed))})" if fixed else ""))
    if args.fix_templates_only:
        return 0
    todo = letters.candidates(settings, db, limit=args.limit, capped=not args.all)
    if args.ids:
        wanted = {int(x) for x in args.ids.replace(" ", "").split(",") if x}
        todo = [j for j in letters.candidates(settings, db, capped=False) if j["id"] in wanted]
    if args.all and args.limit:
        todo = todo[:args.limit]
    print(f"Stellen für KI-Anschreiben: {len(todo)}" + ("" if args.all else f" (max. {settings.llm.max_per_run} pro Lauf)"))
    if args.dry_run or not todo:
        for j in todo:
            print(f"  #{j['id']} [{j.get('score')}] {j.get('title')} – {j.get('company') or '–'} ({j.get('letter_origin') or 'leer'})")
        return 0
    if not settings.llm.enabled:
        print("Keine KI konfiguriert (llm.provider / OPENCODE_BIN) – nichts geschrieben.")
        return 1
    t0 = [time.monotonic()]

    def progress(job, error):
        dt = time.monotonic() - t0[0]
        t0[0] = time.monotonic()
        print(f"  #{job['id']} {job.get('title')}: " + (f"FEHLER {error}" if error else f"ok ({dt:.0f} s)"), flush=True)

    result = letters.run_sync(settings, db, todo, progress)
    if result is None:
        print("Ein anderer Anschreiben-Lauf ist aktiv.")
        return 1
    print(f"Fertig: {result['done']} geschrieben, {result['failed']} fehlgeschlagen")
    return 0 if not result["failed"] else 1


if __name__ == "__main__":
    sys.exit(main())
