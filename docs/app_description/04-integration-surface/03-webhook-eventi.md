# Webhook — eventi da notificare

## Scopo

Inviare al sistema chiamante **notifiche push** durante e dopo l'assessment, senza che il chiamante debba fare polling continuo.

## Configurazione

Per ogni **progetto** o **organizzazione** (a scelta architetturale):
- URL destinazione webhook;
- secret condiviso per verifica autenticità;
- tipi di evento abilitati.

> Nel rebuild, questa configurazione è **nativa** nella piattaforma. Non è richiesto un router intermediario.

---

## Evento 1: Progresso candidato

**Quando si invia:**
- Alla creazione del candidato (primo accesso o creazione esplicita);
- Dopo ogni risposta registrata (o a intervalli significativi di avanzamento).

**Dati concettuali nel payload:**

| Campo | Descrizione |
|-------|-------------|
| Identificativo candidato | Stesso valore ricevuto all'ingresso SSO |
| Riferimento progetto | ID o codice campagna |
| Progresso | Elenco competenze con stato avanzamento |

**Struttura progresso (per competenza):**

| Campo | Descrizione |
|-------|-------------|
| Codice competenza | es. `PRS`, `STG` |
| Risposte | Elenco risposte date: id domanda, timestamp |

**Caso nuovo candidato:** tutte le competenze del progetto presenti con liste risposte vuote.

**Caso avanzamento:** competenze con una o più risposte registrate.

---

## Evento 2: Valutazione completata

**Quando si invia:**
- Al termine del job asincrono di valutazione (indipendentemente dall'orario esatto di fine intervista).

**Dati concettuali nel payload:**

| Campo | Descrizione |
|-------|-------------|
| Identificativo candidato | Invariato |
| Riferimento progetto | ID o codice campagna |
| Stato valutazione | `completed` o `pending` (vedi regole business) |
| Valutazione | Oggetto strutturato con punteggi per competenza |

**Contenuto valutazione (concettuale):**

| Sotto-campo | Descrizione |
|-------------|-------------|
| `text` | Per competenza: score, reliability, behaviors (indicator, score, explanation, excerpts) |
| `files` | Riferimenti ad asset: audio per domanda, trascrizione, file valutazione raw |

**Stato `pending`:** valutazione elaborata ma copertura competenze insufficiente; il candidato può essere invitato a ritentare.

**Stato `completed`:** valutazione definitiva.

---

## Autenticazione notifiche (requisito generico)

- Ogni richiesta webhook deve essere **verificabile** dal ricevente;
- Meccanismo a scelta del fornitore (firma HMAC del body, header dedicato, token bearer, ecc.);
- Documentare formato verifica nella specifica tecnica.

---

## Semantica HTTP (indicativa)

| Esito | Comportamento atteso ricevente | Azione BEAI |
|-------|-------------------------------|-------------|
| Successo | Conferma ricezione | Nessun reinvio |
| Errore temporaneo | Retry con backoff | Reinvio automatico |
| Errore permanente | Log + alert admin | Nessun reinvio infinito |

---

## Esempio narrativo — progresso

> Webhook a `https://hr.acme.com/beai/events`: candidato `acme-672`, progetto 42, competenza INN ha 2 risposte (domanda 0 e 1), le altre competenze hanno 0 risposte.

## Esempio narrativo — valutazione

> Stesso endpoint, evento valutazione: stato `completed`, competenza COL score 3.67 con 3 indicatori valutati, allegati path audio e trascrizione.

---

## Riferimento struttura dati

Vedi `../03-ux-reference/esempio-report-valutazione.json` per forma del blocco `text` della valutazione.
