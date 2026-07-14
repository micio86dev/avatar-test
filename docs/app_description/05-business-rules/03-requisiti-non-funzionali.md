# Requisiti non funzionali

## Piattaforma e browser

### Supportati (desktop)

| Browser | Versione minima indicativa |
|---------|---------------------------|
| Google Chrome | 66+ |
| Microsoft Edge | 79+ |
| Opera | 53+ |
| Safari (macOS) | 14.1+ |

### Non supportati

| Ambiente | Motivo |
|----------|--------|
| Firefox | Incompatibilità streaming audio realtime (versione attuale) |
| Mobile / tablet | Esperienza non ottimizzata; solo desktop |

> Il nuovo stack può ampliare il supporto se tecnicamente fattibile. Minimo contrattuale: Chrome/Edge desktop recenti.

## Audio e microfono

- Richiesta esplicita permesso microfono prima dell'intervista;
- Selezione dispositivo audio input;
- Gestione errori: permesso negato, dispositivo non disponibile, ambiente troppo rumoroso (warning UX);
- Test microfono opzionale pre-intervista.

## Connettività

- Connessione internet stabile richiesta per streaming realtime;
- VPN o proxy aggressivi possono degradare l'esperienza → messaggi di troubleshooting in UI;
- Retry automatico su disconnessioni brevi (desiderabile).

## Lingue

- **Obbligatorie:** italiano, inglese;
- **Desiderabili:** spagnolo, francese, tedesco, portoghese;
- UI, domande TTS e valutazione devono essere coerenti con la lingua del progetto.

## Performance

| Metrica | Target indicativo |
|---------|-------------------|
| Latenza voce (domanda → audio udibile) | < 2–3 secondi percepiti |
| Avvio sessione dopo SSO | < 5 secondi |
| Valutazione post-intervista | < 10 minuti (p95) |

## Sicurezza e privacy

- HTTPS ovunque;
- Dati assessment (audio, trascrizioni, valutazioni) trattati come **dati personali** (GDPR);
- Secret (API, webhook, SSO) mai in log o client-side;
- Isolamento tenant: un cliente non deve vedere dati di un altro;
- Audit log operazioni admin (consigliato).

## Disponibilità

- Target SLA da definire con committente (es. 99.5% orario lavorativo);
- Manutenzione programmata comunicata in anticipo.

## Scalabilità

- Supporto concorrenza: più candidati in intervista simultanea;
- Job valutazione in coda asincrona;
- Storage asset audio con policy di retention configurabile.

## Accessibilità

- Non obbligatorio WCAG completo per v1, ma:
  - contrasto adeguato UI;
  - messaggi errore comprensibili;
  - percorso keyboard per schermate pre/post intervista (non necessariamente per conversazione vocale).

## Troubleshooting (supporto)

Cause comuni di malfunzionamento da gestire in UX e documentazione supporto:

1. Browser non supportato → messaggio con link a Chrome/Edge;
2. Microfono bloccato → istruzioni per sblocco permessi;
3. Connessione instabile / VPN → suggerimenti;
4. Estensioni browser (ad-blocker) → prova incognito.

Dettaglio scenari: incorporare in manuale operativo del fornitore.

## Fatturazione (se in scope)

- Collegamento interviste completate a record di fatturazione;
- Vista admin transazioni per organizzazione.
