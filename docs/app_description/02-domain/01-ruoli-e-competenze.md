# Ruoli e competenze

## Framework di riferimento

Il dominio BEAI si basa su un framework di **ruoli organizzativi** e **competenze trasversali** (soft skill). Ogni ruolo ha un set predefinito di competenze da valutare.

I file strutturati completi sono in `framework/`:
- `framework/roles.json` — ruoli e competenze associate
- `framework/competencies.json` — definizioni delle competenze
- `framework/bars/*.json` — scale comportamentali (BARS) per ruolo

## Ruoli organizzativi

| Codice | Nome | Focus |
|--------|------|-------|
| **ICO** | Individual Contributor | Esecuzione task, focus breve termine, nessuna responsabilità manageriale diretta |
| **FLL** | Front Line Leader | Coordinamento operativo, unità funzionale singola, costi operativi |
| **MLL** | Mid-Level Leader | Allineamento strategico paese/area, 1–2 funzioni correlate |
| **BUL** | Business Unit Leader | Strategia paese/regione, P&L completo, funzioni multiple |
| **SRX** | Senior Executive | Direzione strategica pluriennale (3-5 anni), organizzazione/regione multi-paese, P&L consolidato |

## Competenze standard

| Codice | Nome |
|--------|------|
| PRS | Problem Solving |
| STG | Strategy |
| INN | Innovation |
| JDG | Judgment |
| DRV | Drive |
| CSF | Customer Focus |
| SLF | Sales Focus |
| OPX | Operational Excellence |
| TMG | Team Management |
| INS | Inspiring Others |
| COM | Communication |
| COL | Collaboration |
| INF | Influence |
| NET | Networking |
| RES | Resilience |
| LRN | Learning |
| ITG | Integrity |
| INC | Inclusion |

## Matrice ruolo → competenze

| Ruolo | N. competenze | Note |
|-------|---------------|------|
| ICO | 15 | Senza JDG, TMG, INS |
| FLL | 18 | Set completo leader di prima linea |
| MLL | 18 | Come FLL |
| BUL | 14 | Senza SLF, COM, ITG, INC |
| SRX | 18 | Set ampio executive |

Dettaglio esatto per codice: `framework/roles.json`.

## Competenze aggiuntive (solo assessment Potential)

| Codice | Nome | Disponibilità |
|--------|------|---------------|
| MTG | Managing | Solo tipo Potential |
| LAT | Leadership Attributes | Solo tipo Potential |

Vedi `03-tipi-assessment.md`.

## Scale BARS (Behaviorally Anchored Rating Scales)

Per ogni competenza e ruolo, la valutazione confronta le risposte del candidato con **indicatori comportamentali** a scala 1–5.

Ogni indicatore ha ancore testuali per i livelli (es. 1 = insufficiente, 3 = adeguato, 5 = eccellente).

Esempio (estratto ICO / PRS):

| Indicatore | Livello 5 | Livello 3 | Livello 1 |
|------------|-----------|-----------|-----------|
| Recognizes symptoms that indicate problems | Utilizza sintomi e pattern come indizi delle cause profonde | Riconosce sintomi e differenzia problemi da sintomi | Si concentra sui sintomi superficiali |

**Copertura BARS.** Tutte le 83 coppie ruolo×competenza dichiarate in `roles.json` hanno ancore
comportamentali (5/3/1) — 249 indicatori, 747 testi di ancoraggio, su ICO/FLL/MLL/BUL/SRX. La copertura
è completata da `bars-catalogue-completion`: `bars/SRX.json` (18 competenze, 54 indicatori) è l'ultimo
file arrivato, insieme al completamento delle 26 coppie residue di FLL/MLL/BUL. I due file di controllo
CI — `scripts/framework-known-gaps.txt` (ruoli senza alcun file BARS) e
`scripts/framework-competency-gaps.txt` (coppie ruolo×competenza senza ancore) — sono entrambi vuoti oggi
e restano il meccanismo di verifica per qualunque lacuna futura, mantenuti esatti in entrambe le
direzioni dallo step (d) di `.github/workflows/wrapper-ci.yml`: una coppia scoperta e non elencata fa
fallire la CI, e un'esenzione la cui lacuna è stata colmata fa fallire la CI finché non viene rimossa.
I 132 indicatori (396 testi di ancoraggio) autorati da questo cambiamento sono una bozza calibrata in
attesa di validazione da parte di uno specialista di assessment prima di essere usati per valutare
candidati reali (vedi `openspec/specs/framework-catalog/spec.md`, requisito "Calibrated Draft Pending
Specialist Sign-Off").

## Regole di configurazione progetto

Alla creazione di un **Progetto**:
- si seleziona il **ruolo target**;
- si seleziona il **sottoinsieme di competenze** tra quelle ammesse per il ruolo e il tipo assessment;
- le competenze devono essere **coerenti** con ruolo e tipo (standard vs potential).

## Lingue

L'intervista e la valutazione devono supportare almeno:
- italiano (`it`)
- inglese (`en`)

Estendibile ad altre lingue europee (es. `es`, `fr`, `de`, `pt`) in base a requisiti commerciali.
