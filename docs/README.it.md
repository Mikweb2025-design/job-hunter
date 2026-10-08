# job-hunter

Assistente self-hosted per la ricerca di lavoro. Ogni giorno cerca nuove offerte in Germania, le valuta rispetto al tuo profilo/CV, prepara una bozza di *Anschreiben* in tedesco e mostra tutto in una dashboard web con tracker delle candidature.

**La app non fa login su nessun portale.** Le candidature via portale restano un clic tuo. Le offerte che chiedono la candidatura **per e-mail** possono essere inviate dall'app macOS tramite Apple Mail – dopo la tua conferma, oppure in automatico con regole rigide (vedi [Candidature per e-mail](#candidature-per-e-mail-apple-mail)). Di default è attivo il **TESTMODUS**: non parte nessuna e-mail.

## Funzioni

- **Fonti** (plug-in, ognuna opzionale):
  - **Bundesagentur für Arbeit – Jobsuche API** (nessuna registrazione, attiva di default)
  - **Adzuna** (`country=de`, chiave gratuita, fornisce `salary_min/max`)
  - **Feed RSS/Atom** configurabili
- **Deduplica** per titolo + azienda normalizzati (senza `(m/w/d)`, `GmbH`, `AG`, …). Se la stessa offerta compare su più fonti, viene salvata una volta sola e le altre fonti vengono annotate.
- **Punteggio a regole 0–100** (veloce, senza costi):

  | Componente | Max | Logica |
  |---|---|---|
  | Keyword | 40 | keyword pesate da `data/cv_profile.md` (+ `keyword_weights` in `config.yaml`) trovate in titolo+testo |
  | Titolo | 25 | il titolo contiene uno dei `target_titles` (parziale = meno punti) |
  | Luogo | 15 | Berlino (o `extra_locations`) oppure remote/Homeoffice se `remote_ok` |
  | Stipendio | 20 | ≥ `min_salary` = 20, entro il 10% = 5, sotto = 0, **sconosciuto o stimato = 10 (neutro)** |
  | Penalità | −30 | `excluded_keywords` nel testo: −10 ciascuna |
  | Esclusione | → 0 | `excluded_title_keywords`/`excluded_keywords` nel **titolo** (es. Werkstudent, Praktikum, Junior) |

