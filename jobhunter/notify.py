"""Optional Telegram notification for top new matches (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID)."""
from __future__ import annotations

import html
import logging

import httpx

log = logging.getLogger(__name__)


def format_message(jobs: list[dict], dashboard_url: str | None = None) -> str:
    lines = [f"<b>Job-Hunter: {len(jobs)} neue Top-Treffer</b>"]
    for j in jobs:
        title = html.escape(j["title"])
        company = html.escape(j.get("company") or "?")
        line = f"\n<b>{j['score']}</b> · {title} – {company}"
        if j.get("llm_reason"):
            line += f"\n<i>{html.escape(j['llm_reason'])}</i>"
        if dashboard_url:
            line += f'\n<a href="{html.escape(dashboard_url.rstrip("/"))}/jobs/{j["id"]}">Details</a>'
        lines.append(line)
    return "\n".join(lines)


def send_telegram(token: str, chat_id: str, text: str, client: httpx.Client | None = None) -> bool:
    client = client or httpx.Client(timeout=15)
    try:
        r = client.post(f"https://api.telegram.org/bot{token}/sendMessage",
                        json={"chat_id": chat_id, "text": text, "parse_mode": "HTML",
                              "disable_web_page_preview": True})
        if r.status_code != 200:
            log.warning("Telegram HTTP %s: %s", r.status_code, r.text[:200])
            return False
        return True
    except httpx.HTTPError as exc:
        log.warning("Telegram failed: %s", exc)
        return False
