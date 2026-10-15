"""Employer replies from the user's mailbox (read by the macOS app from Apple Mail, read-only).

For every reply the server
* classifies it (rule based, no AI): absage · einladung · unterlagen (documents requested) ·
  rueckfrage (questions / "Rücksprache": salary, start date, availability …) · eingang (automatic
  acknowledgement) · sonstiges,
* extracts what the employer asks for (Arbeitszeugnis, Notenübersicht, Gehaltsvorstellung …),
* matches it to an application (sender domain of the sent e-mail, company name, job title),
* appends a dated line to the job's notes and stores the reply (job_replies, unique Message-ID),
* moves the status forward where the mail is unambiguous (Absage → absage/absage_firma,
  Einladung → gespraech, any reply → at least beworben). A status the user changed after the
  mail was received is never touched.

Rückfrage/Rücksprache and requested documents count as a "Rückmeldung" in the tracker
(see jobhunter.tracker.has_response). Eingangsbestätigungen do not.
"""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone

from .db import Database, now_iso
from .dedup import _fold, normalize_company, normalize_title

KINDS = ("absage", "einladung", "unterlagen", "rueckfrage", "eingang", "sonstiges")
KIND_LABELS = {
    "absage": "Absage", "einladung": "Einladung zum Gespräch", "unterlagen": "Unterlagen angefordert",
    "rueckfrage": "Rückfrage / Rücksprache", "eingang": "Eingangsbestätigung", "sonstiges": "Sonstige Antwort",
}
KIND_ICONS = {"absage": "✖", "einladung": "📅", "unterlagen": "📎", "rueckfrage": "❓", "eingang": "📨",
              "sonstiges": "✉"}
# Kinds that are a real answer of the employer ("Rückmeldung").
RESPONSE_KINDS = ("absage", "einladung", "unterlagen", "rueckfrage")
# Kinds that need an action from the applicant.
ACTION_KINDS = ("unterlagen", "rueckfrage")

MAX_BODY = 20000


@dataclass
class ReplyItem:
    message_id: str
    sender: str
    subject: str
    body: str = ""
    received_at: str = ""


@dataclass
class Classification:
    kind: str
    documents: list[str] = field(default_factory=list)   # papers to send (Zeugnisse, Zertifikate …)
    questions: list[str] = field(default_factory=list)   # information asked for (Gehalt, Eintritt …)
    deadline: str | None = None                           # "25.10.2026" when the mail names one

    @property
    def requested(self) -> list[str]:
        return self.documents + self.questions


# ---------------------------------------------------------------------------------------------
# Text preparation

_QUOTE_CUTS = [
    re.compile(r"\n\s*(?:Von|From)\s*:.{0,200}\n\s*(?:Gesendet|Sent|Datum|Date)\s*:", re.I | re.S),
    re.compile(r"\n\s*-{2,}\s*(?:Original|Ursprüngliche)[^\n]*", re.I),
    re.compile(r"\n[^\n]{0,40}\bAm\b[^\n]{3,120}\bschrieb\b[^\n]*:", re.I),
    re.compile(r"\n[^\n]{0,40}\bOn\b[^\n]{3,120}\bwrote\b[^\n]*:", re.I),
]


def strip_quoted(body: str) -> str:
    """The employer's own text: cut the quoted earlier mails (our application / our answer)."""
    text = "\n" + re.sub(r"\r\n?|[\u2028\u2029\u0085]", "\n", (body or "")[:MAX_BODY])
    cut = len(text)
    for rx in _QUOTE_CUTS:
        m = rx.search(text)
        if m:
            cut = min(cut, m.start())
    lines = [ln for ln in text[:cut].split("\n") if not ln.lstrip().startswith(">")]
    return "\n".join(lines).strip()


def answers_our_mail(body: str) -> bool:
    """The employer replied to a mail of ours (quoted below): earlier requests were answered."""
    text = "\n" + re.sub(r"\r\n?|[\u2028\u2029\u0085]", "\n", (body or "")[:MAX_BODY])
    return any(rx.search(text) for rx in _QUOTE_CUTS)