- **LLM opzionale** (solo per offerte con punteggio a regole ≥ `llm.threshold`, max `llm.max_per_run` per esecuzione): punteggio LLM, motivazione in una frase e bozza di Anschreiben in 4 frasi (1: risultato concreto più rilevante dal CV; 2: perché quest'azienda, dal testo dell'annuncio; 3: cosa faresti nei primi 90 giorni; 4: richiesta semplice di un colloquio; niente buzzword, nessun numero inventato). Punteggio finale = media di regole e LLM.
  - `anthropic` (default `claude-sonnet-5-5`, `ANTHROPIC_API_KEY`). È attivo il *server-side fallback* di Anthropic (`anthropic_fallbacks: true`): se il modello rifiuta una richiesta, l'API riprova con un modello di riserva nella stessa chiamata. Si disattiva in `config.yaml`.
  - `openai`: qualsiasi endpoint compatibile OpenAI (`/chat/completions`), es. IONOS AI Model Hub o Ollama. **Sul server (solo CPU) con Ollama usare solo modelli piccoli** (es. `llama3.2:3b`) e al massimo 1 richiesta alla volta (`OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1`): il server è già stato sovraccaricato da modelli grandi.
  - `opencode` (consigliato, è quello che usa anche l'app Mac): la CLI [opencode](https://opencode.ai) con `opencode run -m <modello> --format json "<prompt>"`, modello di default `opencode/big-pickle` (gratuito, gira in remoto: nessun modello locale, poca CPU). Scrive **solo la lettera** (nessun punteggio LLM), `letter_origin = „KI (opencode)“`. Vedi [Anschreiben con KI](#anschreiben-con-ki-opencode).
  - **Senza LLM** tutto funziona lo stesso: per le offerte sopra soglia viene generata una bozza da modello fisso (segnata come „Vorlage“, con parti tra `[...]` da completare).
- **Dashboard** (FastAPI + Jinja2, responsive, dark mode automatica + pulsante): lista ordinata per punteggio con filtri (stato, punteggio minimo, fonte, nuove da, ricerca testo), dettaglio con testo dell'annuncio, dettaglio del punteggio, motivazione, bozza con pulsante **Kopieren**, **Neu generieren**, salvataggio della bozza modificata, link **Bewerbung öffnen** all'annuncio originale.
- **Viste di lavoro** (come nell'app Mac, barra in alto con i conteggi): **Heute zu tun**, **✉ Automatisch per E-Mail**, **🖐 Manuell bewerben**, **✅ Beworben**, **⏸ Später/Abgelehnt**, **📤 Postausgang**. Vedi [Viste](#viste-di-lavoro-come-nellapp-mac).
- **Tracker**: `neu → interessant → beworben → Gespräch → Absage/Angebot`, note, data di candidatura (impostata in automatico su „beworben“). Export **CSV** e **XLSX** (rispettano i filtri attivi).
- **Telegram** opzionale: messaggio con i migliori nuovi risultati (punteggio ≥ `notify.min_score`).
- **Basic Auth** sulla dashboard (`DASHBOARD_USER`/`DASHBOARD_PASSWORD`); `/healthz` resta libero per l'healthcheck.
- **Scheduler** APScheduler con cron configurabile (default ogni giorno alle 06:30, Europe/Berlin) + pulsante „Jetzt suchen“.
- UI in tedesco; stringhe in `jobhunter/i18n.py` (c'è anche l'italiano: `UI_LANG=it`). Le bozze di lettera restano sempre in tedesco.

## Candidature per e-mail (Apple Mail)

Il **server non invia mai e-mail** (nessun SMTP, nessuna password). Decide soltanto *cosa* può partire, prepara il testo e tiene il registro. L'invio vero lo fa l'**app macOS JobHunter** tramite **Apple Mail** con l'account `info@daniele-michelin.com` (vedi README di `job-hunter-mac`). Quindi l'invio funziona solo quando il Mac è acceso e l'app è aperta.

### Indirizzo di candidatura

Per ogni offerta viene cercato nel testo l'indirizzo a cui inviare la candidatura (`apply_email`, `apply_method` = `email` | `manual`), in modo prudente (`jobhunter/apply_email.py`):

- accettato se il testo lo chiede esplicitamente („Bewerbung an …“, „Lebenslauf an: …“, „send your CV to …“, `mailto:` dopo una di queste frasi) → `phrase`;
- oppure se è una casella generica di recruiting (`bewerbung@`, `jobs@`, `karriere@`, `recruiting@`, `personal@`, …) e la frase non parla di „Fragen“/„questions“ → `generic`;
- oppure il classico blocco finale „Wir freuen uns auf Ihre Bewerbung …“ seguito da un solo contatto → `closing`;
- **mai**: `datenschutz@`, `noreply@`, `inclusion@`, contatti „per domande“, annunci con „nur über unser Portal“/„keine Bewerbungen per E-Mail“.

L'indirizzo si può correggere a mano (dashboard o app; `apply_email_source = manuell`, non viene più sovrascritto). Le offerte esistenti vengono analizzate automaticamente all'avvio dopo l'aggiornamento (migrazione) e di nuovo con `python -m jobhunter rescore`.

### Regole (`config.yaml` › `send`, un'unica fonte di verità in `jobhunter/outbox.py`)

| Chiave | Default | Significato |
|---|---|---|
| `mode` | `approve` | `off` = niente invii · `approve` = solo dopo conferma per offerta · `auto` = automatico secondo le regole |
| `dry_run` | `true` | **TESTMODUS**: nessuna e-mail parte mai. L'app al massimo apre il messaggio in Mail senza inviarlo |
| `auto_min_score` | `80` | `auto`: solo offerte con punteggio ≥ 80 |
| `daily_cap` | `5` | max. invii **reali** al giorno (giorno Europe/Berlin), vale per tutti i modi |
| `company_cooldown_days` | `90` | mai due candidature alla stessa azienda (nome normalizzato) in 90 giorni – contano anche le candidature segnate a mano come „beworben“ |
| `blocklist` | IONOS, STRATO, 1&1, United Internet, … | azienda (sottostringa, maiuscole indifferenti) o dominio del destinatario → mai |
| `require_letter` | `true` | senza lettera niente invio; lettere con segnaposto `[...]` **mai**; la bozza da modello („Vorlage“) **mai in automatico** |
| `location_filter` | `true` | **filtro anti-trasloco**: invio automatico **solo** per Berlino/Brandeburgo o 100% remote esplicito. „Homeoffice möglich“ a Köln/Kiel/Norimberga è ibrido → non conta. Approvazione manuale resta possibile; i nuovi annunci fuori zona vanno in „🗺️ Zu weit weg“ |
| `kill_switch` | `false` | `true` = stop immediato di tutto, anche delle offerte approvate (anche via ENV `SEND_KILL_SWITCH=1`) |
| `from_address` / `sender_name` | `info@daniele-michelin.com` / `Daniele Michelin` | mittente |
| `subject_template` | `Bewerbung als {title}` | `{title}` senza „(m/w/d)“, `{company}` |
| `cv_attachment` | `~/Bewerbung/Lebenslauf_Daniele_Michelin.pdf` | percorso sul Mac (modificabile nell'app) |

Altre regole sempre attive: mai due invii reali per la stessa offerta; solo offerte con stato „Neu“/„Interessant“; nell'outbox al massimo un'offerta per azienda. Gli invii di prova (`dry_run`) vengono registrati ma **non contano** per dedup, cooldown e limite giornaliero. Dopo un invio reale l'offerta passa a „beworben“ con la data di oggi.

Corpo dell'e-mail: „Sehr geehrte Damen und Herren,“ + la lettera + „Meinen Lebenslauf finden Sie im Anhang.“ + saluti/firma (`body_template` modificabile). Se la lettera ha già un saluto proprio viene usata così com'è.

### Vedere sempre cosa succede

- Fascia in alto su ogni pagina: **„TESTMODUS – es werden keine E-Mails versendet“** (giallo), **„AUTOMATISCHER VERSAND AKTIV – x von 5 heute“** (rosso), „ECHTER VERSAND nach Freigabe“ (verde), „Versand aus“ (grigio), con modo del server, stato dell'interruttore „Automatisch senden“ dell'app e i contatori *Heute gesendet · Insgesamt gesendet · Im Testmodus vorbereitet*.
- In lista e dettaglio: „✉ Gesendet am … an …“, „Test – nicht gesendet“, „Bereit zum Senden“, „Nur manuell (keine E-Mail-Adresse)“.
- Dettaglio: sezione **E-Mail-Bewerbung** con destinatario modificabile, anteprima completa, motivi di blocco, pulsante **Zum Senden freigeben** / **Freigabe zurücknehmen**, cronologia.
- Pagina **Postausgang** (`/outbox`): regole, cosa partirebbe adesso, elenco di tutti gli invii (reali e di prova).

### Attivare l'invio automatico (dal test al reale)

1. Lascia `dry_run: true` per qualche giorno e controlla nel **Postausgang** cosa partirebbe e le anteprime nel dettaglio. Senza LLM le lettere sono „Vorlage“ con `[...]`: non partono mai finché non le completi (o configuri un LLM).
2. In `config.yaml`: `send.mode: auto` e `send.dry_run: false`, poi riavvia il server (`docker compose restart jobhunter` o il comando `serve`).
3. Nell'app macOS: Impostazioni › **E-Mail-Versand** › controlla il percorso del CV, „Mail-Konto prüfen“, poi attiva **Automatisch senden**.
4. Al primo invio macOS chiede se JobHunter può controllare Mail → **Consenti** (Impostazioni di Sistema › Privacy e sicurezza › Automazione).
5. Per fermare tutto subito: `send.kill_switch: true` (o `mode: off`) e riavvio, oppure disattiva „Automatisch senden“ nell'app.

## Viste di lavoro (come nell'app Mac)

Regole in `jobhunter/views.py` (le stesse di `ApplyCategory.swift` nell'app):

| Vista | Regola |
|---|---|
| **✉ Automatisch per E-Mail** (`auto`) | stato `neu`/`interessant`, indirizzo di candidatura presente, azienda non in `send.blocklist`. Se e quando parte lo decidono le regole del Postausgang (invariate). Etichetta per riga: „Automatisch (E-Mail an x)“ |
| **🖐 Manuell bewerben** (`manual`) | stato `neu`/`interessant`, nessun indirizzo (o azienda in blocklist) → candidatura dal portale. Etichetta: „MANUELL – über Portal bewerben“ |
| **✅ Beworben** (`applied`) | stato `beworben`/`gespraech`/`angebot` oppure un invio reale registrato |
| **⏸ Später/Abgelehnt** (`later`) | stato `absage` |
| **🗺️ Zu weit weg** (`far`) | stato `zu_weit`, oppure ancora `neu` ma fuori Berlino/Brandeburgo senza 100% remote esplicito. Mai invio automatico; segnando „interessant“ passa a manuale |
| **Heute zu tun** (`today`) | le 10 migliori `manual` per punteggio, come checklist: „Jetzt manuell bewerben ↗“ (apre l'annuncio), „Anschreiben kopieren“, „Anschreiben mit KI schreiben“, „Als beworben markieren“ (solo stato + data, le note restano; non invia nulla). Sotto: „Heute erledigt“. |

URL: `/today`, `/?view=auto|manual|applied|later` (gli altri filtri restano combinabili). Layout utilizzabile da telefono (barra delle viste scorrevole, pulsanti a tutta larghezza).

**Postausgang** (`/outbox`): riepilogo „heute x von 5 · insgesamt · Test · wartet · Fehler“ e una riga per stato con data, destinatario, oggetto:
**Gesendet ✅** (invio reale), **Test 🧪** (dry run, non inviato), **Wartet ⏳** (nella coda adesso, o approvato ma in un giro successivo per limite giornaliero / un'azienda per giro), **Fehler ❌** (approvato ma ora bloccato da una regola, con il motivo).

## Anschreiben con KI (opencode)

- Configurazione: `llm.provider: opencode`, `llm.model: opencode/big-pickle` (default), `llm.timeout_s: 180`, `llm.max_per_run: 10`. Binario: `OPENCODE_BIN` → `llm.opencode_bin` → `opencode` nel `PATH` → `~/.opencode/bin/opencode`. Se il binario manca, la KI risulta disattivata e tutto funziona con le „Vorlage“.
- Prompt e controlli identici all'app Mac: 4 frasi, nessun saluto; dall'output vengono tolti codici ANSI, righe di tool/rumore, saluto e chiusura. **Scartata** (lettera precedente invariata) se contiene `[`/`]` (segnaposto), se è più corta di 200 caratteri o se contiene numeri che non stanno né nel profilo né nell'annuncio (tranne „90“).
- **Mai due generazioni contemporaneamente**: un lock unico nel processo serializza pipeline, pulsanti e API (per tutti i provider). Timeout → il gruppo di processi di opencode viene terminato.
- Dashboard: „🤖 Anschreiben mit KI schreiben“ (dettaglio e Heute zu tun) e „🤖 Alle Vorlagen schreiben (max 10)“ (lista, Heute zu tun): girano in background, una alla volta, con barra di avanzamento che si aggiorna da sola. „Alle Vorlagen“ prende le offerte aperte (`neu`/`interessant`) senza lettera, con „Vorlage“ o con `[...]`, migliori prima, al massimo `llm.max_per_run`.
- Nel giro giornaliero, con `provider: opencode` le nuove offerte sopra `llm.threshold` (max `max_per_run`) ricevono una lettera KI; il punteggio resta quello a regole.
- Le lettere KI non cambiano le regole d'invio: in modalità `approve` serve sempre l'approvazione, `dry_run` resta com'è.

## Struttura

```
job-hunter/
├── jobhunter/
│   ├── __main__.py        # CLI: run | serve | rescore
│   ├── config.py          # config.yaml + variabili d'ambiente
│   ├── models.py          # JobPosting, stati
│   ├── dedup.py           # normalizzazione titolo/azienda, deduplica
│   ├── scoring.py         # profilo CV + punteggio a regole
│   ├── llm.py             # Anthropic / OpenAI-compatibile / opencode CLI + bozza senza LLM
│   ├── views.py           # viste auto/manual/applied/later/today + righe del Postausgang
│   ├── letters.py         # „Alle Vorlagen schreiben“ in background (una alla volta)
│   ├── pipeline.py        # fetch → dedup → score → LLM → notify
│   ├── db.py              # SQLite (sqlite3)
│   ├── web.py             # dashboard FastAPI + scheduler
│   ├── api.py             # API JSON /api/v1 (client nativi)
│   ├── actions.py         # scritture condivise da dashboard e API (incl. approve/sent)
│   ├── apply_email.py     # riconoscimento dell'indirizzo di candidatura
│   ├── outbox.py          # regole d'invio, rendering e-mail, contatori (fonte unica)
│   ├── export.py          # CSV/XLSX
│   ├── notify.py          # Telegram
│   ├── i18n.py            # stringhe UI (de, it)
│   ├── sources/           # base.py, arbeitsagentur.py, adzuna.py, rss.py
│   ├── templates/         # base.html, index.html, today.html, detail.html, outbox.html, _send.html
│   └── static/style.css
├── data/cv_profile.md     # il tuo profilo (keyword + risultati concreti)
├── tests/                 # pytest + fixtures
├── config.yaml            # profilo di ricerca
├── .env.example
├── Dockerfile
└── docker-compose.yml
```

## API JSON (`/api/v1`)

Per client nativi (es. l'app macOS `JobHunter`). Stessa Basic Auth della dashboard; le scritture accettano solo `Content-Type: application/json`. Nessun endpoint invia e-mail: il server decide e registra, l'app invia.

| Metodo | Percorso | Descrizione |
|---|---|---|
| GET | `/api/v1/health` | `ok`, `api_version`, `running`, `llm_enabled`, `llm`, `letters_running`, `server_time` |
| GET | `/api/v1/statuses` | stati del tracker con etichetta (`[{id, label}]`) |
| GET | `/api/v1/jobs` | lista ordinata per punteggio; filtri `status` (anche `aktiv`), `min_score`, `source`, `since` (giorni oppure timestamp ISO-8601), `q`, `view` (`auto`/`manual`/`applied`/`later`/`today`), `limit` → `{count, items}`; ogni item ha `view` e `apply_label` |
| GET | `/api/v1/views` | conteggi per vista `{counts: {today, auto, manual, applied, later, total}, labels, order}` |
| GET | `/api/v1/jobs/{id}` | dettaglio: `description`, `score_breakdown`, `reason`, `letter`, `url`, `notes`, … |
| PATCH | `/api/v1/jobs/{id}` | `{status?, notes?, applied_date?, apply_email?}` (parziale; `applied_date: null` la cancella; „beworben“ imposta la data se manca) |
| PUT | `/api/v1/jobs/{id}/letter` | `{letter, origin?}` salva la bozza (`letter_origin` = `origin`, es. „KI (opencode)“ se scritta dall'app, default `manuell`; `vorlage` riservato) |
| POST | `/api/v1/jobs/{id}/regenerate` | rigenera la bozza (LLM o modello); errore LLM → 502 |
| POST | `/api/v1/jobs/{id}/write-letter` | scrive la lettera con la KI configurata (opencode). Sincrono (fino a `llm.timeout_s`) → dettaglio; `?wait=false` → 202 in background. 503 senza KI, 409 se la KI è occupata, 502 se fallisce/scartata |
| POST | `/api/v1/letters/write-all` | `{view?, limit?}` → 202: scrive in background le lettere mancanti/„Vorlage“ (max `llm.max_per_run`, una alla volta) |
| GET | `/api/v1/letters/status` | avanzamento `{running, busy, total, done, failed, current, errors, llm}` |
| GET | `/api/v1/outbox/log` | righe del Postausgang (`waiting`/`error`/`sent`/`test` con data, destinatario, oggetto) + `summary` |
| POST | `/api/v1/run` | avvia un giro di ricerca in background → 202 `{started}` |
| GET | `/api/v1/send-settings` | sezione `send` + contatori `sent_today`, `sent_total`, `dry_run_total`, `remaining_today` |
| GET | `/api/v1/outbox` | offerte da inviare **adesso** (tutte le regole applicate) con e-mail pronta (`to`, `sender`, `subject`, `body`, `attachment`) e `reason` (`approved` / `auto`) |
| GET | `/api/v1/jobs/{id}/email-preview` | anteprima, `can_send`, `auto_eligible`, `blockers` (+ testi), `send_state`, cronologia |
| POST/DELETE | `/api/v1/jobs/{id}/approve` | approva l'invio (409 con `blockers` se una regola lo vieta) / ritira l'approvazione |
| POST | `/api/v1/jobs/{id}/sent` | `{dry_run, sent_at?, message_id?, to?, subject?, body?, trigger?}` registra un invio; se reale → „beworben“ + data |
| GET | `/api/v1/sent` | registro invii (reali e di prova) + contatori |
| PATCH | `/api/v1/sent/{id}` | `{message_id}` |
| POST | `/api/v1/client-state` | `{auto_send_enabled, app_version?}` stato dell'interruttore dell'app (mostrato nella fascia della dashboard) |
| GET | `/api/v1/stats` | conteggi per stato, totale, fonti, `running`, `new_since_last_run`, `new_since_last_run_above_threshold` (`?min_score=`, default `notify.min_score`), `last_run` |

```bash
curl -u "$DASHBOARD_USER:$DASHBOARD_PASSWORD" "http://localhost:8000/api/v1/jobs?min_score=70&since=7"
```

## Deploy su un server Linux (Docker Compose)

Prerequisiti: Docker Engine con il plugin `docker compose`.

```bash
# 1. copiare il progetto sul server (git clone dal tuo remote, oppure rsync/scp)
rsync -av --exclude .venv --exclude data/jobhunter.db ./job-hunter/ user@server:/opt/job-hunter/
ssh user@server
cd /opt/job-hunter

# 2. configurazione
cp .env.example .env
nano .env                      # almeno DASHBOARD_USER e DASHBOARD_PASSWORD (password lunga!)
chmod 600 .env
nano config.yaml               # query, luogo, stipendio minimo, keyword...
nano data/cv_profile.md        # il tuo profilo: solo fatti reali

# 3. il container gira come uid 1000: la cartella data deve essere scrivibile
sudo chown -R 1000:1000 data

# 4. build e avvio (INSTALL_OPENCODE=1 in .env → la CLI opencode viene installata nell'immagine)
docker compose up -d --build
docker compose logs -f         # deve comparire "scheduler started: cron='30 6 * * *'"

# 5. primo giro subito (senza aspettare il cron)
docker compose exec jobhunter python -m jobhunter run
```

**KI-Anschreiben sul server (opencode).** Nel `.env`: `INSTALL_OPENCODE=1` (build arg: installa `nodejs`/`npm` dai pacchetti Debian e `opencode-ai@1.18.34` da npm; senza, l'immagine resta come prima) e, se `config.yaml` non ha già `provider: opencode`, `LLM_PROVIDER=opencode`. Poi `docker compose up -d --build` e verifica:

```bash
docker compose exec jobhunter opencode --version
docker compose exec jobhunter python -c "from jobhunter.config import load_settings as l; c=l().llm; print(c.provider, c.model, c.opencode_bin, c.enabled)"
curl -u "$DASHBOARD_USER:$DASHBOARD_PASSWORD" http://127.0.0.1:8000/api/v1/letters/status
```

`POST /api/v1/jobs/{id}/write-letter` (sincrono) può durare fino a `llm.timeout_s` (180 s): dietro nginx alzare `proxy_read_timeout` (es. 200s), oppure usare `?wait=false`. La dashboard usa sempre il background.

La porta è pubblicata solo su `127.0.0.1:8000`. Per accedere da fuori metti davanti un reverse proxy con HTTPS, es. Caddy:

```
jobs.example.org {
    reverse_proxy 127.0.0.1:8000
}
```

oppure un tunnel SSH: `ssh -L 8000:127.0.0.1:8000 user@server` → http://localhost:8000.

Comandi utili:

```bash
docker compose exec jobhunter python -m jobhunter run        # un giro di ricerca
docker compose exec jobhunter python -m jobhunter rescore    # ricalcola i punteggi dopo aver cambiato config/CV
docker compose restart jobhunter                             # dopo modifiche a config.yaml o .env
git pull && docker compose up -d --build                     # aggiornamento
cp data/jobhunter.db backup-$(date +%F).db                   # backup (SQLite, un solo file)
```

## Sviluppo locale

```bash
uv venv -p 3.12 .venv && uv pip install --python .venv/bin/python -r requirements-dev.txt
# oppure: python3.12 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
.venv/bin/python -m jobhunter run --no-notify
.venv/bin/python -m jobhunter serve --port 8000 --no-scheduler
```

## Configurazione

- `config.yaml`: profilo di ricerca (query, luogo, raggio, remote, giorni, stipendio minimo, titoli target, esclusioni, pesi keyword), fonti, LLM, cron, Telegram. Commentato riga per riga.
- `.env`: solo segreti e override (vedi `.env.example`).
- `data/cv_profile.md`: sezioni `## Kernergebnisse` (frasi usate per la prima frase della lettera) e `## Keywords` (`Keyword: peso`, separate da virgola). **Scrivi solo fatti verificabili**: l'LLM ha l'istruzione di non inventare numeri, ma può usare solo ciò che trova qui.

### Telegram

1. Su Telegram scrivi a **@BotFather** → `/newbot` → copia il token in `TELEGRAM_BOT_TOKEN`.
2. Scrivi un messaggio qualsiasi al tuo bot, poi apri `https://api.telegram.org/bot<TOKEN>/getUpdates` e copia `chat.id` in `TELEGRAM_CHAT_ID`.
3. Opzionale `PUBLIC_URL=https://jobs.example.org` per avere il link „Details“ nei messaggi.

### Adzuna

Registrazione gratuita su https://developer.adzuna.com/ → `ADZUNA_APP_ID` e `ADZUNA_APP_KEY` nel `.env`. Senza chiavi la fonte viene semplicemente saltata (visibile in „Letzte Läufe“).

### Aggiungere una fonte

Sottoclasse di `jobhunter.sources.base.Source` con `fetch(profile) -> list[JobPosting]` (e opzionale `enrich(job)` per i dettagli), poi registrala in `jobhunter/sources/__init__.py`. Regola: solo API/feed pubblici, nessun login.

## Stato dell'API Arbeitsagentur (verificato il 03.10.2026)

- `GET /pc/v4/jobs` (l'endpoint indicato all'inizio) risponde **HTTP 403 „No match found for request“** – anche fuori dalla sandbox. Non è un blocco di rete: l'endpoint non esiste più.
- `GET /pc/v6/jobs` con header `X-API-Key: jobboerse-jobsuche` **funziona** (HTTP 200, campi `ergebnisliste`, `referenznummer`, `stellenangebotsTitel`, `firma`, `stellenlokationen`, `homeofficemoeglich`, `verguetungsangabe`/`gehaltsspanneVon/Bis`…). È quello che usa la app.
- `GET /pc/v4/jobdetails/{base64(refnr)}` **funziona** e restituisce il testo completo (`stellenangebotsBeschreibung`).
- Il client prova in ordine `/pc/v6/jobs`, `/pc/v4/app/jobs`, `/pc/v4/jobs` (con fallback automatico su 403/404), usa un User-Agent proprio, retry con backoff su errori di rete/429/5xx, e un errore di una fonte non blocca le altre.
- È un'API non ufficiale (documentata dalla community in [bundesAPI/jobsuche-api](https://github.com/bundesAPI/jobsuche-api)): può cambiare senza preavviso. Se smette di funzionare, l'errore compare in „Letzte Läufe“ nella dashboard.
- Gli stipendi BA vengono convertiti in EUR/anno (mensile ×12, orario ×1720 ore).

## Sicurezza

- Imposta sempre `DASHBOARD_USER`/`DASHBOARD_PASSWORD` sul server (senza, la dashboard mostra un avviso e non ha login) e usala solo dietro HTTPS.
- I POST da un'altra origine vengono rifiutati (protezione CSRF di base).
- Il testo degli annunci viene ripulito dall'HTML e sempre mostrato come testo; l'export neutralizza le formule (CSV injection).
- Il `.env` non va in git (`.gitignore`).
- Il server non contiene codice che invia e-mail (verificato da un test). L'invio passa sempre per l'app macOS e Apple Mail; senza `send.mode: auto` + `dry_run: false` + interruttore nell'app non parte nulla in automatico.

## Pubblicare in una sottocartella (es. https://mikweb.eu/jobs/)

Nel `.env`: `BASE_PATH=/jobs` e `JOBHUNTER_PORT=<porta libera>` (es. 8091). Il reverse proxy deve togliere il prefisso:

nginx:
```nginx
location /jobs/ {
    proxy_pass http://127.0.0.1:8091/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
}
location = /jobs { return 301 /jobs/; }
```

Apache (`a2enmod proxy proxy_http`):
```apache
ProxyPass        /jobs/ http://127.0.0.1:8091/
ProxyPassReverse /jobs/ http://127.0.0.1:8091/
RedirectMatch ^/jobs$ /jobs/
```

App macOS: Server-URL `https://mikweb.eu/jobs`.
