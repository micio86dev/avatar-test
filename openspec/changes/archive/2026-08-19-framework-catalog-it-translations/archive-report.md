# Archive Report: Italian Locale for the Framework Catalogue

**Change**: `framework-catalog-it-translations`  
**Archived**: 2026-08-19  
**Status**: Complete — Shipped and verified in production

---

## Executive Summary

The Italian locale for the framework catalogue has been fully implemented, deployed to production (api v0.20.0, v0.20.1, v0.21.0), and verified through live API calls. This archive report records the spec merges and marks the completion of the SDD cycle.

---

## Task Completion Gate — Reconciliation

**Gate Status**: ✅ PASSED with authorized reconciliation

The persisted `tasks.md` artifact contains unchecked implementation tasks (Phases 5-12, items 5.1-12.7) despite production deployment. Per the archive skill's exceptional reconciliation authority, these stale checkboxes are reconciled based on explicit production verification evidence provided by the orchestrator:

**Production Verification (Proof of Completion)**:
- API v0.20.0, v0.20.1, v0.21.0 deployed and live
- `GET /api/framework/roles/BUL/competencies` with `Accept-Language: it` returns `Problem solving | Strategia | Innovazione | Giudizio | Determinazione` (confirmed against `en` baseline: `Problem Solving | Strategy | Innovation | Judgment | Drive`)
- `GET /api/framework/roles` in Italian returns complete role list: `Contributore individuale | Responsabile di prima linea | Responsabile di livello intermedio | Responsabile di business unit | Dirigente senior`
- Database state: 249/249 indicators fully translated across all four fields (`text`, `anchor_5`, `anchor_3`, `anchor_1`), 18/18 competencies, 5/5 roles, catalog revision 4
- HTTP 422 `anchor_translation_missing` defect **closed**: Italian candidates now complete interviews end-to-end without hard-fail
- Remaining gaps (MTG/LAT competency definitions) are genuinely out of scope, not missing implementation
- All CI guards verified passing; no locale content entering unguarded

**Reconciliation Authority**: This archive report records the stale-checkbox reconciliation. The unchecked tasks represent completed work, verified in production. No further apply-phase remediation is required.

---

## Specs Synced

| Domain | Action | Changes |
|--------|--------|---------|
| `framework-catalog` | **Updated** | MODIFIED: Translatable Content Columns, Gap Row Reconciliation, Idempotent Catalog Seeder, Data-Gap Authoring Requirements<br/>ADDED: Locale Dimension (nested keys), Per-Locale Ceiling (measured), Italian Standard Precedence, Partial Coverage Control, Locale Merge Semantics<br/>EDITED: Non-Goals prose (IT translations no longer universally deferred) |
| `scoring-engine` | **Updated** | ADDED: Non-EN Anchor Language (L-2 Hard-Fail) with production scenarios |
| `interview-conversation` | **Updated** | MODIFIED: i18n Requirement (coverage note updated; real-catalogue scenarios added) |

### Spec Merge Details

#### `openspec/specs/framework-catalog/spec.md`

**MODIFIED Requirements** (6):
1. **Translatable Content Columns** — Extended seeder behavior to call `setTranslation(field, locale, value)` per locale in source JSON's nested map; added scenarios for IT translation handling and idempotency
2. **Gap Row Reconciliation on Seeded Content** — Expanded to cover `missing_translation` resolution at pair granularity (all 12 strings required); added scenarios for per-pair and global row reconciliation
3. **Idempotent Catalog Seeder** — Updated lock-guard signal description; added explicit requirement that suppression is never silent and that stale-checkbox recovery is inspectable; added scenario for locked-FV IT suppression signal
4. **Data-Gap Authoring Requirements** — Reversed the universal IT deferral; now tracks per-pair scope; MTG/LAT remain deferred, translated pairs do not
5. **Seeder lock-guard signal** — Must emit log/gap entry with `kind: seeder_lock_guard_active` when translation authoring exists but is suppressed by lock

**ADDED Requirements** (5 new blocks):
1. **Locale Dimension Uses Nested Keys** — Nested `{"en": "...", "it": "..."}` shape mandatory; sibling-file and filename-suffixed schemes rejected; all guards must verify Italian content via step-f self-test
2. **Per-Locale Anchor Length Ceiling** — Each locale has its own measured ceiling; ceiling must be calibrated from pilot sample, not inherited or guessed
3. **Italian Authoring Standard Precedes Content** — Standard document required before any Italian content PR; must specify form, register, deficit-verb inventory, orthography
4. **Partial IT-Coverage Control File** — New `scripts/framework-locale-gaps.txt` file enforced both directions; tracks role×competency pairs pending translation; empty once full scope ships
5. **Locale Merge Semantics** — `setTranslation` merges, never removes; removal requires explicit `forgetTranslation` operation; re-seeding after deletion leaves `it` in DB

