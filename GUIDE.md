# BEAI — Guida alla prova in locale

Come far girare BEAI sulla tua macchina e cosa puoi effettivamente vedere.

> **Ogni comando qui sotto è stato eseguito davvero**, su questa macchina, il
> 2026-08-01. Dove qualcosa non funziona lo dico, invece di far finta.

---

## 1. Prerequisiti

Serve solo **Docker Desktop** (testato con 29.4.3). Tutto il resto gira dentro i
container: niente PHP, Node o Bun sull'host per avviare lo stack.

```bash
docker info      # deve rispondere senza errori
```

---

## 2. Avvio

Dalla root del wrapper:

```bash
./scripts/dev.sh
```

È idempotente: rilanciarlo non rompe nulla. Opzioni utili:

| Comando | Cosa fa |
|---|---|
| `./scripts/dev.sh --build` | forza il rebuild delle immagini |
| `./scripts/dev.sh --status` | stato e salute dei servizi |
| `./scripts/dev.sh --logs` | segue i log di tutti i servizi |
| `./scripts/dev.sh --down` | ferma i container (i dati restano) |
| `./scripts/dev.sh --fresh` | **DISTRUTTIVO**: cancella i volumi e riparte da zero |

Quando finisce vedi:

```
Candidate app   http://localhost:3000
Backoffice      http://localhost:3001
API             http://localhost:8000/api/health
Mailpit         http://localhost:8025
Postgres        localhost:5432   ·   Redis  localhost:6379
```

Verifica veloce:

```bash
curl -s http://localhost:8000/api/health
# {"status":"ok", ...}
```

---

## 3. Popolare il database

Il database appena migrato è **vuoto e inutilizzabile**: senza il catalogo dei
framework (competenze, ruoli, ancore BARS) non si può creare nessun progetto.

### 3.1 Catalogo + ruoli

Il catalogo vive nel **wrapper** (`docs/app_description/`), non dentro il
sottomodulo `api` — quindi il container non lo vede. Va copiato dentro una
volta:

```bash
docker cp docs/app_description/02-domain/framework beai_api:/tmp/framework

docker compose exec -e FRAMEWORK_CATALOG_PATH=/tmp/framework api \
  php artisan db:seed
```

> **Perché il passaggio manuale.** Il seeder cerca il catalogo in
> `dirname(base_path())/docs/...`, che funziona in un checkout ma dentro
> l'immagine diventa `/var/docs`, dove non c'è niente. La variabile
> `FRAMEWORK_CATALOG_PATH` esiste apposta per scavalcare quel default.
>
> Il mount diretto (`./docs:/var/docs:ro` nel compose) sarebbe più pulito, ma
> **su questa macchina non funziona**: il progetto sta su `/Volumes/Scheda SSD`
> e Docker Desktop non ha quel percorso tra le cartelle condivise. Se lo
> aggiungi in *Settings → Resources → File Sharing*, il mount diventa la strada
> migliore.

Output atteso:

```
Database\Seeders\RolesAndPermissionsSeeder ...... DONE
Database\Seeders\FrameworkCatalogSeeder ......... DONE
```

### 3.2 Tenant demo

Non esiste API né schermata per creare un'organizzazione: progetti e partecipanti
hanno endpoint, le organizzazioni no, e il superadmin di piattaforma nasce con
`organization_id = null`. Da un database migrato non si arriva quindi in nessun
modo *via HTTP* a qualcosa in cui fare login.

Per il locale c'è un seeder che monta anche progetto e partecipante:

```bash
docker compose exec api php artisan db:seed --class=DemoSeeder
```

```
+------------------+------------------------------------------------+
| Organization     | Dev Organization (id=1)                        |
| Backoffice login | admin@beai.local / password                    |
| Project          | Demo Project — slug=demo-project, role=ICO     |
| Participant      | demo-candidate-001 (status=in_attesa)          |
+------------------+------------------------------------------------+
```

> Quella password è pubblica: il seeder si rifiuta di girare in produzione.
> È idempotente, puoi rilanciarlo quando vuoi.

### 3.3 Organizzazione vera (anche in produzione)

Il `DemoSeeder` si rifiuta di girare in produzione, e giustamente: password nota
e dati finti. Per creare un tenant reale c'è un comando che funziona ovunque, e
che soprattutto **non chiede niente in input** — quindi gira in un container
senza terminale, dove `app:create-superadmin` non può andare.

```bash
php artisan beai:provision-organization \
  --name="Acme Corp" \
  --admin-email=admin@acme.com \
  --admin-name="Acme Admin"
```

```
Organization provisioned: Acme Corp (id=1, slug=acme-corp)
Roles created: admin, operator, viewer (scoped to this organization)
Administrator: admin@acme.com
Password: <generata, 20 caratteri>
This password is shown once and cannot be recovered. Store it now.
```

