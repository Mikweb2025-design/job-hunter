"""Find the address a posting asks applications to be e-mailed to.

Conservative on purpose: a wrong address means an application lands with a stranger,
while a missed one only means "apply manually". An address is accepted when

* the text around it asks for an application by e-mail ("Bewerbung an", "Lebenslauf an",
  "send your CV to", "mailto:" next to such a phrase, ...), or
* it is a generic recruiting mailbox (bewerbung@, jobs@, karriere@, recruiting@, ...)
  and the sentence is not just "for questions contact ...".

Never accepted: datenschutz@/privacy@/noreply@/info-style mailboxes in a questions
context, inclusion/disability officers, and postings that say "only via our portal".
"""
from __future__ import annotations

import re
from dataclasses import dataclass

EMAIL_RE = re.compile(r"(?<![\w.+-])([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})")

# Local parts that are never an application mailbox.
_IGNORED_LOCAL = re.compile(
    r"^(?:datenschutz|privacy|dataprotection|data-protection|dsb|gdpr|dpo|noreply|no-reply|"
    r"donotreply|do-not-reply|mailer-daemon|postmaster|abuse|webmaster|presse|press|"
    r"inclusion|schwerbehindertenvertretung|sbv|gleichstellung|diversity|compliance|"
    r"rechnung|invoice|buchhaltung|newsletter|support|service|kundenservice)\b",
    re.IGNORECASE,
)
# Generic recruiting mailboxes.
_GENERIC_LOCAL = re.compile(
    r"^(?:bewerbung(?:en)?|jobs?|karriere|career(?:s)?|recruiting|recruitment|talent|"
    r"application(?:s)?|apply|hr|personal|personalabteilung|stellen|job-?bewerbung)\b",
    re.IGNORECASE,
)
# Phrases (just before the address) that ask for an application by e-mail.
_POSITIVE = re.compile(
    r"(?:bewerbung(?:sunterlagen)?|unterlagen|lebenslauf|cv|resume|résumé|application|"
    r"bewirb\s+dich|bewerben\s+sie\s+sich|bewerbe\s+dich)"
    r"[^.\n]{0,80}?(?:\ban\b|\bper\s+e-?mail\b|\bvia\s+e-?mail\b|\bto\b|\bunter\b|:)\s*[\[(]?\s*$"
    r"|(?:per|via|by)\s+e-?mail\s+(?:an|to)\s*:?\s*[\[(]?\s*$"
    r"|(?:sende|senden|schick|schicken|send|e-?mail)\s+(?:uns|us)\b[^.\n]{0,60}?(?:\ban\b|\bto\b|:)\s*[\[(]?\s*$",
    re.IGNORECASE,
)
# Sentence context that makes an address a "questions" contact, not the application inbox.
_QUESTIONS = re.compile(
    r"\bfragen\b|\bquestions?\b|\brückfragen\b|\bvorab\b|\binclusion\b|\bschwerbehindert|"
    r"\bdisab|\bdatenschutz|\bprivacy\b|\bprobleme\b|\bkontaktieren\b|\bcontact\b|"
    r"\bwenden\b|\banliegen\b|\binformationen\b|\bauskunft\b",
    re.IGNORECASE,
)
# Whole-posting statements that e-mail applications are not wanted.
_PORTAL_ONLY = re.compile(
    r"keine\s+(?:bewerbungen\s+)?per\s+e-?mail|bewerbungen\s+per\s+e-?mail\s+(?:können\s+)?(?:nicht|werden\s+nicht)|"
    r"ausschließlich\s+(?:über|via|online)|nur\s+(?:über\s+(?:unser|das|den)|online)|"
    r"only\s+(?:via|through)\s+(?:our\s+)?(?:online|career|portal|website)|do\s+not\s+(?:send|accept)\s+applications\s+by\s+e-?mail",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class ApplyEmail:
    email: str
    why: str  # "phrase" | "generic" | "closing"


def _sentence(text: str, start: int, end: int) -> tuple[str, str]:
    """Text from the previous sentence break to the address, and the whole sentence."""
    left = max(text.rfind(".\n", 0, start), text.rfind("\n\n", 0, start), text.rfind(". ", 0, start))
    # Keep a short lead-in even across a line break ("Lebenslauf an:\n\nx@y.de").
    before = text[max(0, start - 160):start]
    right_candidates = [i for i in (text.find("\n\n", end), text.find(". ", end)) if i != -1]
    right = min(right_candidates) if right_candidates else len(text)
    return before, text[(left + 1 if left != -1 else 0):right]


def find_apply_email(text: str | None) -> ApplyEmail | None:
    if not text:
        return None
    portal_only = bool(_PORTAL_ONLY.search(text))
    best: ApplyEmail | None = None
    candidates = {m.group(1).strip(".").lower() for m in EMAIL_RE.finditer(text)
                  if not _IGNORED_LOCAL.match(m.group(1).split("@", 1)[0])}
    for m in EMAIL_RE.finditer(text):
        email = m.group(1).strip(".").lower()
        local = email.split("@", 1)[0]
        if _IGNORED_LOCAL.match(local):
            continue
        before, sentence = _sentence(text, m.start(), m.end())
        # Drop markdown/mailto noise right before the address: "[x@y](mailto:", "mailto:".
        lead = re.sub(r"(?:\]\(mailto:|mailto:|\[)\s*$", "", before.rstrip()).rstrip()
        lead = re.sub(r"\s+", " ", lead)
        questions = bool(_QUESTIONS.search(sentence))
        if _POSITIVE.search(lead + " ") or _POSITIVE.search(lead):
            if questions and not re.search(r"bewerbung|lebenslauf|unterlagen|cv\b|application|resume",
                                           sentence, re.IGNORECASE):
                continue
            return ApplyEmail(email, "phrase")
        if portal_only:
            continue
        if _GENERIC_LOCAL.match(local) and not questions and best is None:
            best = ApplyEmail(email, "generic")
            continue
        # Classic German closing: "Wir freuen uns auf Ihre Bewerbung ..." followed by a contact
        # block with a single address – only if nothing nearby talks about questions.
        near = text[max(0, m.start() - 400):m.start()]
        if (best is None and len(candidates) == 1
                and re.search(r"(?:freuen\s+(?:wir\s+)?uns\s+(?:sehr\s+)?auf\s+(?:Ihre|deine)\s+\w*\s*Bewerbung|"
                              r"Ihre\s+(?:aussagekräftige\s+)?Bewerbung\s+(?:richten|senden)\s+Sie)",
                              near, re.IGNORECASE)
                and not _QUESTIONS.search(text[max(0, m.start() - 250):m.start()])
                and not questions):
            best = ApplyEmail(email, "closing")
    return best


def apply_fields(text: str | None) -> dict:
    """Column values for the jobs table."""
    found = find_apply_email(text)
    return {"apply_email": found.email if found else None,
            "apply_method": "email" if found else "manual",
            "apply_email_source": found.why if found else None}


def valid_email(value: str) -> bool:
    m = EMAIL_RE.fullmatch(value.strip())
    return bool(m)
