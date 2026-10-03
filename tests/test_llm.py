import json

import httpx
import httpx2

from jobhunter.config import LLMConfig
from jobhunter.db import Database
from jobhunter.llm import LLMClient, LLMError
from jobhunter.pipeline import run_cycle
from jobhunter.sources.adzuna import parse_response as adzuna_parse

from .conftest import load_json
from .test_pipeline_web import FixtureSource

REPLY = {"score": 82, "reason": "Passt gut zum Cloud-Support-Profil.",
         "letter": "Satz eins. Satz zwei. Satz drei. Satz vier."}


def anthropic_handler(captured):
    def handler(req):
        captured.append(req)
        body = json.loads(req.content)
        return httpx2.Response(200, json={
            "id": "msg_test", "type": "message", "role": "assistant", "model": body["model"],
            "content": [{"type": "text", "text": json.dumps(REPLY)}],
            "stop_reason": "end_turn", "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 10}})
    return handler


def test_anthropic_request_shape_and_parse():
    captured = []
    cfg = LLMConfig(provider="anthropic", model="claude-sonnet-5-5", api_key="test-key")
    client = LLMClient(cfg, anthropic_http_client=httpx2.Client(transport=httpx2.MockTransport(anthropic_handler(captured))))
    r = client.evaluate("CV", {"title": "Cloud Support Engineer", "description": "Linux"}, 44000)
    assert (r.score, r.reason) == (82, REPLY["reason"])
    req = captured[0]
    body = json.loads(req.content)
    assert body["model"] == "claude-sonnet-5-5"
    assert body["fallbacks"] == "default"
    assert "server-side-fallback-2026-07-01" in req.headers.get("anthropic-beta", "")
    assert "Cloud Support Engineer" in body["messages"][0]["content"]


def test_anthropic_refusal_is_error():
    def handler(req):
        return httpx2.Response(200, json={
            "id": "m", "type": "message", "role": "assistant", "model": "claude-sonnet-5-5",
            "content": [], "stop_reason": "refusal", "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 0}})
    cfg = LLMConfig(provider="anthropic", model="claude-sonnet-5-5", api_key="k")
    client = LLMClient(cfg, anthropic_http_client=httpx2.Client(transport=httpx2.MockTransport(handler)))
    try:
        client.evaluate("CV", {"title": "x"}, 1)
    except LLMError as exc:
        assert "refusal" in str(exc)
    else:
        raise AssertionError


def test_openai_compatible():
    def handler(req):
        assert req.url.path == "/v1/chat/completions"
        assert json.loads(req.content)["model"] == "llama3.1"
        return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(REPLY)}}]})
    cfg = LLMConfig(provider="openai", model="llama3.1", base_url="http://ollama:11434/v1")
    client = LLMClient(cfg, http_client=httpx.Client(transport=httpx.MockTransport(handler)))
    assert client.evaluate("CV", {"title": "x"}, 1).letter == REPLY["letter"]


def test_pipeline_calls_llm_only_above_threshold(settings, monkeypatch):
    calls = []

    def fake_evaluate(self, cv_text, job, min_salary):
        from jobhunter.llm import LLMResult
        calls.append(job["title"])
        return LLMResult(90, "ok", "A. B. C. D.", "fake:model")

    monkeypatch.setattr(LLMClient, "evaluate", fake_evaluate)
    settings.llm = LLMConfig(provider="openai", model="m", base_url="http://x", threshold=50, max_per_run=1)
    db = Database(settings.db_path)
    run_cycle(settings, db=db, sources=[FixtureSource("adzuna", adzuna_parse(load_json("adzuna_search.json")))],
              notify=False)
    jobs = {j["title"]: j for j in db.list_jobs()}
    assert len(calls) == 1  # max_per_run
    top = jobs[calls[0]]
    assert top["llm_score"] == 90 and top["letter_origin"] == "fake:model"
    assert top["score"] == round((top["rule_score"] + 90) / 2)
    assert jobs["Werkstudent IT-Support (m/w/d)"]["llm_score"] is None
