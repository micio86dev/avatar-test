# Fuori scope e vincoli espliciti

## Non richiesto: retrocompatibilità

Il rebuild **non** deve mantenere compatibilità con:

| Elemento legacy | Nota |
|-----------------|------|
| API REST versione precedente (v2, v3) | Nuova specifica OpenAPI da zero |
| Formato webhook storico | Nuovo schema eventi, documentato dal fornitore |
| Formato identificativo candidato (`portale\|id\|email`, 5 parti, ecc.) | Nuovo schema opaco a scelta del fornitore |
| Componente "router" intermediario | Sostituito da configurazione nativa per-tenant/progetto |
| Pacchetti integrazione Provider attuale (BeaiApi, BeaiFull, Laravel) | Non rilevanti per questo progetto |
| URL, domini, chiavi produzione attuali | Nuovo deploy greenfield |

## Non condiviso con il fornitore (materiale interno)

- Codice sorgente versione attuale;
- Script di debug e test in `integrazione-nostra/`, `test-e-debug/`, `backup/`;
- Chiavi e secret in `documentazione-fornitore/generale/productionKey/`;
- Contratti legali (salvo invio esplicito dal committente).

## Libertà tecnologica

Il fornitore è **libero** di scegliere:

- Linguaggio, framework, database;
- Provider TTS/STT / LLM;
- Architettura (monolite, microservizi, serverless);
- Design UI/UX (salvo requisiti funzionali e riferimenti in `03-ux-reference/`).

## Vincoli non negoziabili (dominio)

- Framework ruoli e competenze (`02-domain/framework/`);
- Due tipi assessment: standard e potential;
- Valutazione basata su BARS;
- Regole soglia 90% e un retry (`05-business-rules/`);
- Superficie integrazione astratta (`04-integration-surface/`);
- Esperienza vocale realtime su desktop (Chrome/Edge minimo).

## Deliverable attesi dal fornitore

| Deliverable | Descrizione |
|-------------|-------------|
| Web app candidato | Intervista vocale end-to-end |
| Pannello admin | Gestione tenant, progetti, candidati, risultati |
| API documentata | OpenAPI + autenticazione |
| Webhook documentati | Schema eventi + verifica autenticità |
| SSO / magic link | Flusso ingresso documentato |
| Ambiente staging | Per test scenari accettazione |
| Manuale operativo | Troubleshooting browser/audio |

## Decisioni aperte (da chiudere con committente)

- SLA e hosting (cloud, regione dati UE);
- Retention audio e GDPR (durata conservazione);
- Modulo fatturazione: in scope v1 o fase 2;
- Lingue oltre IT/EN: priorità;
- Ampliamento supporto Firefox/mobile: sì/no;
- Calibrazione AI (tool per tarare scoring umano): in scope o no.

## Riferimento roadmap interna

Per evoluzioni prodotto future (non vincolanti per v1 rebuild), vedi nota interna Provider attuale su BEAI v2 (link Notion in `documentazione-fornitore/generale/elenco-sviluppi.txt`).