def _sentences(text: str) -> list[str]:
    flat = re.sub(r"[ \t ]+", " ", text)
    flat = re.sub(r"\n\s*[-•*–]\s*", "; ", flat)          # list items stay in the sentence before
    parts = re.split(r"(?<=[.!?])\s+|\n{2,}", flat)
    return [p.strip() for p in parts if p.strip()]


# Sentences that only talk about a possibility ("falls …", "sollten wir …") never decide the kind.
_CONDITIONAL = re.compile(
    r"\b(falls|sofern|sollten?|solltest|sobald|im falle|wenn sie keine|wenn du keine|als absage zu werten|"
    r"keine rückmeldung (?:von uns )?erhalten|if you (?:have|do not|don't)|in case|abgelehnter bewerber|"
    r"nicht immer (?:eine )?persönliche)\b", re.I)

_ABSAGE = re.compile(
    r"(nicht (?:weiter |mehr )?(?:zu )?berücksichtig|nicht in die engere auswahl|nicht für sie entschieden|"
    r"nicht für dich entschieden|für (?:eine|einen) andere[nr]? (?:kandidat|bewerber)|"
    r"mit anderen kandidat|anderen bewerber(?:innen|n)? entschieden|keinen positiven bescheid|"
    r"keine positivere? rückmeldung|nicht für die nächste runde|nicht anbieten können|keine erfreulicheren nachrichten|(?:ihre|deine|eine) absage|absage (?:erteilen|mitteilen)|nicht (?:optimal|ausreichend)[^.]{0,80}(?:passt|übereinstimmt|entspricht)|"
    r"leider (?:müssen|muss|können|kann) (?:wir|ich) (?:ihnen|dir|euch)? ?(?:mitteilen|heute mitteilen)|"
    r"(?:stelle|position) (?:wurde |ist )?(?:bereits )?(?:besetzt|vergeben)|"
    r"unfortunately,? (?:we|i) (?:have|had|must|will|are|cannot|can not|decided)|not (?:be )?(?:moving|proceed)|decided to (?:move|proceed) with other|not been successful)",
    re.I)

_EINLADUNG = re.compile(
    r"(zu einem (?:ersten |zweiten |2\. |persönlichen |kurzen )?(?:vorstellungs|kennenlern|video|telefon)?(?:gespräch|interview|telefonat)|"
    r"(?:gespräch|interview|telefonat)[^.]{0,40}einladen|einladen[^.]{0,60}(?:gespräch|interview)|"
    r"kennen ?lernen|terminvorschl|telefoninterview|vorstellungsgespräch|ihr(?:en)? termin am|"
    r"dein(?:en)? termin|neuer termin|terminverschiebung|kalendereinladung|meet\.google\.com|teams\.microsoft\.com|"
    r"zoom\.us/|hast du [^.?]{0,40}zeit\?|haben sie [^.?]{0,40}zeit\?|ich rufe (?:dich|sie) an|"
    r"invite you to (?:an )?interview|schedule (?:a|an) (?:call|interview))",
    re.I)

_EINGANG = re.compile(
    r"(eingangsbestätigung|bestätigen (?:wir )?(?:hiermit )?den eingang|ihre bewerbung (?:ist )?(?:bei uns )?eingegangen|"
    r"deine bewerbung (?:ist )?(?:bei uns )?eingegangen|haben (?:ihre|deine) bewerbung erhalten|"
    r"(?:ihre|deine) (?:unterlagen|mail) (?:haben wir erhalten|ist eingegangen)|automatische antwort|automatic reply|"
    r"automatisierte eingangsbestätigung|etwas (?:zeit|geduld)|um (?:etwas )?geduld|"
    r"(?:melden|setzen) uns (?:so bald|schnellstmöglich|baldmöglichst|zeitnah)|received your application|"
    r"thank you for (?:your )?(?:submitting|application)|vielen dank für (?:deine|ihre|dein|ihr) (?:bewerbung|interesse)|"
    r"(?:prüfen|sichten) (?:deine|ihre) unterlagen|bewerbungsdaten (?:nun )?im)",
    re.I)