Crea in un'unica transazione l'organizzazione, i tre ruoli di autorizzazione
(`admin`, `operator`, `viewer`) scoped a quell'organizzazione, e l'utente
amministratore. Con quelle credenziali entri nel backoffice.

Opzioni utili:

| Opzione | Effetto |
|---|---|
| `--slug=` | slug esplicito invece di derivarlo dal nome |
| `--admin-password=` | password scelta da te — in quel caso **non** viene stampata |
| `--locale=` | lingua delle notifiche dell'admin (default `it`) |

> Rifiuta di sovrascrivere: se lo slug o l'email esistono già esce con errore e
> non scrive nulla. L'admin creato è amministratore **della sua organizzazione**,
> non un superadmin di piattaforma — quello resta `app:create-superadmin`.

---

## 4. Cosa puoi provare adesso

### 4.1 Backoffice — http://localhost:3001

Funziona **completamente**. Accedi con `admin@beai.local` / `password`.

- **Dashboard** — metriche aggregate dell'organizzazione
- **Partecipanti** — elenco con filtri, e il dettaglio del singolo candidato
- **Template avatar** — volto, voce e messa a punto del colloquio (vedi §4.5)
- **Banner consenso analytics** — compare dopo il login (vedi §6)

I gate di lifecycle sono veri: la trascrizione si apre da `in_valutazione` in
poi, la valutazione solo su `completato`. Il candidato demo è `in_attesa`, quindi
entrambe rispondono **409** — non è un errore, è il gate che funziona.

### 4.5 Template avatar

Definiscono il volto e la voce che ogni candidato dell'organizzazione incontra.
**È attivo un solo template alla volta**, garantito da un indice unico parziale
nel database: non è una regola applicativa, quindi due attivazioni contemporanee
non possono vincere entrambe.

Il form è costruito dalle *field spec* servite dall'API — 12 knob per HeyGen, 17
per Tavus — quindi una manopola aggiunta lato server compare qui senza toccare
il frontend, e una che il server non conosce non può comparire affatto.

Cose da sapere provandolo:

- **Il servizio è nominato solo qui.** Ti serve per sapere da quale dashboard
  copiare gli identificativi. Il candidato non lo vede mai: nessuna stringa,
  nessun errore, nessuna traduzione del frontend nomina il fornitore.
- **Svuotare un campo lo rimuove**, non lo azzera: assente significa "usa il
  default del fornitore", stringa vuota è un valore.
- **Il servizio non è modificabile** dopo la creazione — le impostazioni
  appartengono a un solo fornitore e nessuna si sovrappone.
- **Il template attivo non si può eliminare**: attivane un altro prima.
- Senza chiave provider puoi creare e attivare template, ma il colloquio non
  parte (vedi §5).

Un'organizzazione **senza** template attivo non è un errore: i colloqui usano i
default d'ambiente, esattamente come prima che questa funzione esistesse.

### 4.2 API — http://localhost:8000

```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/auth/login \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"email":"admin@beai.local","password":"password"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

curl -s http://localhost:8000/api/auth/me -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json'
curl -s http://localhost:8000/api/participants -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json'
```

Verificato: il login restituisce un JWT, `/me` riporta utente + organizzazione +
ruoli, `/participants` restituisce solo i candidati del tuo tenant.

Documentazione OpenAPI generata da Scramble: `http://localhost:8000/docs/api`.

### 4.3 App candidato — http://localhost:3000

La radice è una **pagina informativa**, non una home: nessun login, nessun form.
È voluto — un candidato non digita mai questo indirizzo, ci arriva da un magic
link.

### 4.4 Mailpit — http://localhost:8025

Cattura tutte le mail in uscita. In locale non parte nessun invio finché non
scateni una notifica.

---

## 5. Cosa NON puoi provare (e perché)

Qui sta la risposta onesta a "è tutto pronto?".

### Il colloquio vero non parte

Servono credenziali che non esistono in questo repo, e giustamente:

| Serve | Per cosa | Dove sta |
|---|---|---|
| `ANTHROPIC_API_KEY` | scoring BARS asincrono | va nel variable store, mai committata |
| chiave provider avatar (HeyGen / Tavus) | video + voce sintetica | idem |

Senza chiave avatar la schermata di consenso e il device-check si vedono, ma
l'avatar non si connette. Senza chiave Anthropic un colloquio completato resta
`in_valutazione` e non arriva mai a `completato`.

### Il magic link va costruito a mano

Il flusso reale è: il sistema chiamante chiama `POST /api/m2m/sso-link` con una
chiave M2M, ottiene un token, e manda il candidato su
`/api/sso/exchange?token=…`. Per farlo in locale devi prima creare un client M2M
(`POST /api/m2m/clients` con il JWT admin). Il `DemoSeeder` **non** lo fa: minare
token di ingresso è una cosa che merita un passaggio esplicito.

### Il purge GDPR è disattivato

