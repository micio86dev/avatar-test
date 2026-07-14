# Uscita utente (post-assessment)

## Scopo

Al termine dell'intervista (o in uscita anticipata gestita), reindirizzare il candidato verso il **sistema di origine** con conferma dell'identità.

## Flusso concettuale

1. Il candidato completa (o abbandona secondo regole UX) l'intervista;
2. BEAI mostra eventuale schermata di chiusura / ringraziamento;
3. Redirect automatico verso **URL di ritorno** configurato per il progetto o tenant;
4. Opzionale: token di ritorno con identificativo candidato (stesso concetto dell'ingresso).

## Configurazione

| Parametro | Descrizione |
|-----------|-------------|
| URL destinazione | Landing page sul portale chiamante (es. "Assessment completato") |
| Parametri opzionali | Identificativo candidato, stato sessione, progetto |

## Comportamento atteso

- L'URL di ritorno è **configurabile per progetto** (non globale unico);
- Il candidato non deve ripetere login sul portale se la sessione è ancora valida;
- La valutazione **non** è sincrona con il redirect: il candidato può tornare al portale prima che i risultati siano pronti;
- I risultati arrivano tramite **webhook valutazione** (vedi `03-webhook-eventi.md`).

## Casi particolari

| Caso | Comportamento suggerito |
|------|-------------------------|
| Valutazione `pending` | Redirect normale; portale informa che risultati parziali o retry possibile |
| Errore tecnico in intervista | Redirect a pagina errore configurabile |
| Token ingresso scaduto a metà | Gestione graceful (salvataggio progresso se possibile) |

## Esempio narrativo

> Mario termina l'intervista alle 15:42. BEAI lo reindirizza a `https://hr.acme.com/assessment/done?ref=acme-672`. Il portale mostra "Grazie, riceverai i risultati a breve". Alle 15:45 arriva il webhook valutazione.

## Fuori scope

- Formato esatto query string o fragment;
- Nome route sul portale chiamante.