# A request addressed to the applicant.
_REQUEST = re.compile(
    r"(benötigen (?:wir )?(?:noch|außerdem|zusätzlich)?|bitten? (?:wir |ich )?(?:sie|dich|euch)|bitte (?:sende|schick|reich|teil|nenn|lass)|"
    r"noch folgende|zukommen lassen|nachreich|nachzureichen|nachreichung|zu vervollständigen|vervollständigen sie|"
    r"können sie uns|kannst du uns|könnten sie uns|könntest du uns|teilen sie uns|teile uns|nennen sie uns|"
    r"würde uns interessieren|möchten wir (?:gern|gerne)? ?wissen|(?:zwei|einige|ein paar|noch) fragen|"
    r"bitte (?:um|noch)|wäre(?:n)? (?:wir )?dankbar|please (?:send|provide|share))",
    re.I)

_DOCS = [
    ("Arbeitszeugnisse", r"arbeitszeugnis|dienstzeugnis|zwischenzeugnis|referenzschreiben|work reference"),
    ("Abschlusszeugnis", r"(?<!schul)abschlusszeugnis|ausbildungszeugnis|abschluss- und|berufsabschlusszeugnis|"
                         r"diplom|bachelorzeugnis|masterzeugnis|ihk-?zeugnis|gesellenbrief|degree certificate"),
    ("Schulzeugnis", r"schulabschlusszeugnis|schulzeugnis|abiturzeugnis|realschulzeugnis"),
    ("Notenübersicht", r"notenübersicht|notenspiegel|transcript"),
    ("Praktikumszeugnis", r"praktikumszeugnis"),
    ("Zertifikate / Weiterbildungsnachweise", r"zertifikat|weiterbildungsnachweis|fortbildungsnachweis|certificat"),
    ("Sprachnachweis", r"sprachzertifikat|sprachnachweis|language certificate"),
    ("Lebenslauf", r"lebenslauf|\bcv\b|curriculum vitae|resume"),
    ("Anschreiben", r"anschreiben|motivationsschreiben|cover letter"),
    ("Führungszeugnis", r"führungszeugnis"),
    ("Arbeitserlaubnis", r"arbeitserlaubnis|aufenthaltstitel|work permit"),
]
_QUESTIONS = [
    ("Gehaltsvorstellung", r"gehaltsvorstellung|gehaltswunsch|jahresbruttogehalt|bruttojahresgehalt|gehalt|"
                           r"verdienen möcht|salary"),
    ("Eintrittstermin / Verfügbarkeit", r"eintrittstermin|eintrittsdatum|frühestmöglich|verfügbarkeit|"
                                         r"anfangen könnt|starttermin|start ?termin|kündigungsfrist|notice period|start date"),
    ("Führerschein", r"führerschein|fahrpraxis|driving licen"),
    ("Berufsabschluss", r"welchen (?:berufs)?abschluss|berufsabschluss haben"),
    ("Terminvorschläge", r"terminvorschläge|termine vorschlagen|wann passt es|wann (?:hast du|haben sie) zeit"),
    ("Datenschutz-Zustimmung", r"zustimmung zu unserer datenschutz|datenschutzerklärung (?:einzusehen und )?(?:anzunehmen|zustimm)|"
                               r"ich habe die datenschutzerklärung zur kenntnis"),
    ("Profil bestätigen", r"vervollständigen sie ihre bewerbung|bewerbungsprofil bestätigen"),
]
_DOCS_RX = [(n, re.compile(p, re.I)) for n, p in _DOCS]
_Q_RX = [(n, re.compile(p, re.I)) for n, p in _QUESTIONS]
_DEADLINE = re.compile(r"\bbis (?:spätestens |zum )?(\d{1,2}\.\d{1,2}\.(?:\d{4}|\d{2}))", re.I)
# Questions that are only offers to ask ("Hast du weitere Fragen?").
_FAQ = re.compile(r"(fragen|mehr erfahren|passwort|questions|talentpool|talent community|datenschutz)", re.I)
# Strong requests: even an automatic acknowledgement that contains one is a real request.
_STRONG = re.compile(r"(benötigen|noch folgende|zukommen lassen|nachreich|nachzureichen|zu vervollständigen|"
                     r"können sie uns|kannst du uns|könnten sie uns|könntest du uns|teilen sie uns|teile uns|"
                     r"würde uns interessieren|fragen:|please (?:send|provide))", re.I)
