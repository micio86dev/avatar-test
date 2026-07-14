# API — capacità richieste (traccia)

Elenco **funzionale** delle operazioni che la piattaforma deve esporre verso sistemi esterni o automazioni admin. Il fornitore definirà REST/GraphQL, autenticazione e schema dati.

## Autenticazione (requisito generico)

- Comunicazione server-to-server autenticata;
- Credenziali per tenant o ambiente (chiave segreta, client credentials, ecc.);
- Rifiuto richieste non autenticate o non autorizzate.

---

## Area: Organizzazioni (tenant)

| Operazione | Descrizione |
|------------|-------------|
| Elenco | Tutte le organizzazioni accessibili al chiamante |
| Dettaglio | Singola organizzazione, eventualmente con progetti annidati |
| Creazione | Nuova organizzazione cliente |
| Aggiornamento | Modifica metadati (nome, configurazione) |
| Eliminazione | Rimozione con cascade su dati dipendenti (progetti, candidati, assessment) |

**Nota business:** alcune entità di sistema (es. organizzazione/progetto default) potrebbero essere protette da eliminazione.

---

## Area: Progetti (campagne assessment)

| Operazione | Descrizione |
|------------|-------------|
| Elenco | Tutti i progetti o filtro per organizzazione |
| Dettaglio | Configurazione completa: ruolo, competenze, tipo assessment, opzioni UX |
| Creazione | Nuovo progetto con `company_id`, ruolo, competenze, tipo, lingua, pause, nudge |
| Aggiornamento | Modifica campi ammessi (tipo assessment e set competenze: immutabili post-go-live consigliato) |
| Eliminazione | Rimozione progetto e dati candidati associati |

**Campi concettuali progetto:**
- organizzazione di appartenenza;
- ruolo target;
- elenco competenze;
- tipo assessment (standard / potential);
- lingua;
- opzioni UX (pause ogni N competenze, soglia nudge risposte brevi).

---

## Area: Candidati

| Operazione | Descrizione |
|------------|-------------|
| Elenco | Tutti i candidati o filtro per progetto |
| Dettaglio | Stato, metadati, link intervista se applicabile |
| Creazione | Nuovo candidato con identificativo, progetto, ruolo, lingua |
| Aggiornamento | Modifica metadati ammessi |
| Eliminazione | Rimozione candidato e dati assessment |

---

## Area: Lettura risultati (post-intervista)

| Operazione | Descrizione | Gate |
|------------|-------------|------|
| Trascrizione | Testo conversazione completa | Stato candidato ≥ "in valutazione" |
| Valutazione | Output strutturato scoring | Stato candidato = "completato" |
| Progresso | Avanzamento per competenza | Durante o dopo intervista |

I **gate per stato** evitano esposizione di dati parziali prima che il pipeline lo consenta.

---

## Area: Generazione link intervista

| Operazione | Descrizione |
|------------|-------------|
| Genera link SSO | Produce URL sicuro per un candidato (alternativa o complemento all'ingresso dal portale chiamante) |

---

## Multi-tenancy

- Ogni operazione è scoped all'organizzazione del chiamante autenticato;
- Un progetto appartiene a una sola organizzazione (non riassegnabile consigliato);
- Un candidato appartiene a un solo progetto.

---

## Cosa il fornitore deve consegnare

- Specifica OpenAPI (o equivalente) con request/response, codici errore, paginazione;
- Guida autenticazione;
- Ambiente sandbox per test integrazione.
