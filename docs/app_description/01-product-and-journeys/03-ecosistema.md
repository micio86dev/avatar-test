# Contesto ecosistema

## Posizionamento

BEAI è la **piattaforma di assessment** (intervista + valutazione). Non è il portale HR del cliente.

Tipicamente:
- Il **portale del cliente** ospita utenti già autenticati (email, nome, ID interno);
- Un'azione nel portale (es. "Inizia assessment") genera un link verso BEAI;
- Al termine, il candidato torna al portale di origine;
- I risultati arrivano al portale tramite **notifiche asincrone**.

## Informazioni note sul candidato (lato chiamante)

Il sistema chiamante conosce sempre almeno:
- email;
- nome e cognome;
- identificativo utente nel proprio sistema.

BEAI deve poter ricevere queste informazioni (o un sottoinsieme) all'ingresso e associarle al record candidato.

## Identificativo opaco del candidato

È fondamentale un **identificativo stabile** che:
- viene passato all'ingresso;
- BEAI lo conserva e lo **ripete invariato** in ogni notifica verso l'esterno;
- permette al sistema chiamante di ricondurre eventi e risultati al proprio utente.

Il formato interno di questo identificativo è **a discrezione del nuovo progetto**. Non è richiesta compatibilità con formati legacy.

## Multi-tenant e multi-portale

In produzione coesistono:
- più **organizzazioni cliente** (aziende);
- più **portali / sistemi chiamanti** che inviano candidati;
- più **progetti** per organizzazione (campagne diverse per ruolo o tipologia).

La nuova piattaforma deve supportare:
- isolamento dati per tenant;
- configurazione flessibile di URL di ritorno e endpoint notifiche **per progetto o per tenant** (evitando intermediari obbligatori come un "router" centralizzato).

## Cosa NON replicare dall'architettura attuale

La versione corrente usa un componente intermediario ("router") perché la piattaforma legacy non permetteva di configurare webhook e URL di ritorno per ogni portale/progetto.

**Nel rebuild:** progettare nativamente la configurazione per-tenant o per-progetto di:
- URL webhook destinazione;
- URL redirect post-assessment;
- secret di autenticazione notifiche.

Questo elimina la necessità di smistamento basato su parsing dell'identificativo candidato.

## Confini di responsabilità

| Componente | Responsabilità |
|------------|----------------|
| Portale cliente | Autenticazione utente, UX pre/post assessment, ricezione webhook |
| BEAI (questo progetto) | Intervista, storage assessment, valutazione, admin, API |
| Motore AI | Conversazione adattiva, scoring (può essere modulo interno o servizio separato) |
| Servizi audio | TTS/STT realtime (provider a scelta) |