# "Questions" that are only portal/admin steps, not an answer of the employer.
ADMIN_QUESTIONS = {"Datenschutz-Zustimmung", "Profil bestätigen"}


def classify(subject: str, body: str) -> Classification:
    """Rule based. Priority: absage > einladung > unterlagen > rueckfrage > eingang > sonstiges."""
    own = strip_quoted(body)
    sents = _sentences(f"{subject or ''}.\n\n{own}")
    firm = [s for s in sents if not _CONDITIONAL.search(s)]
    firm_text = " \n".join(firm)

    docs: list[str] = []
    questions: list[str] = []
    deadline = None
    asking = False
    for s in firm:
        i = sents.index(s)
        req = bool(_REQUEST.search(s))
        q = s.endswith("?") and not _FAQ.search(s)
        if not (req or q):
            continue
        follow = []
        if req:  # a request often introduces a list ("noch folgende Unterlagen: …")
            for nxt in sents[i + 1:i + 8]:  # incl. "…, sofern vorhanden" list items
                if re.search(r"(grüße|grüßen|freue|freuen uns|vielen dank|regards)", nxt, re.I):
                    break
                follow.append(nxt)
        scope = " ".join([s, *follow])
        found_any = False
        for name, rx in _DOCS_RX:
            if rx.search(scope) and name not in docs:
                docs.append(name)
                found_any = True
        for name, rx in _Q_RX:
            if rx.search(scope) and name not in questions:
                questions.append(name)
                found_any = True
        asking = asking or q or found_any
        m = _DEADLINE.search(scope)
        if m and not deadline:
            deadline = m.group(1)
    if "Schulzeugnis" in docs and "Abschlusszeugnis" in docs and not re.search(
            r"(?<!schul)abschlusszeugnis|ausbildungszeugnis", firm_text, re.I):
        docs.remove("Abschlusszeugnis")

    if _ABSAGE.search(firm_text):
        kind = "absage"
    elif _EINLADUNG.search(firm_text):
        kind = "einladung"
    elif _EINGANG.search(firm_text) and not _STRONG.search(firm_text):
        kind = "eingang"   # automatic acknowledgement that only mentions documents/possibilities
    elif docs:
        kind = "unterlagen"
    elif questions and set(questions) <= ADMIN_QUESTIONS:
        kind = "sonstiges"
    elif asking and (questions or not _EINGANG.search(firm_text)):
        kind = "rueckfrage"
    elif _EINGANG.search(firm_text):
        kind = "eingang"
    else:
        kind = "sonstiges"
    if kind in ("absage", "eingang"):
        docs, questions, deadline = [], [], None
    return Classification(kind, docs, questions, deadline)


# ---------------------------------------------------------------------------------------------
# Matching a reply to an application

# Applicant-tracking / mail services: their domain says nothing about the employer.
ATS_DOMAINS = (
    "personio.de", "personio.com", "softgarden", "join.com", "onlyfy.jobs", "successfactors", "icims",
    "hrworks", "workday", "greenhouse", "lever.co", "recruitee", "smartrecruiters", "bamboohr", "d.vinci",
    "dvinci", "rexx", "umantis", "concludis", "jobbase", "talention", "teamtailor", "ashbyhq", "breezy",
    "gmail.com", "googlemail.com", "outlook.", "hotmail.", "gmx.", "web.de", "t-online.de", "yahoo.",
)
_GENERIC_TOKENS = {
    "bewerbung", "bewerbungen", "karriere", "career", "careers", "jobs", "job", "recruiting", "personal",
    "people", "team", "hr", "talent", "the", "und", "and", "fur", "der", "die", "das", "von", "mit", "it",
    "service", "services", "solutions", "systems", "group", "gruppe", "berlin", "digital", "consulting",
    "software", "technologies", "technology", "informationssysteme", "information", "gesellschaft",
    "stiftung", "mail", "noreply", "reply", "info", "notifications", "communication", "news", "office",
}


