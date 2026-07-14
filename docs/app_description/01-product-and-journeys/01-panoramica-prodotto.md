# Panoramica prodotto

## Cos'è BEAI

BEAI è una **web application** per la valutazione delle **soft skill** tramite **intervista vocale automatizzata**.

Il candidato sostiene un colloquio con un intervistatore virtuale (AI) che:
- pone domande strutturate per competenza;
- ascolta le risposte a voce;
- adatta il flusso in tempo reale (approfondimenti o passaggio alla competenza successiva);
- al termine avvia una **valutazione asincrona** basata su scale comportamentali (BARS).

## Problema che risolve

Le organizzazioni devono valutare competenze trasversali (leadership, problem solving, collaborazione, ecc.) su candidati o dipendenti in modo:
- **scalabile** (molti partecipanti, poca supervisione umana);
- **strutturato** (stesso framework per ruolo);
- **oggettivo** (scoring su indicatori comportamentali definiti a priori).

## Attori

| Attore | Ruolo |
|--------|-------|
| **Candidato** | Sostiene l'intervista vocale via browser |
| **Amministratore** | Configura aziende, progetti, candidati; monitora stato e risultati |
| **Sistema chiamante** | Portale HR o LMS esterno che invia utenti autenticati e riceve notifiche |
| **Motore AI** | Gestisce conversazione, trascrizione, valutazione (interno o esterno alla web app) |

## Componenti funzionali della piattaforma

### 1. Esperienza candidato (intervista)

Interfaccia web vocale end-to-end:
- ingresso tramite link sicuro;
- configurazione microfono;
- conversazione adattiva con voce sintetica;
- pause tra competenze e solleciti su risposte troppo brevi;
- chiusura e redirect verso sistema di origine.

### 2. Pannello amministrazione

Interfaccia per operatori interni o clienti B2B:
- gestione **Aziende** (tenant);
- gestione **Progetti** (campagne di assessment);
- gestione **Candidati** (creazione, monitoraggio, download risultati);
- eventuale modulo **fatturazione** collegato alle interviste completate.

### 3. Superficie di integrazione

Capacità machine-to-machine per sistemi esterni (dettaglio in `04-integration-surface/`):
- ingresso utente (SSO / magic link);
- API di gestione tenant e assessment;
- webhook di progresso e valutazione;
- uscita utente post-assessment.

## Modello dati concettuale

```
Azienda (tenant)
  └── Progetto (configurazione assessment)
        └── Candidato (istanza partecipante)
              ├── Risposte / trascrizione
              └── Valutazione (quando completata)
```

| Entità | Significato |
|--------|-------------|
| **Azienda** | Organizzazione cliente. Confine di tenancy e fatturazione. |
| **Progetto** | Campagna per un ruolo target: set competenze, lingua, opzioni UX (pause, solleciti), tipo assessment. |
| **Candidato** | Partecipante univoco nel contesto del progetto. Ha uno **stato** che evolve durante il ciclo di vita. |

## Architettura realtime (riferimento concettuale)

Durante l'intervista collaborano tipicamente tre layer:

```
Browser candidato  ←→  Servizi audio (TTS/STT)  ←→  Motore conversazionale / AI
                              ↓
                    Notifiche verso sistemi esterni (webhook)
```

**Obiettivo di design:** latenza minima nella conversazione. L'audio può viaggiare in streaming diretto tra browser e servizi specializzati, con orchestrazione lato backend/AI.

> Lo stack attuale (es. provider TTS/STT specifici) **non è vincolante**. L'esperienza deve essere equivalente: conversazione fluida, simile a una telefonata.

## Tipi di assessment

Vedi `02-domain/03-tipi-assessment.md`. In sintesi:

| Tipo | Descrizione |
|------|-------------|
| **Standard (readiness)** | Competenze del framework per ruolo; domande adattive AI |
| **Potential** | Solo competenze Managing e Leadership Attributes; 4 domande predefinite per competenza + follow-up AI |

## Deliverable atteso

Una piattaforma web completa che replichi **lo scopo funzionale** della versione attuale con:
- UX ridisegnata;
- architettura e stack liberi;
- integrazioni esterne progettate ex novo (seguendo la traccia in `04-integration-surface/`).
