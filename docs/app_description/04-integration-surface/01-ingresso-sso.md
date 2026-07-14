# Ingresso utente (SSO / magic link)

## Scopo

Consentire a un sistema esterno di inviare un candidato **già identificato** direttamente all'esperienza di intervista, senza login separato su BEAI.

## Flusso concettuale

1. Il sistema chiamante genera un **link sicuro** (o redirect) verso BEAI;
2. Il link contiene un **token** (o parametri firmati) con le informazioni di contesto;
3. BEAI valida il token, crea o aggiorna il record candidato, avvia la sessione intervista.

## Informazioni minime da ricevere

| Campo | Obbligatorio | Descrizione |
|-------|--------------|-------------|
| Identificativo candidato | Sì | Stringa opaca, univoca nel contesto del sistema chiamante. BEAI la conserva e la ripete in ogni notifica. |
| Nome visualizzato | Sì | Nome completo mostrato in UI e usato nel contesto AI |
| Contesto progetto | Sì | Riferimento alla campagna/configurazione assessment (ID progetto o equivalente) |
| Ruolo organizzativo | Sì | Codice ruolo (ICO, FLL, MLL, BUL, SRX) |
| Lingua | No (default `it`) | Lingua dell'intervista |
| Scadenza sessione | No | Validità temporale del link/token |

## Comportamento atteso di BEAI

- Se il candidato **non esiste** per quel progetto → creazione record al primo accesso;
- Se esiste già → ripresa o nuova sessione secondo regole di business (retry, stato precedente);
- Token scaduto o non valido → errore chiaro, nessun avvio intervista;
- Dopo validazione → redirect alla schermata di preparazione (microfono) o direttamente all'intervista.

## Creazione candidato al volo

Il sistema chiamante **non** deve necessariamente pre-creare il candidato via API. L'ingresso SSO può essere l'unico punto di creazione.

## Sicurezza (requisito, non implementazione)

- Il token deve essere **non falsificabile** (firma crittografica o equivalente);
- Trasmissione preferibilmente su HTTPS;
- Scadenza breve consigliata (es. 15–60 minuti);
- Un token non deve essere riutilizzabile indefinitamente dopo completamento assessment (salvo flusso retry esplicito).

## Esempio narrativo

> Il portale HR di Acme genera un link per Mario Rossi (ID interno 672), progetto "Selezione FLL 2026", ruolo FLL, lingua italiana. Mario clicca, arriva su BEAI, concede il microfono e inizia l'intervista. L'identificativo `acme-672-mrossi` compare in ogni webhook successivo.

## Fuori scope di questo documento

- Algoritmo di firma (HS256, RS256, ecc.);
- Nome parametri URL (`token`, `session`, ecc.);
- Formato interno dell'identificativo candidato.