def _addr(sender: str) -> str:
    m = re.search(r"<([^>]+)>", sender or "")
    return (m.group(1) if m else (sender or "")).strip().lower()


def _domain(addr: str) -> str:
    return addr.rsplit("@", 1)[-1].lower() if "@" in addr else ""


def _core(domain: str) -> str:
    """career.datagroup.de → datagroup; m.personio.de → '' (ATS)."""
    if not domain or any(a in domain for a in ATS_DOMAINS):
        return ""
    parts = domain.split(".")
    return parts[-2] if len(parts) >= 2 else parts[0]


def _tokens(company: str) -> list[str]:
    return [t for t in normalize_company(company).split() if len(t) >= 3 and t not in _GENERIC_TOKENS]


def _folded(text: str) -> str:
    return " " + re.sub(r"[^a-z0-9+#]+", " ", _fold(text or "")) + " "


def candidate_jobs(db: Database) -> list[dict]:
    """Jobs an employer can answer: applied (status or date), with a real e-mail sent, or marked
    "interessant" (applied on a portal but not marked yet – an Eingangsbestätigung then sets "beworben")."""
    sent_ids = {r["job_id"] for r in db.sent_log(limit=100000, include_dry_run=False)}
    out = []
    for j in db.list_jobs(limit=100000):
        if j.get("close_reason") == "duplikat":
            continue
        if j["status"] in ("interessant", "beworben", "gespraech", "angebot", "absage") or j.get("applied_date") or j["id"] in sent_ids:
            out.append(j)
    return out


def match_job(db: Database, it: ReplyItem, jobs: list[dict] | None = None,
              sent_domains: dict[int, set[str]] | None = None) -> dict | None:
    jobs = candidate_jobs(db) if jobs is None else jobs
    if sent_domains is None:
        sent_domains = {}
        for r in db.sent_log(limit=100000, include_dry_run=False):
            sent_domains.setdefault(r["job_id"], set()).add(_domain(r["to_addr"]))
    addr = _addr(it.sender)
    dom = _domain(addr)
    core = _core(dom)
    display = (it.sender or "").split("<")[0]
    head = _folded(f"{display} {addr.replace('.', ' ').replace('@', ' ').replace('-', ' ').replace('+', ' ')} {it.subject}")
    text = _folded(f"{it.subject}\n{strip_quoted(it.body)[:4000]}")

    best, best_score = None, 0
    for j in jobs:
        score = 0
        doms = set(sent_domains.get(j["id"], set()))
        if j.get("apply_email"):
            doms.add(_domain(j["apply_email"]))
        if dom and core and (dom in doms or any(d.endswith("." + dom) or dom.endswith("." + d) for d in doms if d)):
            score += 100
        toks = _tokens(j.get("company") or "")
        if toks:
            if core and core in toks:
                score += 70
            hits = sum(1 for t in toks if f" {t} " in head)
            if hits:
                score += 60 + 5 * hits
            elif any(f" {t} " in text for t in toks):
                score += 40
        title = normalize_title(j.get("title") or "")
        # job titles like "Acme GmbH: Support Engineer" (some sources prefix the company)
        title = title.split("  ")[0]
        if title and len(title) >= 8:
            if f" {title} " in text:
                score += 55
            else:
                words = [w for w in title.split() if len(w) >= 4]
                if words and sum(1 for w in words if f" {w} " in text) >= max(2, int(0.8 * len(words))):
                    score += 30
        if score > best_score or (score == best_score and best is not None and score > 0
                                  and (j.get("applied_date") or "") > (best.get("applied_date") or "")):
            best, best_score = j, score
    return best if best_score >= 55 else None


