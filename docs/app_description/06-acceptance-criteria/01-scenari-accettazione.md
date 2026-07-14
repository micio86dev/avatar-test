# Scenari di accettazione

Scenari narrativi per validare il rebuild. Non presuppongono compatibilità con integrazioni legacy.

---

## SA-01 — Ingresso SSO e prima intervista

**Dato** un progetto "Selezione FLL" per Acme con 18 competenze in italiano  
**E** un candidato Mario Rossi non ancora registrato  
**Quando** il portale HR genera un link SSO valido e Mario lo apre su Chrome desktop  
**Allora** BEAI crea il candidato, richiede il microfono, avvia l'intervista  
**E** invia un webhook progresso con tutte le competenze e risposte vuote  

---

## SA-02 — Conversazione adattiva

**Dato** Mario in intervista sulla competenza INN  
**Quando** risponde in modo vago alla prima domanda  
**Allora** l'AI pone una domanda di follow-up sulla stessa competenza  
**Quando** risponde in modo sufficiente  
**Allora** l'AI passa alla competenza successiva  
**E** ogni risposta registrata genera aggiornamento webhook progresso  

---

## SA-03 — Nudge su risposta breve

**Dato** un progetto con soglia nudge configurata (es. minimo 50 caratteri)  
**Quando** il candidato risponde con una frase molto breve  
**Allora** il sistema emette un sollecito vocale per approfondire  

---

## SA-04 — Pause tra competenze

**Dato** un progetto con pausa ogni 3 competenze  
**Quando** il candidato completa la 3ª competenza  
**Allora** viene mostrata una schermata di pausa prima di continuare  

---

## SA-05 — Chiusura e redirect

**Dato** Mario che completa l'ultima competenza  
**Quando** l'intervista termina  
**Allora** Mario viene reindirizzato all'URL configurato per il progetto  
**E** il suo stato passa a "in valutazione"  
**E** un job asincrono di scoring viene avviato  

---

## SA-06 — Valutazione completata con successo

**Dato** Mario ha fornito risposte sufficienti su almeno 90% delle competenze (17/18)  
**Quando** il job di valutazione termina  
**Allora** arriva webhook valutazione con stato `completed`  
**E** il payload include per ogni competenza: score, reliability, behaviors con excerpts  
**E** l'admin può scaricare trascrizione e report  

---

## SA-07 — Valutazione pending e retry

**Dato** Mario ha risposte insufficienti su troppe competenze (< 90% valide)  
**Quando** il job di valutazione termina  
**Allora** webhook con stato `pending` e dati parziali  
**Quando** Mario ripete l'intervista (unico retry)  
**E** ancora non raggiunge la soglia  
**Allora** webhook successivo con stato `completed` (definitivo)  

---

## SA-08 — Assessment Potential

**Dato** un progetto tipo Potential con competenze MTG e LAT  
**Quando** un candidato avvia l'intervista  
**Allora** per ogni competenza vengono poste 4 domande predefinite seguite da follow-up AI  
**E** non compaiono competenze standard (PRS, STG, …)  

---

## SA-09 — Admin: ciclo completo tenant

**Dato** un operatore admin autenticato  
**Quando** crea organizzazione, progetto (ruolo ICO, 15 competenze), candidato  
**Allora** può generare link, monitorare stato realtime, scaricare valutazione a completamento  

---

## SA-10 — API gestione remota

**Dato** credenziali API valide per tenant Acme  
**Quando** il sistema chiamante crea progetto e candidato via API  
**E** legge stato e valutazione a completamento  
**Allora** tutte le operazioni rispettano isolamento tenant e gate per stato  

---

## SA-11 — Browser non supportato

**Dato** un candidato su Firefox desktop  
**Quando** apre il link intervista  
**Allora** vede messaggio chiaro con istruzione per usare Chrome o Edge  
**E** l'intervista non si avvia  

---

## SA-12 — Token SSO scaduto

**Dato** un link SSO generato 2 ore fa con validità 30 minuti  
**Quando** il candidato lo apre  
**Allora** vede errore "link scaduto" senza avvio intervista  

---

## Criteri di accettazione generali

- [ ] Tutti gli scenari SA-01 … SA-12 superati in ambiente staging;
- [ ] Framework competenze in `02-domain/framework/` integrato nel motore valutazione;
- [ ] Documentazione OpenAPI + guida integrazione consegnata;
- [ ] Nessuna dipendenza da componenti legacy (router, formati username storici).
