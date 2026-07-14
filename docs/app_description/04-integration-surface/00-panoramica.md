# Superficie di integrazione — panoramica

Questa sezione descrive **cosa** la piattaforma BEAI deve poter fare verso l'esterno, senza prescrivere **come** (protocolli, formati, autenticazione).

## Obiettivo

Permettere a sistemi terzi (portali HR, LMS, applicazioni cliente) di:
1. **Inviare** candidati autenticati all'assessment;
2. **Gestire** (opzionalmente via API) tenant, progetti e candidati;
3. **Ricevere** aggiornamenti di progresso e risultati;
4. **Ricevere** il candidato al termine dell'intervista.

## I quattro blocchi

| Blocco | File | Scopo |
|--------|------|-------|
| Ingresso | [01-ingresso-sso.md](./01-ingresso-sso.md) | Magic link / SSO per avviare sessione |
| API | [02-api-capacita.md](./02-api-capacita.md) | Operazioni machine-to-machine |
| Webhook | [03-webhook-eventi.md](./03-webhook-eventi.md) | Notifiche push verso sistemi esterni |
| Uscita | [04-uscita-utente.md](./04-uscita-utente.md) | Redirect post-assessment |

## Principi di design

- **Configurabilità per tenant/progetto:** ogni cliente può avere URL webhook e redirect diversi, senza componenti intermedi obbligatori.
- **Identificativo opaco:** un ID candidato stabile attraversata tutto il ciclo (ingresso → webhook → uscita).
- **Sicurezza:** autenticazione forte su API e notifiche (meccanismo a scelta: HMAC, JWT, API key, mTLS, ecc.).
- **Idempotenza:** i sistemi chiamanti devono poter gestire notifiche duplicate senza corruzione dati.
- **Documentazione OpenAPI:** il fornitore dovrà produrre la specifica tecnica definitiva a partire da questa traccia.

## Cosa NON è in questa sezione

- Path REST specifici;
- Formato JWT o header esatti;
- Compatibilità con API o webhook della versione precedente.
