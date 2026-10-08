# JobHunter Mac app — TODO filtro anti-trasloco (ESEGUIRE SUL MAC)

> Copia questo file nella repo `job-hunter-mac` (es. `UMZUG_TODO.md`) e fallo
> eseguire all'agente/persona che lavora in locale. Il server è già aggiornato,
> qui c'è solo da allineare la Mac app. Tempo stimato: 1–2 ore.

## 1. Contesto (cosa ha cambiato il server il 07.10.2026)

Il server (`https://mikweb.eu/jobs`, codice in `/opt/job-hunter` sul server)
non manda più mail in automatico fuori zona:

- **Nuovo stato** `zu_weit` = "Zu weit weg / Troppo lontano" (fuori
  Berlino/Brandeburgo senza 100% Remote esplicito; "Homeoffice möglich" a
  Kiel/Colonia è ibrido e NON conta).
- **Nuova vista** `far` ("🗺️ Zu weit weg").
- **Nuovo blocco** `location` in `auto_blockers`: questi annunci non partono
  mai in automatico. L'approvazione manuale resta possibile.
- Gli item di `GET /api/v1/jobs` contengono già `view` e `apply_label`
  calcolati dal server (usali, vedi punto 3).

## 2. Prerequisiti in locale

- Xcode + repo `job-hunter-mac` aggiornata (`git pull`).
- Credenziali dashboard a portata di mano (NON scriverle nel codice):
  `export JH_USER='...' JH_PASS='...'` e `export JH_URL='https://mikweb.eu/jobs'`.

## 3. TODO (in ordine)

1. **Usa `view` / `apply_label` del server.** `GET /api/v1/jobs` restituisce
   per ogni item `view` (`today|auto|manual|applied|later|far`) e `apply_label`
   già pronti. Usa questi per liste e badge; tieni le regole locali
   (`ApplyCategory.swift`) solo come fallback se i campi mancano (server vecchio).
2. **`ApplyCategory.swift` — aggiungi `.far`.** Stesse regole del server
   (`jobhunter/views.py::classify`): `applied` prima di tutto, poi `absage`→later,
   poi `zu_weit`→far, poi `neu` fuori zona→far, altrimenti auto/manual come prima.
   Label far: `Zu weit weg – kein Umzug (nur manuell prüfen)`.
3. **Tab "🗺️ Zu weit weg".** Leggi `GET /api/v1/views` (`labels`, `order`,
   `counts`) e costruisci i tab dinamicamente così: se domani arriva una nuova
   vista non si rompe niente. La vista `far` NON deve avere il pulsante di invio.
4. **🛑 Guardia anti-invio (la parte più importante, defense in depth).**
   Prima di ogni invio automatico la app deve controllare
   `GET /api/v1/jobs/{id}/email-preview` e NON inviare se:
   `status == "zu_weit"` OPPURE `view == "far"` OPPURE `"location" ∈ auto_blockers`.
   Questo deve valere anche se il server fosse vecchio / non aggiornato.
5. **Mostra il motivo del blocco.** `email-preview` restituisce `blocker_texts`
   (già in tedesco dal server, es. `Außerhalb Berlin/Brandenburg und kein 100 %
   Remote – kein Umzug`). Mostra questi testi nel dettaglio invece di un generico errore.
6. **Status picker completo.** Lo stato `zu_weit` deve essere selezionabile
   (meglio: popola il picker da `GET /api/v1/statuses` invece di una lista fissa).
   `PATCH /api/v1/jobs/{id}` accetta già `"status": "zu_weit"`.
7. **Impostazioni.** `GET /api/v1/send-settings` ora include
   `"location_filter": true`. Mostralo nella schermata E-Mail-Versand
   (es. riga `Umzugsfilter: nur Berlin/Brandenburg oder 100 % Remote — an/aus`).

## 4. Verifica con curl (prima di dire "fatto")

```bash
export JH_URL='https://mikweb.eu/jobs'
# 1. nuovo stato + nuova vista esposti dal server
curl -su "$JH_USER:$JH_PASS" "$JH_URL/api/v1/statuses"
curl -su "$JH_USER:$JH_PASS" "$JH_URL/api/v1/views"
# 2. la vista far contiene solo fuori zona (atteso: count > 0, location non-Berlino)
curl -su "$JH_USER:$JH_PASS" "$JH_URL/api/v1/jobs?view=far&limit=3" | python3 -m json.tool
# 3. un annuncio lontano (id 305 = Kiel) è bloccato per l'auto ...
curl -su "$JH_USER:$JH_PASS" "$JH_URL/api/v1/jobs/305/email-preview" | python3 -m json.tool
#    ^ atteso: "auto_eligible": false, "location" in auto_blockers
# 4. ... mentre uno di Berlino (id 1224) non ha il blocco location
curl -su "$JH_USER:$JH_PASS" "$JH_URL/api/v1/jobs/1224/email-preview" | python3 -m json.tool
```

## 5. Criteri di accettazione (checklist)

- [ ] La app compila senza warning nuovi; `ApplyCategory` gestisce `.far`.
- [ ] Tab "🗺️ Zu weit weg" visibile con conteggio uguale al server (`/views`).
- [ ] Dettaglio annuncio Kiel (id 305): mostra il blocco anti-trasloco, nessun pulsante auto.
- [ ] Test di invio automatico simulato su id 305: la app SI RIFIUTA di inviare.
- [ ] Invio automatico su id 1224 (Berlino): flusso invariato.
- [ ] `git diff` non contiene password o token.

## 6. Se qualcosa va storto

- Vista `far` vuota ma il server la riempie → stai leggendo le regole locali invece
  di `view` del server (punto 1): correggi il parsing.
- `PATCH status=zu_weit` → 422 → la app punta a un server vecchio: aggiorna
  `JH_URL` / verifica che il server sia quello rebuildato il 07.10.2026
  (`GET /api/v1/statuses` deve contenere `zu_weit`).
- Rollback server (solo emergenza, DA ESEGUIRE SUL SERVER, non sul Mac):
  `cp /opt/job-hunter/data/jobhunter.db.bak-2026-10-07-umzug /opt/jobhunter.db.tmp`
  NON spiegato qui di proposito: chiedi all'amministratore del server.
