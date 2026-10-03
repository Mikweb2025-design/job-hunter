# Job-Hunter

[English](README.md) · **Deutsch** · [Italiano (technische Details)](docs/README.it.md)

Ein selbst gehosteter Assistent für die Jobsuche in Deutschland. Jeden Morgen findet er neue Stellenanzeigen, bewertet sie anhand deines Profils, schreibt mit KI (opencode) ein kurzes deutsches Anschreiben und zeigt alles in einem Web-Dashboard und einer nativen macOS-App. Dabei trennt er klar zwischen Bewerbungen, die **automatisch per E-Mail** rausgehen, und solchen, die du **von Hand** über ein Firmenportal machst.

> **Deine Daten bleiben auf deinen eigenen Geräten.** Profil, Datenbank, Passwörter und das KI-Werkzeug (opencode) liegen auf deinem Mac und deinem eigenen Server. Dieses Repository enthält keine privaten Daten: dein echtes Profil (`data/cv_profile.md`), die `.env` mit Passwörtern und die Datenbank sind per `.gitignore` ausgeschlossen. Voreinstellungen wie die Absenderadresse in `config.yaml` sind zum Anpassen gedacht.

---

## Screenshots

| Heute zu tun (manuelle Bewerbungen) | Alle Stellen mit Automatisch/Manuell |
|---|---|
| ![Heute zu tun](docs/screenshots/web-today.png) | ![Stellen](docs/screenshots/web-jobs.png) |
| **Stellendetail: KI-Anschreiben, Score** | **Ansicht Automatisch per E-Mail** |
| ![Detail](docs/screenshots/web-detail.png) | ![Automatisch](docs/screenshots/web-auto.png) |
| **Postausgang (Gesendet / Test / Wartet / Fehler)** | **macOS-App** |
| ![Postausgang](docs/screenshots/web-outbox.png) | ![macOS](docs/screenshots/mac-app.png) |

---

## So funktioniert es

```
 Arbeitsagentur-API · Adzuna · RSS          (öffentliche Quellen, keine Logins)
                │  täglich 06:30
                ▼
 ┌────────────────────────────────┐        ┌──────────────────────────────┐
 │  Server (Docker, FastAPI)      │  API   │  macOS-App „JobHunter“       │
 │  • Dubletten + Score 0–100     │◄──────►│  • gleiche Ansichten, offline│
 │  • Anschreiben (opencode)      │        │  • schreibt Anschreiben      │
 │  • Web-Dashboard + Tracker     │        │  • sendet E-Mails über Apple │
 │  • Versandregeln (eine Quelle) │        │    Mail (nur wenn Server OK) │
 └────────────────────────────────┘        └──────────────────────────────┘
```

1. **Finden** – der Server fragt öffentliche Job-APIs ab (Bundesagentur für Arbeit, optional Adzuna und RSS-Feeds) und entfernt Dubletten.
2. **Bewerten** – jede Anzeige bekommt 0–100 Punkte: Keywords aus deinem Profil, Jobtitel, Ort/Remote, Gehalt gegenüber deinem Minimum. Ausgeschlossene Titel (Junior, Werkstudent, …) bekommen 0.
3. **Schreiben** – für gute Treffer schreibt opencode ein deutsches Anschreiben aus 4 Sätzen in der Ich-Form, nur mit Fakten aus deinem Profil und der Anzeige. Texte mit Platzhaltern, erfundenen Zahlen oder falscher Perspektive werden verworfen.
4. **Sortieren** – jede Stelle landet in genau einer Ansicht:
   - **✉ Automatisch per E-Mail** – die Anzeige nennt eine Bewerbungsadresse
   - **🖐 Manuell bewerben** – Bewerbung über das Firmenportal (der Button öffnet es und kopiert das Anschreiben)
   - **Heute zu tun** – die 10 besten manuellen Bewerbungen des Tages
   - **✅ Beworben** / **⏸ Später/Abgelehnt**
5. **Senden** – die macOS-App verschickt E-Mail-Bewerbungen über Apple Mail mit deinem Lebenslauf im Anhang, streng nach den Regeln des Servers (siehe unten). Alles wird im **Postausgang** protokolliert (Gesendet ✅ / Test 🧪 / Wartet ⏳ / Fehler ❌).
6. **Verfolgen** – Status `neu → interessant → beworben → Gespräch → Absage/Angebot`, Notizen, Bewerbungsdatum, Export als CSV/XLSX.

### Sicherheitsregeln für den automatischen Versand
- Start im **Testmodus** (`dry_run: true`) – es wird nichts gesendet, bis du ihn ausschaltest.
- Höchstens **5 pro Tag**, Mindest-Score **80**, nie zweimal dieselbe Firma innerhalb von **90 Tagen**.
- Sperrliste (z. B. dein aktueller Arbeitgeber), nie Vorlagen-Anschreiben, nie offline.
- Not-Aus (`kill_switch`) in `config.yaml` und Schalter „Automatisch senden“ in der App.
- **Keine Bots auf Jobbörsen** (StepStone, Indeed und LinkedIn verbieten das) und kein automatisches Ausfüllen von Portalformularen – das bleibt Handarbeit.

---

## Aufbau des Repositorys

| Pfad | Inhalt |
|---|---|
| `jobhunter/` | Server (Python 3.12, FastAPI, SQLite) |
| `config.yaml` | **Suchprofil und Regeln** – der wichtigste Ort zum Anpassen |
| `data/cv_profile.example.md` | Vorlage für dein Profil → kopieren nach `data/cv_profile.md` |
| `.env.example` | Vorlage für Passwörter und Overrides → kopieren nach `.env` |
| `macos/` | Native SwiftUI-App (macOS 15+) |
| `tests/` | pytest-Tests |
| `docs/README.it.md` | Vollständige technische Referenz (API, Deployment, Interna) |

