# BEAI — Documentazione per rebuild

Pacchetto documentale per lo sviluppo **da zero** della web app BEAI (assessment soft skill tramite intervista vocale con AI).

## Destinatario

Sviluppatore esterno incaricato di progettare e implementare la nuova piattaforma con **libertà tecnologica completa**.

## Cosa contiene

| Cartella | Contenuto |
|----------|-----------|
| [01-product-and-journeys](./01-product-and-journeys/) | Cos'è il prodotto, attori, journey utente, architettura concettuale |
| [02-domain](./02-domain/) | Ruoli, competenze, BARS, logica di valutazione, tipi di assessment |
| [03-ux-reference](./03-ux-reference/) | Messaggi in-app, esempio output valutazione |
| [04-integration-surface](./04-integration-surface/) | Traccia astratta: SSO, API, webhook, uscita utente |
| [05-business-rules](./05-business-rules/) | Lifecycle candidato, soglie valutazione, requisiti non funzionali |
| [06-acceptance-criteria](./06-acceptance-criteria/) | Scenari di accettazione narrativi |
| [07-out-of-scope](./07-out-of-scope/) | Cosa non è richiesto (retrocompatibilità, stack attuale) |

## Ordine di lettura consigliato

1. `01-product-and-journeys/01-panoramica-prodotto.md`
2. `02-domain/01-ruoli-e-competenze.md`
3. `04-integration-surface/` (tutti i file)
4. `05-business-rules/`
5. `06-acceptance-criteria/`
6. `07-out-of-scope/`

## Principi guida

- **Vincolante:** dominio (competenze, ruoli, scoring), funzionalità prodotto, regole di business.
- **Traccia (non vincolante):** tipi di integrazione esterna (SSO, API, webhook) — da progettare ex novo.
- **Fuori scope:** retrocompatibilità con integrazioni, API o stack della versione attuale.

## Fonti interne (riferimento Provider attuale)

Documentazione estratta e riscritta da materiali in `documentazione-fornitore/`, `mockup/` e note di progetto. Non include codice sorgente né contratti API specifici della versione corrente.

---

*Ultimo aggiornamento: luglio 2026*