# ---------------------------------------------------------------------------------------------
# Recording

def _received(it: ReplyItem) -> str:
    try:
        d = datetime.fromisoformat((it.received_at or "").replace("Z", "+00:00"))
        return (d if d.tzinfo else d.replace(tzinfo=timezone.utc)).astimezone(timezone.utc).replace(microsecond=0).isoformat()
    except ValueError:
        return now_iso()


def _fmt(iso: str) -> str:
    try:
        return datetime.fromisoformat(iso).astimezone().strftime("%d.%m.%Y")
    except ValueError:
        return iso[:10]


def note_line(c: Classification, subject: str, received: str) -> str:
    line = f"{KIND_ICONS[c.kind]} {_fmt(received)} {KIND_LABELS[c.kind]}"
    if c.documents:
        line += " – Unterlagen: " + ", ".join(c.documents)
    if c.questions:
        line += (" – Fragen: " if c.kind != "unterlagen" or c.documents else " – ") + ", ".join(c.questions)
    if c.deadline:
        line += f" (bis {c.deadline})"
    subj = re.sub(r"\s+", " ", subject or "").strip()
    if subj:
        line += f" · Mail „{subj[:90]}“"
    return line


# Status moves a reply may cause (from → to). Never backwards, never touches "angebot".
_STATUS_MOVES = {
    "absage": {"neu": "absage", "interessant": "absage", "beworben": "absage", "gespraech": "absage", "zu_weit": "absage"},
    "einladung": {"neu": "gespraech", "interessant": "gespraech", "beworben": "gespraech", "zu_weit": "gespraech"},
}
_TO_APPLIED = {"neu", "interessant", "zu_weit"}


def record_replies(db: Database, items: list[ReplyItem]) -> dict:
    out = {"received": len(items), "matched": [], "unmatched": 0, "duplicates": 0, "invalid": 0,
           "status_changed": [], "kinds": {}}
    jobs = candidate_jobs(db)
    sent_domains: dict[int, set[str]] = {}
    for r in db.sent_log(limit=100000, include_dry_run=False):
        sent_domains.setdefault(r["job_id"], set()).add(_domain(r["to_addr"]))
    items = sorted(items, key=lambda i: _received(i))
    kinds: Counter = Counter()
    for it in items:
        mid = (it.message_id or "").strip()
        if not mid or not (it.subject or it.body):
            out["invalid"] += 1
            continue
        if db.reply_exists(mid):
            out["duplicates"] += 1
            continue
        c = classify(it.subject, it.body)
        received = _received(it)
        job = match_job(db, it, jobs, sent_domains)
        kinds[c.kind] += 1
        db.insert_reply(message_id=mid, job_id=job["id"] if job else None, received_at=received,
                        sender=(it.sender or "")[:300], subject=(it.subject or "")[:300], kind=c.kind,
                        documents=", ".join(c.requested), deadline=c.deadline,
                        snippet=re.sub(r"\s+", " ", strip_quoted(it.body))[:600])
        if not job:
            out["unmatched"] += 1
            continue
        out["matched"].append(job["id"])
        job = db.get_job(job["id"])
        fields: dict = {}
        # Notes only for real answers; acknowledgements stay in the timeline (job_replies).
        line = note_line(c, it.subject, received) if c.kind in RESPONSE_KINDS else ""
        notes = (job.get("notes") or "").rstrip()
        if line and line not in notes:
            fields["notes"] = (notes + "\n" if notes else "") + line
        if c.kind != "eingang" and c.kind != "sonstiges" and (job.get("reply_at") or "") <= received:
            fields["reply_kind"] = c.kind
            fields["reply_at"] = received
        if c.kind in ACTION_KINDS and c.requested:
            open_ = [] if answers_our_mail(it.body) else \
                [x.strip() for x in (job.get("docs_requested") or "").split(",") if x.strip()]
            fields["docs_requested"] = ", ".join(dict.fromkeys(open_ + c.requested))
        elif c.kind == "absage" or (c.kind == "einladung" and answers_our_mail(it.body)):
            fields["docs_requested"] = None
        # Status: only forward, and never over a change the user made after this mail.
        user_later = (job.get("status_updated_at") or "") > received
        new_status = None
        if not user_later:
            new_status = _STATUS_MOVES.get(c.kind, {}).get(job["status"])
            if new_status is None and job["status"] in _TO_APPLIED and c.kind != "sonstiges":
                new_status = "beworben"
        if new_status and new_status != job["status"]:
            fields.update(status=new_status, status_updated_at=received)
            if new_status == "absage":
                fields["close_reason"] = "absage_firma"
            out["status_changed"].append(job["id"])
        if (new_status or job["status"]) in ("beworben", "gespraech", "absage") and not job.get("applied_date"):
            fields["applied_date"] = received[:10]
        if fields:
            db.update_job(job["id"], history_source="antwort", **fields)
    out["kinds"] = dict(kinds)
    return out


