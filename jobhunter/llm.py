"""Optional LLM rerank + German cover-letter draft.

Providers:
  anthropic – official Anthropic SDK (default model claude-sonnet-5-5, ANTHROPIC_API_KEY)
  openai    – any OpenAI-compatible /chat/completions endpoint (IONOS AI Model Hub, Ollama, ...).
              With Ollama on a CPU-only server use small models only (e.g. llama3.2:3b).
  opencode  – the opencode CLI (`opencode run -m <model> --format json "<prompt>"`), default model
              opencode/big-pickle (free, runs remotely: no local model, little CPU). Letters only,
              no score. Same prompt and output checks as the macOS app (LetterWriter.swift).
Without a configured provider, `template_letter` produces a deterministic draft instead.

All generations are serialized by one process-wide lock: never two LLM calls at the same time
(the server is small and CPU-only).
"""
from __future__ import annotations

import json
import logging
import os
import re
import signal
import subprocess
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path

import httpx

from .config import LLMConfig
from .scoring import CVProfile, find_keywords

log = logging.getLogger(__name__)

MAX_POSTING_CHARS = 15000  # postings are rarely longer; keeps cost predictable

SYSTEM_PROMPT = """Du hilfst einem erfahrenen Support Engineer bei der Jobsuche in Deutschland.
Du bewertest eine Stellenanzeige gegen sein Profil und schreibst einen kurzen Anschreiben-Entwurf.

Regeln für das Anschreiben (Deutsch, genau 4 Sätze, kein Gruß, keine Anrede). Schreibe in der ICH-FORM aus Sicht des Bewerbers (ich, mein, mir); das Unternehmen wird höflich mit „Sie“ angesprochen. Sprich NIE den Bewerber selbst mit „Sie“ oder „Ihre“ an:
1. Satz: das relevanteste konkrete Ergebnis aus dem Profil, passend zur Stelle.
2. Satz: warum genau dieses Unternehmen/diese Stelle – mit einem konkreten Bezug aus dem Anzeigentext.
3. Satz: was ich in den ersten 90 Tagen konkret tun würde.
4. Satz: eine schlichte Bitte um ein Gespräch.
Keine Buzzwords (z.B. "leidenschaftlich", "dynamisch", "Synergien", "Mehrwert schaffen").
Erfinde NIEMALS Zahlen, Firmen, Zertifikate oder Ergebnisse. Verwende Zahlen nur, wenn sie wörtlich im Profil stehen.

Bewertung: score 0-100 = wie gut passt die Stelle zu Profil, Seniorität und Wünschen
(Berlin oder remote, Mindestgehalt). reason = ein einziger deutscher Satz mit dem wichtigsten Grund.

Antworte ausschließlich mit JSON: {"score": <int>, "reason": "<ein Satz>", "letter": "<4 Sätze>"}"""


OPENCODE_ORIGIN = "KI (opencode)"
MIN_LETTER_CHARS = 200

LETTER_RULES = """Du hilfst einem erfahrenen Support Engineer bei der Jobsuche in Deutschland und schreibst einen kurzen Anschreiben-Entwurf für die Stellenanzeige unten.

Regeln für das Anschreiben (Deutsch, genau 4 Sätze, kein Gruß, keine Anrede). Schreibe in der ICH-FORM aus Sicht des Bewerbers (ich, mein, mir); das Unternehmen wird höflich mit „Sie“ angesprochen. Sprich NIE den Bewerber selbst mit „Sie“ oder „Ihre“ an:
1. Satz: das relevanteste konkrete Ergebnis aus dem Profil, passend zur Stelle.
2. Satz: warum genau dieses Unternehmen/diese Stelle – mit einem konkreten Bezug aus dem Anzeigentext.
3. Satz: was ich in den ersten 90 Tagen konkret tun würde.
4. Satz: eine schlichte Bitte um ein Gespräch.
Keine Buzzwords (z.B. "leidenschaftlich", "dynamisch", "Synergien", "Mehrwert schaffen").
Erfinde NIEMALS Zahlen, Firmen, Zertifikate oder Ergebnisse. Verwende Zahlen nur, wenn sie wörtlich im Profil stehen.
Keine Platzhalter in eckigen Klammern. Benutze keine Werkzeuge und lies keine Dateien – alles Nötige steht unten.

Gib ausschließlich den Text des Anschreibens aus: genau 4 Sätze als ein Absatz, ohne Überschrift, ohne Anführungszeichen, ohne Erklärung davor oder danach."""

