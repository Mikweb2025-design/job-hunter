import dataclasses

from jobhunter import actions, letters
from jobhunter.llm import LLMError


class _DB:
    def __init__(self):
        self.jobs = {1: {"id": 1, "title": "Support Engineer", "company": "X", "status": "neu"}}

    def get_job(self, job_id):
        return self.jobs.get(job_id)


def _settings(settings, **llm):
    return dataclasses.replace(settings, llm=dataclasses.replace(settings.llm, **llm))


def test_retry_after_timeout_then_success(settings, monkeypatch):
    calls = []

    def fake_write(s, db, job):
        calls.append(s.llm.model)
        if len(calls) == 1:
            raise LLMError("opencode hat nach 180 s nicht geantwortet – abgebrochen.")

    monkeypatch.setattr(actions, "write_letter", fake_write)
    s = _settings(settings, model="opencode/big-pickle", retries=1, fallback_model="")
    letters._begin([{"id": 1}])
    letters._run(s, _DB(), [1])
    st = letters.status()
    assert calls == ["opencode/big-pickle", "opencode/big-pickle"]
    assert st["done"] == 1 and st["failed"] == 0


def test_fallback_model_used_last(settings, monkeypatch):
    calls = []

    def fake_write(s, db, job):
        calls.append(s.llm.model)
        raise LLMError("timeout")

    monkeypatch.setattr(actions, "write_letter", fake_write)
    s = _settings(settings, model="opencode/big-pickle", retries=1, fallback_model="opencode/other")
    letters._begin([{"id": 1}])
    letters._run(s, _DB(), [1])
    assert calls == ["opencode/big-pickle", "opencode/big-pickle", "opencode/other"]
    assert letters.status()["failed"] == 1


def test_not_configured_is_not_retried(settings, monkeypatch):
    calls = []

    def fake_write(s, db, job):
        calls.append(1)
        raise actions.LLMNotConfigured("no llm")

    monkeypatch.setattr(actions, "write_letter", fake_write)
    letters._run(_settings(settings, retries=3), _DB(), [1])
    assert calls == [1]


def test_english_words_rejected():
    import pytest
    from jobhunter.llm import LetterRejected, clean_letter_output
    body = ("Ich arbeite seit Jahren im Support und betreue viele Systeme mit großer Sorgfalt und Ausdauer. " * 3
            + "\n\nIch berate Mittelstands customers und dokumentiere alles sauber für das Team. " * 3
            + "\n\nÜber ein Gespräch freue ich mich sehr, gerne auch kurzfristig per Telefon oder vor Ort. " * 3)
    with pytest.raises(LetterRejected, match="englische"):
        clean_letter_output(body)


class _ManyDB(_DB):
    def __init__(self, n):
        self.jobs = {i: {"id": i, "title": f"Job {i}", "company": "X", "status": "neu"} for i in range(1, n + 1)}


def test_timeout_goes_straight_to_fallback(settings, monkeypatch):
    from jobhunter.llm import LLMTimeout
    calls = []

    def fake_write(s, db, job):
        calls.append(s.llm.model)
        if s.llm.model == "opencode/big-pickle":
            raise LLMTimeout("opencode hat nach 300 s nicht geantwortet – abgebrochen.")

    monkeypatch.setattr(actions, "write_letter", fake_write)
    s = _settings(settings, model="opencode/big-pickle", retries=2, fallback_model="opencode/other")
    letters._begin([{"id": 1}])
    letters._run(s, _DB(), [1])
    assert calls == ["opencode/big-pickle", "opencode/other"]  # no 2×300 s more on the same model
    assert letters.status()["done"] == 1


def test_batch_stops_when_model_keeps_timing_out(settings, monkeypatch):
    from jobhunter.llm import LLMTimeout
    seen = []

    def fake_write(s, db, job):
        seen.append((job["id"], s.llm.model))
        if s.llm.model == "opencode/big-pickle":
            raise LLMTimeout("timeout")
        raise LLMError("opencode Fehler (Exit 1)")  # the fallback fails fast

    monkeypatch.setattr(actions, "write_letter", fake_write)
    s = _settings(settings, model="opencode/big-pickle", retries=2, fallback_model="opencode/other")
    letters._begin([{"id": i} for i in range(1, 6)])
    letters._run(s, _ManyDB(5), [1, 2, 3, 4, 5])
    assert sorted({j for j, _ in seen}) == [1, 2]   # stopped after 2 jobs, 3–5 wait for the next run
    st = letters.status()
    assert st["failed"] == 2 and not st["running"]
    assert any("angehalten" in e["error"] for e in st["errors"])