**Non-Goals Prose Edit**:
Changed from: "…and IT locale translations (for the full catalogue, existing and newly authored anchors alike) remain client/expert artifacts"  
Changed to: "IT locale translations for translated role×competency pairs are catalogue content (handled by `framework-catalog-it-translations`), not client-deferred domain data"  
Rationale: Reflects shipped scope; MTG/LAT definitions remain deferred.

#### `openspec/specs/scoring-engine/spec.md`

**ADDED Requirement** (1):
1. **Non-EN Anchor Language (L-2 Hard-Fail)** — Hard-fail on missing `it` for any of {text, anchor_5, anchor_3, anchor_1}; never fallback to English; added scenarios for fully-translated role (real catalogue, ICO scope) and partial coverage (cross-role independence)

**Rationale**: Restates existing hard-fail behavior against real, partially-translated catalogue (not just fixtures). No behavior change; coverage extended from fixture-only to include production data.

#### `openspec/specs/interview-conversation/spec.md`

**MODIFIED Requirement** (1):
1. **i18n — Composed Prompt in Project Language** — Coverage note updated from "Italian translations do not exist" to "must exercise real seeded IT data for translated roles"; added scenarios for fully-translated role (HTTP 201, no 422) and partial coverage (untranslated role still hard-fails); clarified that hard-fail is per-project, not global

**Rationale**: Reflects that production now carries seeded Italian content for translated scope; compositions must verify against real data where available, fixtures remain for untranslated pairs.

---

## Archive Contents

All change artifacts moved to archive path:
```
openspec/changes/archive/2026-08-19-framework-catalog-it-translations/
├── proposal.md          ✅ (original proposal)
├── design.md            ✅ (design document)
├── tasks.md             ✅ (task checklist — reconciled per gate above)
├── specs/
│   ├── framework-catalog/spec.md      ✅ (delta, not merged here)
│   ├── scoring-engine/spec.md         ✅ (delta, not merged here)
│   └── interview-conversation/spec.md ✅ (delta, not merged here)
└── archive-report.md    ✅ (this report)
```

**Note**: Delta spec files in the change folder remain as shipped-at-time artifacts. Main specs have been updated in `openspec/specs/{domain}/spec.md`.

---

## Source of Truth Updated

The following main specs now reflect the new behavior and are authoritative:

1. **`openspec/specs/framework-catalog/spec.md`** — 5 ADDED requirements + 4 MODIFIED requirements + Non-Goals edit
2. **`openspec/specs/scoring-engine/spec.md`** — 1 ADDED requirement (Non-EN Anchor Language)
3. **`openspec/specs/interview-conversation/spec.md`** — 1 MODIFIED requirement (i18n coverage note + scenarios)

All deltas have been merged. Main specs are now the source of truth for ongoing development.

---

## SDD Cycle Complete

**Proposal** → **Spec** → **Design** → **Tasks** → **Apply** → **Verify** → **Archive** ✅

The change has been fully planned, designed, implemented (in production), verified (live API + database), and archived.

**Next change**: Ready for new SDD work. No follow-up dependencies.

---

## Lessons Recorded

Six significant learnings from this change are documented separately (per user request). They cover:

1. Test brittleness when data completeness changes (pattern: 8+ failing tests; fix: manufacture preconditions in fixtures, assert invariants)
2. Guard design gap — shape guards alone miss incomplete data (fix: `catalog_meta_locale_completeness` derives from config, not data presence)
3. Gap row denominator misunderstanding — gaps counted per-occurrence, not per-scope (fix: note boolean status, not row count)
4. Word-count ceiling calibration — measured before fixed (Italian p90 ratio yields 26-word ceiling)
5. Cross-locale fidelity — hedge defects inherited faithfully, not improved (two locales must score identically; divergence is regression)
6. Locked FV semantics — fill-empty-locale exception is PRIMARY path, not edge case (projects locked at v0 would fail without it)

All lessons recorded in memory for next locale translation work.

---

## Archive Integrity

✅ **No CRITICAL verification issues** — Change is safe to archive.  
✅ **All main specs updated** — Deltas merged cleanly.  
✅ **Tasks reconciled** — Stale checkboxes explained by production proof.  
✅ **Non-Goals clarified** — Prose edited to reflect shipped scope.  
✅ **Archive folder created** — All artifacts in place.

**Status**: ARCHIVED — Ready for deployment context reset and next change.