# One generation at a time, process-wide (pipeline, dashboard button, API, batch).
_GENERATION_LOCK = threading.Lock()


def generation_busy() -> bool:
    return _GENERATION_LOCK.locked()


class LLMError(RuntimeError):
    pass


class LetterRejected(LLMError):
    """The model answered, but the text is not a usable letter."""


@dataclass
class LLMResult:
    score: int | None
    reason: str
    letter: str
    origin: str


def build_user_prompt(cv_text: str, job: dict, min_salary: int) -> str:
    desc = (job.get("description") or "")[:MAX_POSTING_CHARS]
    salary = "unbekannt"
    if job.get("salary_min") or job.get("salary_max"):
        salary = f"{job.get('salary_min') or '?'} – {job.get('salary_max') or '?'} EUR/Jahr"
    return (
        f"<profil>\n{cv_text.strip()}\n</profil>\n\n"
        f"<wuensche>Mindestgehalt {min_salary} EUR/Jahr; Berlin oder remote.</wuensche>\n\n"
        f"<stelle>\nTitel: {job.get('title')}\nUnternehmen: {job.get('company') or 'unbekannt'}\n"
        f"Ort: {job.get('location') or 'unbekannt'}\nRemote möglich: {'ja' if job.get('remote') else 'unbekannt'}\n"
        f"Gehalt: {salary}\n\n{desc}\n</stelle>"
    )


def clean_profile(markdown: str) -> str:
    """Removes HTML comments (editor hints in cv_profile.md)."""
    text = re.sub(r"<!--[\s\S]*?-->", "", markdown or "")
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def build_letter_prompt(cv_text: str, job: dict, min_salary: int) -> str:
    """Letter-only prompt (opencode): rules + profile + posting, as in the macOS app."""
    return LETTER_RULES + "\n\n" + build_user_prompt(clean_profile(cv_text), job, min_salary)


# ---- opencode output cleaning ------------------------------------------------
_ANSI_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]")
_CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_NOISE_LINE_RE = re.compile(
    r"^\s*(> \S+ · .*|[│┃|]\s.*|[⚙✓✔✗•▶■□◆◇⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏].*|```.*|#+\s.*"
    r"|(Anschreiben|Entwurf|Hier (ist|sind)|Gerne|Here is)[^.!?]*:\s*)$", re.IGNORECASE)
_SALUTATION_LINE_RE = re.compile(r"^\s*(sehr geehrte|liebe[rs]?\b|hallo\b|guten tag|dear\b)[^\n]*$", re.IGNORECASE)
_CLOSING_LINE_RE = re.compile(
    r"^\s*(mit )?(freundlichen|besten|herzlichen|viele) grü(ß|ss)en?.*$|^\s*(kind|best) regards.*$", re.IGNORECASE)
_NUMBER_RE = re.compile(r"\d{1,3}(?:[.\u00a0 ]\d{3})+|\d+")
_QUOTES = [('"', '"'), ("„", "“"), ("«", "»"), ("“", "”"), ("'", "'")]


# Some models (seen with opencode/big-pickle) drop the space before numbers: "Seit2018", "rund200".
_GLUED_WORD_NUM_RE = re.compile(
    r"\b(seit|rund|ca\.|circa|etwa|über|ueber|mehr als|bis|von|für|mit|um|ab|nach|als|auf|in|im|zu|zum|"
    r"insgesamt|jährlich|täglich|pro)(?=\d)", re.IGNORECASE)
_GLUED_NUM_WORD_RE = re.compile(r"(?<=\d)(?=[A-Za-zÄÖÜäöüß]{4,})")


def fix_glued_numbers(text: str) -> str:
    return _GLUED_NUM_WORD_RE.sub(" ", _GLUED_WORD_NUM_RE.sub(r"\1 ", text))


def strip_ansi(text: str) -> str:
    return _CTRL_RE.sub("", _ANSI_RE.sub("", text or ""))


