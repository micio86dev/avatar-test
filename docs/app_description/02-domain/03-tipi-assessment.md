# Tipi di assessment

La piattaforma supporta due modalità di intervista con regole di competenze e flusso domande distinte.

## Standard (readiness)

**Scopo:** valutare le soft skill classiche associate al ruolo organizzativo del candidato.

| Aspetto | Comportamento |
|---------|---------------|
| Competenze | Set del framework standard per ruolo (PRS, STG, INN, …) |
| Domande | Prima domanda per competenza può essere predefinita; le successive sono decise dall'AI in tempo reale |
| Flusso | Conversazione adattiva: approfondimento o cambio competenza |
| Target tipico | Assessment di "prontezza" / readiness per un livello organizzativo |

## Potential

**Scopo:** valutare dimensioni di **potenziale di leadership** (Managing, Leadership Attributes).

| Aspetto | Comportamento |
|---------|---------------|
| Competenze | Solo **MTG** (Managing) e/o **LAT** (Leadership Attributes) |
| Domande | **4 domande predefinite** per competenza, seguite da follow-up AI |
| Flusso | Struttura più rigida rispetto allo standard |
| Target tipico | Identificazione high-potential |

## Regole di esclusività

| Tipo | Competenze ammesse |
|------|-------------------|
| Standard | Competenze del framework classico (PRS … INC) |
| Potential | Solo MTG e/o LAT |

**Non** è possibile mescolare competenze standard e potential nello stesso progetto.

## Scelta del tipo

- Il tipo è definito alla **creazione del progetto**.
- Trattarlo come **immutabile** per il ciclo di vita del progetto (cambiare tipo su progetto live crea inconsistenze sui candidati già in corso).

## Impatto su configurazione progetto

Oltre a ruolo e competenze, un progetto definisce:

| Opzione | Descrizione |
|---------|-------------|
| Lingua intervista | es. `it`, `en` |
| Pause | Ogni quante competenze mostrare una pausa (es. ogni N competenze; `null` = nessuna pausa) |
| Solleciti (nudge) | Soglia minima caratteri risposta prima di sollecitare approfondimento |
| Tipo assessment | Standard vs Potential |

## Impatto sul candidato

- Il candidato **non** sceglie il tipo: eredita la configurazione del progetto.
- Il ruolo organizzativo (ICO, FLL, …) può essere passato all'ingresso e influenzare contesto o progetto associato, a discrezione del sistema chiamante.
