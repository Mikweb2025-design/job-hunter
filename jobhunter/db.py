"""SQLite storage (plain sqlite3, one file in DATA_DIR)."""
from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from .apply_email import apply_fields
from .dedup import dedup_key, normalize_company
from .models import JobPosting
from .scoring import combined_score

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dedup_key TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL,
    source_id TEXT,
    title TEXT NOT NULL,
    company TEXT,
    location TEXT,
    remote INTEGER DEFAULT 0,
    url TEXT,
    description TEXT,
    salary_min REAL,
    salary_max REAL,
    salary_predicted INTEGER DEFAULT 0,
    published TEXT,
    fetched_at TEXT NOT NULL,
    rule_score INTEGER,
    score_breakdown TEXT,
    llm_score INTEGER,
    llm_reason TEXT,
    letter TEXT,
    letter_origin TEXT,
    letter_updated_at TEXT,
    score INTEGER DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'neu',
    status_updated_at TEXT,
    applied_date TEXT,
    notes TEXT,
    notified INTEGER DEFAULT 0,
    also_seen_on TEXT
);
CREATE INDEX IF NOT EXISTS idx_jobs_score ON jobs(score DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    stats TEXT,
    new_jobs INTEGER DEFAULT 0,
    errors TEXT
);
CREATE TABLE IF NOT EXISTS sent_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id INTEGER NOT NULL,
    company_norm TEXT NOT NULL,
    company TEXT,
    title TEXT,
    to_addr TEXT NOT NULL,
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    sent_at TEXT NOT NULL,
    dry_run INTEGER NOT NULL DEFAULT 1,
    message_id TEXT,
    trigger TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sent_job ON sent_log(job_id);