---

## Schnellstart

### Server (Linux, Docker)
```bash
git clone <dieses Repo> /opt/job-hunter && cd /opt/job-hunter
cp .env.example .env && nano .env                 # DASHBOARD_USER / DASHBOARD_PASSWORD
cp data/cv_profile.example.md data/cv_profile.md && nano data/cv_profile.md
sudo chown -R 1000:1000 data
docker compose up -d --build
docker compose exec jobhunter python -m jobhunter run   # erste Suche sofort
```
Das Dashboard läuft auf `http://127.0.0.1:8000`. Davor gehört nginx oder Caddy mit HTTPS; für einen Unterordner `BASE_PATH=/jobs` setzen.

### Lokal auf dem Mac (ohne Docker)
```bash
python3.12 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
cp data/cv_profile.example.md data/cv_profile.md
DASHBOARD_USER=ich DASHBOARD_PASSWORD=geheim .venv/bin/python -m jobhunter serve --port 8000
```

### macOS-App
```bash
cd macos && scripts/build-app.sh --install     # → ~/Applications/JobHunter.app
```
Dann **⌘ ,** → Server-URL, Benutzer, Passwort (wird im Schlüsselbund gespeichert).

---

## Anpassen

### 1. Was gesucht wird – `config.yaml` → `search:`
| Schlüssel | Bedeutung |
|---|---|
| `queries` | Suchbegriffe für die Job-APIs |
| `location`, `radius_km`, `remote_ok` | wo |
| `days_back` | nur Anzeigen der letzten N Tage |
| `min_salary` | EUR/Jahr; unbekanntes Gehalt zählt neutral |
| `target_titles` | Titel, die volle Titelpunkte bringen |
| `excluded_title_keywords` | Titel enthält das → Score 0 (z. B. Junior, Praktikum) |
| `excluded_keywords` | im Text je −10; im Titel → 0 |
| `keyword_weights` | zusätzliche oder überschriebene Keyword-Gewichte |

Nach Änderungen: `docker compose restart jobhunter` und `docker compose exec jobhunter python -m jobhunter rescore`.

### 2. Wer du bist – `data/cv_profile.md`
- `## Kernergebnisse` – konkrete, wahre Ergebnisse; die KI nutzt sie für den ersten Satz. **Nur echte Fakten** – die KI darf nur Zahlen verwenden, die hier oder in der Anzeige stehen.
- `## Keywords` – Paare `Keyword: Gewicht`, die den Score bestimmen.
- Erfahrung, Kenntnisse, Ausbildung, Sprachen – Kontext für die KI.

### 3. KI-Anschreiben – opencode
| Einstellung | Wo |
|---|---|
| Anbieter/Modell auf dem Server | `.env`: `LLM_PROVIDER=opencode`, `LLM_MODEL=opencode/big-pickle`, Build mit `INSTALL_OPENCODE=1` |
| Modell in der Mac-App | Einstellungen → **KI-Anschreiben** (Liste aus `opencode models`, inkl. lokaler Ollama-Modelle) |
| Andere Anbieter | `anthropic` (API-Schlüssel) oder jeder OpenAI-kompatible Endpunkt (IONOS AI, Ollama – nur kleine Modelle) |
| Regeln fürs Anschreiben | `LETTER_RULES` in `jobhunter/llm.py` und `macos/Sources/JobHunterCore/LetterWriter.swift` (beide gleich halten) |
| Grenzen | `llm.threshold` (Mindest-Score), `llm.max_per_run`, `llm.timeout_s` |

Auch ohne KI funktioniert die App: Sie erstellt dann ein Vorlagen-Anschreiben mit `[...]`-Lücken, das nie automatisch gesendet wird.

### 4. Versand – `config.yaml` → `send:`
| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `mode` | `approve` | `off` · `approve` (pro Stelle freigeben) · `auto` |
| `dry_run` | `true` | Testmodus – nichts verlässt deinen Mac |
| `daily_cap` | `5` | max. echte Sendungen pro Tag |
| `auto_min_score` | `80` | automatisch nur ab diesem Score |
| `company_cooldown_days` | `90` | pro Firma |
| `blocklist` | – | Firmen, die nie angeschrieben werden |
| `kill_switch` | `false` | sofort alles stoppen |
| `from_address`, `sender_name`, `subject_template` | – | Angaben für die E-Mail |

In der App: Einstellungen → **E-Mail-Versand** → Lebenslauf-PDF, „Mail-Konto prüfen“, Schalter **Automatisch senden**.

### 5. Quellen, Zeitplan, Benachrichtigungen
- `sources:` Arbeitsagentur, Adzuna (`ADZUNA_APP_ID/KEY` in `.env`) und RSS-Feeds ein- oder ausschalten.
- `schedule.cron` – Standard `30 6 * * *` (Europe/Berlin).
- Telegram: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` in `.env`.
- Oberflächensprache: `ui_lang: de | it`.

---

## Entwicklung
```bash
.venv/bin/python -m pytest                                   # Server-Tests
cd macos && swift test                                       # App-Tests
```
Die API-Referenz (`/api/v1`) und Details zum Deployment stehen in [docs/README.it.md](docs/README.it.md), die App ist in [macos/README.md](macos/README.md) beschrieben.
