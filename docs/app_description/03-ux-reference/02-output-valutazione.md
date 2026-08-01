# Riferimento output valutazione

## File di esempio

`esempio-report-valutazione.json` — output reale di una valutazione completata (candidato livello ICO, competenze parziali del set).

## Struttura attesa

```json
{
  "CODICE_COMPETENZA": {
    "score": 3.67,
    "reliability": "100%",
    "behaviors": [
      {
        "indicator": "Nome indicatore BARS",
        "score": 3,
        "explanation": "Motivazione del punteggio...",
        "excerpts": [
          "Estratto dalle risposte del candidato...",
          "Altro estratto..."
        ]
      }
    ]
  }
}
```

## Utilizzo per il progetto

- **Pannello admin:** visualizzazione report per competenza con score, indicatori, estratti;
- **Export:** JSON scaricabile o API di lettura;
- **Webhook valutazione:** payload può includere questa struttura nel campo testuale + riferimenti ad asset (audio, trascrizione);
- **Report HTML/PDF:** il layout è libero; la struttura dati deve preservare i campi sopra.

## Note

- I punteggi per indicatore usano l'insieme discreto {1,3,5} (ancora più vicina, mai valori intermedi); -1 = non valutabile (escluso dalla media);
- `reliability` indica quanto le risposte hanno fornito evidenza sufficiente;
- i valori di `reliability` nell'esempio sono illustrativi e non normativi (in attesa della decisione aperta #1);
- `excerpts` devono essere citazioni fedeli dalla trascrizione (non inventate).