# ---------------------------------------------------------------------------------------------
# Notes written by hand before this feature ("weitere unterlagen angefordert", "fragen nach gehalt")

_NOTE_DOCS = re.compile(r"unterlage|zeugnis|zertifikat|nachweis", re.I)
_NOTE_RUECK = re.compile(r"rücksprache|ruecksprache|rücksp|rückfrage|rueckfrage|nachfrage|fragen nach|"
                         r"feedback|gehalt|eintritt|start ?termin", re.I)


def backfill_from_notes(db: Database) -> int:
    """One-time: jobs whose notes say the employer asked something get reply_kind (counts as Rückmeldung)."""
    n = 0
    for j in db.list_jobs(limit=100000):
        if j.get("reply_kind") or j["status"] not in ("beworben", "gespraech"):
            continue
        notes = j.get("notes") or ""
        if _NOTE_DOCS.search(notes):
            kind = "unterlagen"
        elif _NOTE_RUECK.search(notes):
            kind = "rueckfrage"
        else:
            continue
        db.update_job(j["id"], reply_kind=kind, reply_at=j.get("status_updated_at") or now_iso())
        n += 1
    return n


def stats(db: Database, applied_ids: set[int]) -> dict:
    """Reply statistics for the tracker (only replies matched to applied jobs count)."""
    rows = db.replies()
    by_kind: Counter = Counter()
    jobs_by_kind: dict[str, set[int]] = {k: set() for k in KINDS}
    requested: Counter = Counter()
    for r in rows:
        if r["job_id"] is None or r["job_id"] not in applied_ids:
            continue
        by_kind[r["kind"]] += 1
        jobs_by_kind.setdefault(r["kind"], set()).add(r["job_id"])
        for d in (r.get("documents") or "").split(","):
            if d.strip():
                requested[d.strip()] += 1
    unmatched = [{"received_at": r["received_at"], "sender": r["sender"], "subject": r["subject"],
                  "kind": r["kind"], "kind_label": KIND_LABELS.get(r["kind"], r["kind"])}
                 for r in rows if r["job_id"] is None and r["kind"] in RESPONSE_KINDS]
    unmatched.sort(key=lambda r: r["received_at"] or "", reverse=True)
    return {
        "mails": sum(by_kind.values()),
        "by_kind": [{"kind": k, "label": KIND_LABELS[k], "mails": by_kind.get(k, 0),
                     "jobs": len(jobs_by_kind.get(k, ()))} for k in KINDS],
        "requested": [{"item": k, "count": v} for k, v in requested.most_common(12)],
        "unmatched": unmatched[:30],
        "last_reply_at": max((r["received_at"] for r in rows), default=None),
    }


__all__ = ["ReplyItem", "Classification", "classify", "match_job", "record_replies", "backfill_from_notes",
           "stats", "KIND_LABELS", "RESPONSE_KINDS", "ACTION_KINDS"]