def text_from_json_events(raw: str) -> str | None:
    """`opencode run --format json` prints one JSON event per line; the answer is in the `text`
    parts (the last non-empty one). Returns None if the output is not in that format."""
    texts: list[str] = []
    saw_event = False
    for line in (raw or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict) or not isinstance(obj.get("type"), str):
            continue
        saw_event = True
        part = obj.get("part")
        if obj["type"] == "text" and isinstance(part, dict) and isinstance(part.get("text"), str):
            texts.append(part["text"])
    if not saw_event:
        return None
    return next((t for t in reversed(texts) if t.strip()), "")


def _numbers(text: str) -> list[str]:
    return ["".join(ch for ch in m.group(0) if ch.isdigit()) for m in _NUMBER_RE.finditer(text or "")]


def invented_numbers(letter: str, sources: list[str]) -> list[str]:
    """Numbers in the letter that occur in none of the sources ("90" – the 90 days – is allowed)."""
    known = {n for s in sources for n in _numbers(s)} | {"90"}
    out: list[str] = []
    for n in _numbers(letter):
        if n not in known and n not in out:
            out.append(n)
    return out


_ICH_RE = re.compile(r"\b(ich|mein|meine|meinen|meiner|meinem|mir|mich)\b", re.IGNORECASE)
_WRONG_SIE_RE = re.compile(r"\b(haben Sie bereits|Ihre bisherige|Ihrer bisherigen|Ihre Erfahrung|würden Sie sich|Ihre Eignung|Sie haben .{0,40}(aufgebaut|gezeigt|gearbeitet))", re.IGNORECASE)


def wrong_perspective_ok(letter: str) -> bool:
    """True if the letter is written in first person (ich/mein) and does not address the applicant as „Sie“."""
    return bool(_ICH_RE.search(letter)) and not _WRONG_SIE_RE.search(letter)


def clean_letter_output(raw: str, sources: list[str] | None = None) -> str:
    """Extracts the letter from raw CLI output (JSON events or plain text) and validates it.

    Raises LetterRejected for empty / too short (< MIN_LETTER_CHARS) output, "[" placeholders
    or numbers that appear neither in the profile nor in the posting.
    """
    text = text_from_json_events(raw)
    if text is None:
        text = raw or ""
    lines = [ln for ln in strip_ansi(text).splitlines() if not _NOISE_LINE_RE.match(ln)]
    while True:  # drop salutation lines at the start
        first = next((i for i, ln in enumerate(lines) if ln.strip()), None)
        if first is None or not _SALUTATION_LINE_RE.match(lines[first]):
            break
        lines = lines[first + 1:]
    closing = next((i for i, ln in enumerate(lines) if _CLOSING_LINE_RE.match(ln)), None)
    if closing is not None:
        lines = lines[:closing]
    letter = "\n".join(ln.strip() for ln in lines)
    letter = fix_glued_numbers(re.sub(r"\n{3,}", "\n\n", letter).strip().replace("**", ""))
    for open_q, close_q in _QUOTES:
        if len(letter) > 2 and letter.startswith(open_q) and letter.endswith(close_q):
            letter = letter[1:-1].strip()
    if not letter:
        raise LetterRejected("Die KI hat keinen Text geliefert.")
    if "[" in letter or "]" in letter:
        raise LetterRejected("Antwort enthält noch Platzhalter „[ … ]“ – verworfen.")
    if len(letter) < MIN_LETTER_CHARS:
        raise LetterRejected(f"Antwort zu kurz ({len(letter)} Zeichen) – kein brauchbares Anschreiben.")
    if not wrong_perspective_ok(letter):
        raise LetterRejected("Anschreiben nicht in der Ich-Form (spricht den Bewerber mit „Sie“ an) – verworfen.")
    if sources:
        bad = invented_numbers(letter, sources)
        if bad:
            raise LetterRejected("Antwort enthält Zahlen, die weder im Profil noch in der Anzeige stehen ("
                                 + ", ".join(bad) + ") – verworfen.")
    return letter


def opencode_command(binary: str, model: str, prompt: str) -> list[str]:
    return [binary, "run", "-m", model, "--format", "json", prompt]