CREATE INDEX IF NOT EXISTS idx_sent_company ON sent_log(company_norm, sent_at);
CREATE TABLE IF NOT EXISTS client_state (
    client TEXT PRIMARY KEY,
    state TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
"""

# Columns added after the first release: (name, type). Added by ALTER TABLE on startup.
MIGRATIONS = [
    ("apply_email", "TEXT"),
    ("apply_method", "TEXT"),          # email | manual
    ("apply_email_source", "TEXT"),    # phrase | generic | closing | manuell
    ("send_approved_at", "TEXT"),
]


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


class Database:
    def __init__(self, path: Path | str):
        self.path = Path(path)
        if str(path) != ":memory:":
            self.path.parent.mkdir(parents=True, exist_ok=True)
        self._mem = sqlite3.connect(":memory:", check_same_thread=False) if str(path) == ":memory:" else None
        with self.conn() as c:
            c.executescript(SCHEMA)
            have = {r[1] for r in c.execute("PRAGMA table_info(jobs)")}
            added = [(n, t) for n, t in MIGRATIONS if n not in have]
            for name, typ in added:
                c.execute(f"ALTER TABLE jobs ADD COLUMN {name} {typ}")
        if any(n == "apply_email" for n, _ in added):
            self.backfill_apply_email()

    def backfill_apply_email(self, overwrite: bool = False) -> int:
        """Detect application e-mail addresses for stored jobs (keeps manual entries)."""
        n = 0
        with self.conn() as c:
            rows = c.execute("SELECT id, description, apply_email_source FROM jobs").fetchall()
            for r in rows:
                if r["apply_email_source"] == "manuell" and not overwrite:
                    continue
                f = apply_fields(r["description"])
                c.execute("UPDATE jobs SET apply_email=?, apply_method=?, apply_email_source=? WHERE id=?",
                          (f["apply_email"], f["apply_method"], f["apply_email_source"], r["id"]))
                n += 1
        return n

    @contextmanager
    def conn(self) -> Iterator[sqlite3.Connection]:
        if self._mem is not None:
            self._mem.row_factory = sqlite3.Row
            yield self._mem
            self._mem.commit()
            return
        c = sqlite3.connect(self.path, timeout=30)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA journal_mode=WAL")
        try:
            yield c
            c.commit()
        finally:
            c.close()

    # ---- jobs -------------------------------------------------------------
    def existing_keys(self, keys: list[str]) -> set[str]:
        if not keys:
            return set()
        out: set[str] = set()
        with self.conn() as c:
            for i in range(0, len(keys), 500):
                chunk = keys[i : i + 500]
                q = f"SELECT dedup_key FROM jobs WHERE dedup_key IN ({','.join('?' * len(chunk))})"
                out.update(r[0] for r in c.execute(q, chunk))
        return out

    def note_duplicate(self, job: JobPosting) -> None:
        """A posting we already have was seen again (maybe on another source): fill gaps."""
        key = dedup_key(job.title, job.company)
        with self.conn() as c:
            row = c.execute("SELECT id, source, also_seen_on, salary_min, salary_max, description, "
                            "apply_email_source FROM jobs WHERE dedup_key=?", (key,)).fetchone()
            if not row:
                return
            seen = set(filter(None, (row["also_seen_on"] or "").split(",")))
            if job.source != row["source"]:
                seen.add(job.source)
            updates: dict[str, Any] = {"also_seen_on": ",".join(sorted(seen))}
            if row["salary_min"] is None and row["salary_max"] is None and (job.salary_min or job.salary_max):
                updates.update(salary_min=job.salary_min, salary_max=job.salary_max,
                               salary_predicted=int(job.salary_predicted))
            if len(job.description or "") > len(row["description"] or ""):
                updates["description"] = job.description
                if row["apply_email_source"] != "manuell":
                    updates.update(apply_fields(job.description))
            sets = ", ".join(f"{k}=?" for k in updates)
            c.execute(f"UPDATE jobs SET {sets} WHERE id=?", (*updates.values(), row["id"]))

    def insert_job(self, job: JobPosting, rule_score: int, breakdown: dict) -> int | None:
        key = dedup_key(job.title, job.company)
        with self.conn() as c:
            cur = c.execute(
                """INSERT OR IGNORE INTO jobs (dedup_key, source, source_id, title, company, location,
                   remote, url, description, salary_min, salary_max, salary_predicted, published,
                   fetched_at, rule_score, score_breakdown, score, status, status_updated_at, also_seen_on,
                   apply_email, apply_method, apply_email_source)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'neu',?,?,?,?,?)""",
                (key, job.source, job.source_id, job.title, job.company, job.location,
                 int(job.remote), job.url, job.description, job.salary_min, job.salary_max,
                 int(job.salary_predicted), job.published, now_iso(), rule_score,
                 json.dumps(breakdown, ensure_ascii=False), rule_score, now_iso(),
                 ",".join(sorted(job.extra.get("also_seen", ()))) or None,
                 *apply_fields(job.description).values()),
            )
            return cur.lastrowid if cur.rowcount else None

    def get_job(self, job_id: int) -> dict | None:
        with self.conn() as c:
            row = c.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        return _row(row) if row else None

    def list_jobs(self, status: str | None = None, min_score: int | None = None,
                  source: str | None = None, since: str | None = None, q: str | None = None,
                  limit: int = 500) -> list[dict]:
        where, args = [], []
        if status == "aktiv":
            where.append("status NOT IN ('absage')")
        elif status:
            where.append("status=?"); args.append(status)
        if min_score is not None:
            where.append("score>=?"); args.append(min_score)
        if source:
            where.append("(source=? OR ','||IFNULL(also_seen_on,'')||',' LIKE ?)")
            args += [source, f"%,{source},%"]
        if since:
            where.append("fetched_at>=?"); args.append(since)
        if q:
            where.append("(title LIKE ? OR company LIKE ? OR description LIKE ?)")
            args += [f"%{q}%"] * 3
        sql = "SELECT * FROM jobs"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY score DESC, fetched_at DESC LIMIT ?"
        args.append(limit)
        with self.conn() as c:
            return [_row(r) for r in c.execute(sql, args)]

    def update_job(self, job_id: int, **fields: Any) -> None:
        if not fields:
            return
        sets = ", ".join(f"{k}=?" for k in fields)
        with self.conn() as c:
            c.execute(f"UPDATE jobs SET {sets} WHERE id=?", (*fields.values(), job_id))

    def set_llm_result(self, job_id: int, llm_score: int | None, reason: str | None,
                       letter: str | None, origin: str) -> None:
        job = self.get_job(job_id)
        if not job:
            return
        fields: dict[str, Any] = {}
        if llm_score is not None:
            fields.update(llm_score=llm_score, llm_reason=reason,
                          score=combined_score(job["rule_score"], llm_score))
        elif reason:
            fields["llm_reason"] = reason
        if letter:
            fields.update(letter=letter, letter_origin=origin, letter_updated_at=now_iso())
        self.update_job(job_id, **fields)

    def set_rule_score(self, job_id: int, rule_score: int, breakdown: dict) -> None:
        job = self.get_job(job_id)
        if not job:
            return
        self.update_job(job_id, rule_score=rule_score,
                        score_breakdown=json.dumps(breakdown, ensure_ascii=False),
                        score=combined_score(rule_score, job["llm_score"]))

    def sources(self) -> list[str]:
        with self.conn() as c:
            return [r[0] for r in c.execute("SELECT DISTINCT source FROM jobs ORDER BY source")]

    def counts_by_status(self) -> dict[str, int]:
        with self.conn() as c:
            return {r[0]: r[1] for r in c.execute("SELECT status, COUNT(*) FROM jobs GROUP BY status")}

    def unnotified(self, min_score: int, limit: int) -> list[dict]:
        with self.conn() as c:
            rows = c.execute("SELECT * FROM jobs WHERE notified=0 AND score>=? AND status='neu' "
                             "ORDER BY score DESC LIMIT ?", (min_score, limit)).fetchall()
        return [_row(r) for r in rows]

    def mark_notified(self, ids: list[int]) -> None:
        with self.conn() as c:
            c.executemany("UPDATE jobs SET notified=1 WHERE id=?", [(i,) for i in ids])

    # ---- sent log -----------------------------------------------------------
    def add_sent(self, job: dict, to_addr: str, subject: str, body: str, sent_at: str,
                 dry_run: bool, message_id: str | None, trigger: str | None) -> int:
        with self.conn() as c:
            return c.execute(
                """INSERT INTO sent_log (job_id, company_norm, company, title, to_addr, subject, body,
                   sent_at, dry_run, message_id, trigger, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
                (job["id"], normalize_company(job.get("company") or ""), job.get("company"), job.get("title"),
                 to_addr, subject, body, sent_at, int(dry_run), message_id, trigger, now_iso()),
            ).lastrowid

    def sent_log(self, job_id: int | None = None, limit: int = 500, include_dry_run: bool = True) -> list[dict]:
        where, args = [], []
        if job_id is not None:
            where.append("job_id=?"); args.append(job_id)
        if not include_dry_run:
            where.append("dry_run=0")
        sql = "SELECT * FROM sent_log" + (" WHERE " + " AND ".join(where) if where else "")
        sql += " ORDER BY sent_at DESC, id DESC LIMIT ?"
        args.append(limit)
        with self.conn() as c:
            rows = [dict(r) for r in c.execute(sql, args)]
        for r in rows:
            r["dry_run"] = bool(r["dry_run"])
        return rows

    def set_sent_message_id(self, sent_id: int, message_id: str) -> None:
        with self.conn() as c:
            c.execute("UPDATE sent_log SET message_id=? WHERE id=?", (message_id, sent_id))

    def get_sent(self, sent_id: int) -> dict | None:
        with self.conn() as c:
            r = c.execute("SELECT * FROM sent_log WHERE id=?", (sent_id,)).fetchone()
        if not r:
            return None
        d = dict(r)
        d["dry_run"] = bool(d["dry_run"])
        return d

    # ---- client heartbeat (e.g. the macOS app's "Automatisch senden" toggle) ----
    def set_client_state(self, client: str, state: dict) -> None:
        with self.conn() as c:
            c.execute("INSERT INTO client_state (client, state, updated_at) VALUES (?,?,?) "
                      "ON CONFLICT(client) DO UPDATE SET state=excluded.state, updated_at=excluded.updated_at",
                      (client, json.dumps(state, ensure_ascii=False), now_iso()))

    def client_states(self) -> list[dict]:
        with self.conn() as c:
            rows = c.execute("SELECT * FROM client_state ORDER BY updated_at DESC").fetchall()
        return [{"client": r["client"], "updated_at": r["updated_at"], **json.loads(r["state"])} for r in rows]

    # ---- runs -------------------------------------------------------------
    def start_run(self) -> int:
        with self.conn() as c:
            return c.execute("INSERT INTO runs (started_at) VALUES (?)", (now_iso(),)).lastrowid

    def finish_run(self, run_id: int, stats: dict, new_jobs: int, errors: list[str]) -> None:
        with self.conn() as c:
            c.execute("UPDATE runs SET finished_at=?, stats=?, new_jobs=?, errors=? WHERE id=?",
                      (now_iso(), json.dumps(stats, ensure_ascii=False), new_jobs,
                       json.dumps(errors, ensure_ascii=False), run_id))

    def last_runs(self, n: int = 5) -> list[dict]:
        with self.conn() as c:
            rows = c.execute("SELECT * FROM runs ORDER BY id DESC LIMIT ?", (n,)).fetchall()
        out = []
        for r in rows:
            d = dict(r)
            d["stats"] = json.loads(d["stats"]) if d["stats"] else {}
            d["errors"] = json.loads(d["errors"]) if d["errors"] else []
            out.append(d)
        return out


def _row(row: sqlite3.Row) -> dict:
    d = dict(row)
    try:
        d["score_breakdown"] = json.loads(d.get("score_breakdown") or "{}")
    except json.JSONDecodeError:
        d["score_breakdown"] = {}
    return d
