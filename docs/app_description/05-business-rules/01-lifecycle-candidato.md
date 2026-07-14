# Lifecycle del candidato

## Stati

| Stato | Descrizione | Transizioni tipiche |
|-------|-------------|---------------------|
| *(null / non creato)* | Candidato non ancora registrato | → `in_attesa` al primo SSO o creazione API |
| `in_attesa` | Registrato, intervista non iniziata | → `in_corso` |
| `in_corso` | Intervista attiva | → `in_valutazione` |
| `in_valutazione` | Intervista chiusa, job scoring in esecuzione | → `completato` o `errore` |
| `completato` | Valutazione terminata (stato definitivo o pending risolto) | — |
| `errore` | Fallimento tecnico o irrecuperabile | Possibile intervento admin |

> I nomi degli stati sono indicativi. Il fornitore può usare naming diverso purché la semantica sia equivalente.

## Gate su lettura dati

| Risorsa | Stato minimo richiesto |
|---------|------------------------|
| Trascrizione | `in_valutazione` o `completato` |
| Valutazione strutturata | `completato` (con sotto-stato valutazione `completed` o `pending`) |

## Unicità candidato

- L'**identificativo candidato** deve essere univoco nel contesto definito (globalmente o per progetto — da documentare nella specifica tecnica);
- Tentativo di creazione duplicata → errore di conflitto.

## Retry intervista

- Se valutazione in stato `pending`, il candidato può **ripetere** parte o tutta l'intervista (un solo tentativo di retry previsto);
- Dopo retry fallito (soglia non raggiunta), valutazione marcata `completed` definitivamente.

## Eliminazione e retention

- Eliminazione organizzazione/progetto → cascade su candidati e dati assessment (hard delete consigliato per compliance);
- Policy di retention audio/trascrizioni: da definire con il committente (GDPR).

## Relazione con progresso webhook

Ogni transizione significativa (nuova risposta, cambio competenza) può generare evento progresso verso sistemi esterni.
