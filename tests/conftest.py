import json
from pathlib import Path

import httpx
import pytest

from jobhunter.config import LLMConfig, SearchProfile, Settings

FIX = Path(__file__).parent / "fixtures"


def load_json(name):
    return json.loads((FIX / name).read_text(encoding="utf-8"))


@pytest.fixture
def profile():
    return SearchProfile(
        queries=["Support Engineer"], location="Berlin", radius_km=30, remote_ok=True, days_back=7,
        min_salary=44000,
        target_titles=["Support Engineer", "Technical Account Manager", "Application Support"],
        excluded_title_keywords=["Werkstudent", "Praktikum"],
        excluded_keywords=["Zeitarbeit"],
        keyword_saturation=10,
    )


CV_TEXT = """# Test
## Kernergebnisse
- Technischer Support für eine Nextcloud-Plattform mit rund 15.000 Instanzen
- Eigene Tools mit Python, FastAPI und Docker
## Keywords
<!-- comment, ignored -->
Nextcloud: 4, Linux: 2, Python: 2, Docker: 2, Support, SQL, Kubernetes
S3: 2, Ticket
"""


@pytest.fixture
def cv_text():
    return CV_TEXT


@pytest.fixture
def settings(tmp_path, profile):
    (tmp_path / "cv_profile.md").write_text(CV_TEXT, encoding="utf-8")
    return Settings(profile=profile, llm=LLMConfig(), sources={}, data_dir=tmp_path)


def mock_client(handler):
    return httpx.Client(transport=httpx.MockTransport(handler))