def run_opencode(binary: str, model: str, prompt: str, timeout_s: float,
                 workdir: str | Path | None = None) -> str:
    """Runs the opencode CLI once and returns its stdout. Kills the whole process group on timeout."""
    workdir = Path(workdir or Path(tempfile.gettempdir()) / "jobhunter-opencode")
    workdir.mkdir(parents=True, exist_ok=True)  # empty dir: no project files for the agent
    env = dict(os.environ)
    # Note: NO_COLOR / TERM=dumb make `opencode run` hang (v1.18.34) – don't set them.
    env["PATH"] = os.pathsep.join([str(Path(binary).parent), env.get("PATH") or "/usr/local/bin:/usr/bin:/bin"])
    try:
        proc = subprocess.Popen(opencode_command(binary, model, prompt), cwd=workdir, env=env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
    except (FileNotFoundError, PermissionError) as exc:
        raise LLMError(f"opencode nicht gefunden: {binary}") from exc
    try:
        out, err = proc.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        raise LLMError(f"opencode hat nach {int(timeout_s)} s nicht geantwortet – abgebrochen.") from None
    stdout = out.decode("utf-8", "replace")
    if proc.returncode != 0:
        msg = strip_ansi(err.decode("utf-8", "replace")).strip()[-400:]
        raise LLMError(f"opencode Fehler (Exit {proc.returncode})" + (f": {msg}" if msg else ""))
    return stdout


def _kill_group(proc: subprocess.Popen) -> None:
    for sig, wait in ((signal.SIGTERM, 3), (signal.SIGKILL, 3)):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.communicate(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue


def parse_llm_json(text: str) -> tuple[int, str, str]:
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise LLMError("Antwort enthält kein JSON")
    try:
        data = json.loads(text[start : end + 1])
    except json.JSONDecodeError as exc:
        raise LLMError(f"Ungültiges JSON: {exc}") from exc
    try:
        score = max(0, min(100, int(data["score"])))
    except (KeyError, TypeError, ValueError) as exc:
        raise LLMError("score fehlt") from exc
    reason = str(data.get("reason", "")).strip()
    letter = str(data.get("letter", "")).strip()
    return score, reason, letter


class LLMClient:
    def __init__(self, cfg: LLMConfig, http_client: httpx.Client | None = None,
                 anthropic_http_client=None):
        self.cfg = cfg
        # injectable for tests; the anthropic SDK >= 1.0 uses `httpx2` clients
        self.http_client = http_client
        self.anthropic_http_client = anthropic_http_client

    @property
    def label(self) -> str:
        if self.cfg.provider == "opencode":
            return OPENCODE_ORIGIN
        return f"{self.cfg.provider}:{self.cfg.model}"

    def complete(self, system: str, user: str) -> str:
        with _GENERATION_LOCK:  # never two generations at once
            if self.cfg.provider == "anthropic":
                return self._anthropic(system, user)
            if self.cfg.provider == "openai":
                return self._openai(system, user)
            if self.cfg.provider == "opencode":
                return run_opencode(self.cfg.opencode_bin, self.cfg.model, f"{system}\n\n{user}",
                                    self.cfg.timeout_s)
        raise LLMError("Kein LLM konfiguriert")

    def _anthropic(self, system: str, user: str) -> str:
        import anthropic

        client = anthropic.Anthropic(api_key=self.cfg.api_key, timeout=self.cfg.timeout_s, max_retries=2,
                                     http_client=self.anthropic_http_client)
        kwargs: dict = dict(model=self.cfg.model, max_tokens=16000, system=system,
                            messages=[{"role": "user", "content": user}])
        if self.cfg.effort:
            kwargs["output_config"] = {"effort": self.cfg.effort}
        try:
            if self.cfg.anthropic_fallbacks:
                # Server-side fallback: if the model declines (refusal), the API retries on a
                # fallback model inside the same call.
                try:
                    msg = client.beta.messages.create(
                        betas=["server-side-fallback-2026-07-01"], fallbacks="default", **kwargs)
                except anthropic.BadRequestError as exc:
                    log.info("fallbacks not accepted for %s (%s); retrying without", self.cfg.model, exc.message)
                    msg = client.messages.create(**kwargs)
            else:
                msg = client.messages.create(**kwargs)
        except anthropic.AuthenticationError as exc:
            raise LLMError("Anthropic: ungültiger API-Key") from exc
        except anthropic.RateLimitError as exc:
            raise LLMError("Anthropic: Rate-Limit erreicht") from exc
        except anthropic.APIStatusError as exc:
            raise LLMError(f"Anthropic HTTP {exc.status_code}: {exc.message}") from exc
        except anthropic.APIConnectionError as exc:
            raise LLMError("Anthropic: Netzwerkfehler") from exc
        if msg.stop_reason == "refusal":
            raise LLMError("Anthropic: Anfrage abgelehnt (refusal)")
        return "".join(b.text for b in msg.content if b.type == "text")

    def _openai(self, system: str, user: str) -> str:
        url = self.cfg.base_url.rstrip("/") + "/chat/completions"
        headers = {"Content-Type": "application/json"}
        if self.cfg.api_key:
            headers["Authorization"] = f"Bearer {self.cfg.api_key}"
        body = {"model": self.cfg.model, "temperature": 0.3,
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
        try:
            r = (self.http_client or httpx).post(url, json=body, headers=headers, timeout=self.cfg.timeout_s)
        except httpx.HTTPError as exc:
            raise LLMError(f"OpenAI-kompatibler Endpoint nicht erreichbar: {exc}") from exc
        if r.status_code != 200:
            raise LLMError(f"OpenAI-kompatibel HTTP {r.status_code}: {r.text[:200]}")
        try:
            return r.json()["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, ValueError) as exc:
            raise LLMError("Unerwartetes Antwortformat") from exc

    def write_letter(self, cv_text: str, job: dict, min_salary: int) -> LLMResult:
        """Only the cover letter. opencode: plain-text prompt + output checks (no score);
        other providers: the usual JSON evaluation (score + reason + letter)."""
        if self.cfg.provider != "opencode":
            return self.evaluate(cv_text, job, min_salary)
        raw = self.complete(LETTER_RULES, build_user_prompt(clean_profile(cv_text), job, min_salary))
        sources = [cv_text, f"{job.get('title') or ''}\n{job.get('company') or ''}\n{job.get('description') or ''}"]
        return LLMResult(None, "", clean_letter_output(raw, sources), self.label)

    def evaluate(self, cv_text: str, job: dict, min_salary: int) -> LLMResult:
        if self.cfg.provider == "opencode":
            return self.write_letter(cv_text, job, min_salary)
        text = self.complete(SYSTEM_PROMPT, build_user_prompt(cv_text, job, min_salary))
        score, reason, letter = parse_llm_json(text)
        return LLMResult(score, reason, letter, self.label)


def get_llm(cfg: LLMConfig) -> LLMClient | None:
    return LLMClient(cfg) if cfg.enabled else None


# ---------------------------------------------------------------------------
# Deterministic fallback (no LLM): a plain template the user must edit.
# ---------------------------------------------------------------------------
def _best_result(cv: CVProfile, posting_text: str) -> str:
    if not cv.results:
        return ""
    low = posting_text.lower()

    def overlap(result: str) -> int:
        words = {w for w in re.findall(r"[a-zäöüß0-9+/.-]{3,}", result.lower())}
        return sum(1 for w in words if w in low)

    return max(cv.results, key=overlap)


def template_letter(cv: CVProfile, job: dict) -> str:
    text = f"{job.get('title', '')}\n{job.get('description', '')}"
    result = _best_result(cv, text).rstrip(".")
    matched = [k for k in find_keywords(text, cv.keywords)][:3]
    company = job.get("company") or "Ihrem Unternehmen"
    s1 = (f"Aus meiner Arbeit als Specialist Support Engineer bei IONOS/STRATO (seit 2008) passt besonders: {result}."
          if result else "Seit 2008 arbeite ich als Specialist Support Engineer bei IONOS/STRATO.")
    if matched:
        s2 = (f"Die Stelle als {job.get('title')} bei {company} interessiert mich, weil dort "
              f"{', '.join(matched)} gefragt sind. [konkreten Bezug zur Anzeige ergänzen]")
    else:
        s2 = f"Die Stelle als {job.get('title')} bei {company} interessiert mich, weil [konkreter Bezug zur Anzeige]."
    s3 = ("In den ersten 90 Tagen würde ich mich in Ihre Produkte und Ihr Ticket-Setup einarbeiten, "
          "die häufigsten Anfragen auswerten und die ersten wiederkehrenden Abläufe dokumentieren und vereinfachen.")
    s4 = "Ich würde mich über ein Gespräch freuen."
    return " ".join([s1, s2, s3, s4])
