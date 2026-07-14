# Logica di valutazione

## Obiettivo

Al termine dell'intervista, il sistema produce una **valutazione strutturata** che quantifica le soft skill del candidato rispetto al ruolo e alle competenze del progetto.

## Processo

1. **Input:** trascrizione completa della conversazione (domande + risposte).
2. **Contesto:** ruolo del candidato, definizioni competenze, scale BARS per ruolo.
3. **Analisi:** per ogni competenza valutata, l'AI:
   - identifica comportamenti osservati nelle risposte;
   - confronta con gli indicatori BARS;
   - assegna punteggio per indicatore e per competenza;
   - calcola affidabilità (quanto le risposte sono sufficienti per giudicare).
4. **Output:** struttura JSON con punteggi, spiegazioni, estratti testuali.

## Contenuto output valutazione

Per ogni **competenza** valutata:

| Campo | Descrizione |
|-------|-------------|
| `score` | Punteggio complessivo competenza (es. media indicatori, scala numerica) |
| `reliability` | Affidabilità della valutazione (es. percentuale o qualitativa: alta/media/bassa) |
| `behaviors[]` | Lista indicatori valutati |

Per ogni **indicatore** (`behaviors`):

| Campo | Descrizione |
|-------|-------------|
| `indicator` | Nome dell'indicatore comportamentale (da BARS) |
| `score` | Punteggio assegnato (tipicamente 1–5) |
| `explanation` | Motivazione del punteggio |
| `excerpts[]` | Estratti testuali dalle risposte del candidato a supporto |

## Asset associati

Oltre al testo strutturato, la valutazione può includere riferimenti a:
- file audio delle risposte (per competenza/domanda);
- trascrizione completa (JSON o testo);
- file valutazione raw (JSON).

## Esecuzione asincrona

- La valutazione **non** è sincrona con la fine dell'intervista.
- Si avvia un job in background subito dopo la chiusura.
- Risultati tipicamente disponibili entro **pochi minuti**.
- Lo stato del candidato passa a "in valutazione" fino al completamento.

## Esempio concreto

Vedi `../03-ux-reference/esempio-report-valutazione.json` per un output reale (competenze COL, COM, CSF, ecc. con behaviors, score, excerpts).

## Note per l'implementazione

- Il motore di valutazione può essere un servizio LLM con prompt strutturati e output JSON schema.
- Le scale BARS in `framework/bars/` sono il **riferimento autoritativo** per indicatori e ancore di scoring.
- La valutazione deve essere **ripetibile** e **tracciabile** (versione prompt/modello, timestamp job).

## Stati della valutazione complessiva

| Stato | Significato |
|-------|-------------|
| `completed` | Valutazione considerata definitiva (soglia competenze raggiunta o retry esaurito) |
| `pending` | Valutazione elaborata ma con copertura competenze insufficiente; candidato può ritentare |

Dettaglio regole: `../05-business-rules/02-regole-valutazione.md`.
