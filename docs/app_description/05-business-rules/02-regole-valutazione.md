# Regole di valutazione

## Soglia di validità competenze

Perché una valutazione sia considerata **valida** (`completed`), il candidato deve raggiungere un numero sufficiente di competenze "valide" (con evidenza sufficiente per scoring affidabile).

| Parametro | Valore attuale |
|-----------|----------------|
| Soglia | **90%** delle competenze del progetto |
| Esempio | 12 competenze → almeno **11** valide |

Se la soglia **non** è raggiunta → stato valutazione `pending`.

## Stati valutazione (webhook / export)

| Stato | Significato | Azione suggerita portale |
|-------|-------------|--------------------------|
| `completed` | Valutazione definitiva | Mostrare risultati, chiudere ciclo |
| `pending` | Valutazione elaborata ma copertura insufficiente | Notificare candidato, offrire retry |

**Nota:** anche in stato `pending`, la valutazione **viene comunque inviata** (con i dati disponibili). Non è un errore tecnico.

## Quando `completed` si ottiene

1. Il candidato raggiunge la soglia minima di competenze valide; **oppure**
2. Il candidato ha **esaurito il retry** senza raggiungere la soglia.

## Gestione retry

| Regola | Valore |
|--------|--------|
| Tentativi retry per candidato | **1** |
| Trigger retry | Valutazione in stato `pending` |
| Esito retry insufficiente | Valutazione marcata `completed` (definitiva, anche se sotto soglia) |

## Affidabilità per competenza

Ogni competenza nel report ha un indicatore di **affidabilità** (es. percentuale o qualitativo) che riflette:
- quantità di risposte raccolte;
- profondità delle risposte;
- coerenza delle evidenze per gli indicatori BARS.

Competenza con affidabilità troppo bassa può non contare verso la soglia del 90%.

## Timing

- Valutazione avviata **subito** dopo chiusura intervista;
- Tempo di elaborazione tipico: **pochi minuti**;
- Non correlata all'orario esatto in cui il candidato ha premuto "fine" (può esserci coda).

## Contenuto minimo report

Per ogni competenza valutata, il report deve includere almeno:
- punteggio complessivo;
- almeno un indicatore con score, spiegazione e estratto;
- indicatore affidabilità.

Riferimento: `../03-ux-reference/esempio-report-valutazione.json`.