`beai:purge-expired-data` esiste ed è testato, ma spedisce **spento** e tutte le
durate sono `null`: aspettano una firma legale (decisione aperta #2). Lanciarlo
ora stampa `Retention is DISABLED` e non tocca niente. È l'unica cosa rimasta
aperta in C13.

### Pulse non si apre dal browser

`/pulse` registra tutto correttamente nelle tabelle `pulse_*`, ma la dashboard
HTML non è navigabile: l'API è stateless a JWT, senza login di sessione, e le
chiamate XHR di Livewire non portano l'header `Authorization`. Serve un
autenticatore davanti, oppure leggi le tabelle. Dettagli in
`docs/observability.md`.

---

## 6. Analytics e consenso

GA4 e Microsoft Clarity sono cablati in entrambe le app Nuxt, ma **spenti due
volte**: nessun ID configurato, e consenso negato di default. In locale non parte
nulla verso terzi.

Se vuoi vedere il banner, avvia con un ID finto:

```bash
NUXT_PUBLIC_GA_MEASUREMENT_ID=G-TEST ./scripts/dev.sh --build
```

Il banner **non compare** sulle rotte del colloquio, né su participants/login nel
backoffice: lì gli analytics non girano proprio, e un dialog sui cookie sopra la
valutazione di una persona sarebbe la cosa sbagliata nel posto sbagliato.

---

## 7. Test

Girano fuori da Docker e servono il toolchain locale (PHP 8.5, Bun, Node 24).

```bash
# API — 1320 test
cd api && php -d memory_limit=4G vendor/bin/pest
cd api && ./vendor/bin/phpstan analyse --memory-limit=1G

# Frontend — 464 unit + 105 E2E
cd frontend && bunx vitest run
cd frontend && bunx playwright test

# Backoffice — 250 unit + 69 E2E
cd backoffice && bunx vitest run
cd backoffice && bunx playwright test
```

> **Trappola vera**: Playwright riusa un server già in ascolto sulla 3000/3001.
> Se ne hai avviato uno a mano — o se gira il container — i test girano contro
> *quello*, senza le variabili d'ambiente che Playwright inietta, e fallirebbero
> per motivi che non c'entrano col codice. Ferma tutto prima.

> Se un build Nuxt fallisce con `Invalid or unexpected token`, non è il codice:
> è `node_modules` corrotto. `rm -rf node_modules && bun install` risolve.
> Il solo `bun install` non basta.

---

## 8. Problemi frequenti

| Sintomo | Causa | Rimedio |
|---|---|---|
| `db:seed` → `Call to undefined function fake()` | immagine vecchia | `docker compose build api` |
| `db:seed` → catalogo non trovato | `docs/` non visibile nel container | rifai il `docker cp` di §3.1 |
| `api` non parte, errore su mount | file sharing Docker | rimuovi il mount, o abilita il path |
| Backoffice mostra 401 | JWT scaduto | rifai il login |
| Docker si impianta | backend bloccato | `pkill -f 'Docker Desktop'; pkill -f com.docker.backend; open -a Docker` |

---

## 8.1 Vercel: disattivato di proposito

Il deploy target è **Railway**. Una GitHub App di Vercel era collegata a questo
wrapper e creava un deployment Production a ogni merge su `main` — in pratica
innocuo, perché qui non c'è applicazione da servire, ma è comunque una
violazione di una regola vincolante.

`vercel.json` con `git.deploymentEnabled: false` lo spegne dal repository.
Il file è lì per **impedire** i deploy su Vercel, non per configurarli.

Per rimuoverlo del tutto serve scollegare l'integrazione dalla dashboard Vercel:
questo file la neutralizza, non la disinstalla.

## 9. Stato del prodotto

14 slice verticali (C1→C14). **Tutte consegnate.**

C14 ha anche chiuso due difetti che erano già in produzione: il candidato vedeva
un iframe del fornitore dentro la pagina del colloquio, e le sessioni Tavus non
raggiungevano mai il completamento — quindi non venivano mai valutate.

Resta un solo task bloccante in tutto il progetto: le **durate di retention
GDPR**. Serve un legale, non altro codice — il meccanismo è costruito perché
ratificarle sia un cambio di configurazione, non di codice.

Due cose rinviate per scelta, scritte in `openspec/changes/avatar-provider-templates/tasks.md`:
nessun override del template per progetto (i progetti hanno già `language`,
quindi un solo avatar per organizzazione potrebbe stare stretto a chi intervista
in due lingue), e gli id avatar/voce non sono validati contro l'inventario reale
del fornitore.

Le tre lacune emerse scrivendo questa guida, tutte reali e nessuna bloccante per
provare il prodotto:

1. **Nessuna superficie per creare un'organizzazione** — né API né UI. Oggi ci
   pensa `DemoSeeder`.
2. **Il catalogo framework non è raggiungibile dal container** — path relativo al
   wrapper, ora scavalcabile con `FRAMEWORK_CATALOG_PATH`.
3. **Il colloquio end-to-end richiede credenziali di provider** che nessuno ha
   ancora messo in un ambiente.
