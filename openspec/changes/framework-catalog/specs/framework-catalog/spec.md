# Framework Catalog Specification

## Purpose

Defines the queryable, versioned, translatable, tenant-pinnable data layer
for BEAI's binding domain catalog: 5 roles, 18 standard competencies, and
per-role BARS indicators with reference anchors {5, 3, 1}. C4 pins a
framework version per project; C9 reads anchors to score. C3 stores and
serves — it does NOT evaluate.

---

## Requirements

### Requirement: Global Base Catalog Schema

The system MUST provide three GLOBAL (non-tenant-scoped) tables — `roles`,
`competencies`, and `bars_indicators` — that together represent the binding
domain catalog. None of these tables SHALL carry an `organization_id` column.

`roles` MUST record: code (ICO/FLL/MLL/BUL/SRX), translatable name,
translatable responsibilities. `competencies` MUST record: code (PRS…INC),
translatable name, translatable definition. `bars_indicators` MUST record:
role_code, competency_code, display order, translatable indicator text, and
three translatable anchor text fields for scores 5, 3, 1.

Migrations MUST be reversible (`down()` restores pre-C3 schema) and follow
D22 conventions (3NF, indexed).

#### Scenario: Global tables carry no organization_id

- GIVEN the `roles`, `competencies`, and `bars_indicators` migrations
- WHEN the schema is inspected
- THEN none of those tables has an `organization_id` column
- AND each table has the required code and translatable columns

#### Scenario: BarsIndicator stores anchors at three fixed levels

- GIVEN a BarsIndicator row for ICO × PRS
- WHEN the record is read
- THEN it carries non-null anchor text for levels 5, 3, and 1
- AND the indicator text field is non-null

---

### Requirement: Tenant-Scoped FrameworkVersion Pin

The system MUST provide a `framework_versions` table that extends the C2
`TenantModel` pattern, scoped per organization via `organization_id`. The
table MUST record: `organization_id`, a catalog `version` identifier, a
`label`, timestamps, and a soft-delete or immutability guard.

The composite index on `framework_versions` MUST lead with `organization_id`
(per D22 multi-tenancy convention).

A `FrameworkVersion` record MUST become immutable once it is referenced by
any downstream record (project → framework_version_id, set by C4). The system
MUST NOT permit deletion or mutation of a referenced `FrameworkVersion`.

C4 wires the project → `framework_version_id` FK; C9 reads anchor text via
that FK. These are downstream concerns and are OUT OF SCOPE for C3.

#### Scenario: Two organizations pin different framework versions

- GIVEN organization A has pinned framework version "v1"
- AND organization B has pinned framework version "v2"
- WHEN org A's framework version is fetched
- THEN it returns version "v1"
- AND fetching org B's framework version returns "v2"
- AND no cross-org data leaks

#### Scenario: FrameworkVersion composite index leads with organization_id

- GIVEN the `framework_versions` migration
- WHEN the index definitions are inspected
- THEN the primary lookup index starts with `organization_id`

#### Scenario: A referenced FrameworkVersion cannot be deleted

- GIVEN a FrameworkVersion record that C4 has associated with a project
- WHEN a delete is attempted on that FrameworkVersion
- THEN the delete is rejected (constraint or guard)
- AND the FrameworkVersion record remains intact

---

### Requirement: Translatable Content Columns

The system MUST store role names, role responsibilities, competency names,
competency definitions, BARS indicator text, and all three anchor texts as
translatable JSON columns supporting at minimum `it` and `en` locales, using
`spatie/laravel-translatable`. Adding further locales (es, fr, de, pt) MUST
require no schema migration.

When a locale is requested and that locale's translation exists, the system
MUST return it. When the requested locale is missing for a field, the system
MUST fall back to `en` and MUST flag the gap (e.g. via a response metadata
field or log entry). The system MUST NOT return null or an empty string when
the `en` fallback is present.

#### Scenario: Requesting EN locale returns EN content

- GIVEN a Competency with EN name "Problem Solving"
- WHEN the competency is fetched with locale=en
- THEN the name field is "Problem Solving"

#### Scenario: Requesting IT locale when IT translation is absent falls back to EN

- GIVEN a BarsIndicator whose anchor_5 has EN text but no IT text
- WHEN the indicator is fetched with locale=it
- THEN anchor_5 returns the EN text (fallback)
- AND the response or log indicates a translation gap for that field

#### Scenario: Requesting IT locale when IT translation exists returns IT

- GIVEN a Competency with both IT and EN names populated
- WHEN the competency is fetched with locale=it
- THEN the name field returns the IT value

---

### Requirement: Idempotent Catalog Seeder

The system MUST provide a `FrameworkCatalogSeeder` that seeds the global
catalog from the split-file JSON shape (`competencies.json` + `bars/{ROLE}.json`).
The seeder MUST be idempotent: running it N times MUST produce the same
database state as running it once. Duplicate rows MUST NOT be created.

The seeder MUST use natural-key upserts (role code, competency code,
role×competency×indicator position).

The seeder MUST gracefully skip a missing BARS file and MUST log or record
a structured gap entry flagging the missing data. It MUST NOT throw an
exception or halt for a missing file. After skipping, the affected role's
competency records MUST still be seeded (from `competencies.json`) if present.

The seeder MUST tolerate a future unified competency object shape (where
competency metadata and BARS anchors are co-located) without requiring code
changes to the split-file path.

#### Scenario: First run seeds roles and competencies from JSON

- GIVEN the JSON files competencies.json and bars/ICO.json are present
- WHEN the FrameworkCatalogSeeder runs for the first time
- THEN roles and competencies matching the JSON are present in the DB
- AND ICO BARS indicators are present with correct anchor text

#### Scenario: Second run produces no duplicates (idempotency)

- GIVEN the seeder has already run once
- WHEN the seeder runs again without any data change
- THEN the row counts for roles, competencies, and bars_indicators are identical
- AND no duplicate rows exist

#### Scenario: Missing bars/SRX.json is skipped gracefully

- GIVEN bars/SRX.json does not exist on disk
- WHEN the FrameworkCatalogSeeder runs
- THEN the seeder does NOT throw an exception
- AND SRX role metadata (name) is still seeded from roles.json
- AND a gap entry is recorded flagging "SRX BARS indicators missing"
- AND bars_indicators contains zero rows for SRX

#### Scenario: MTG/LAT absent — potential catalog flagged incomplete

- GIVEN neither competencies.json nor any bars file defines MTG or LAT
- WHEN the FrameworkCatalogSeeder runs
- THEN no MTG or LAT rows are created
- AND a gap entry is recorded flagging "MTG/LAT competencies absent — potential assessment type incomplete"
- AND the seeder completes successfully

#### Scenario: BUL BARS file seeds only present competencies

- GIVEN bars/BUL.json defines BARS for a subset of BUL's competencies
- WHEN the FrameworkCatalogSeeder runs
- THEN bars_indicators rows are created only for competencies present in bars/BUL.json
- AND a gap entry is recorded for each BUL competency listed in roles.json but absent from bars/BUL.json

#### Scenario: Re-seeding after correcting a gap adds the missing rows

- GIVEN bars/SRX.json was absent on the first seed run
- AND bars/SRX.json is subsequently authored and placed on disk
- WHEN the seeder runs again
- THEN SRX BARS indicators are inserted
- AND no existing rows are duplicated

---

### Requirement: Read-Only Org-Scoped Framework API

The system MUST expose read-only HTTP endpoints (behind `auth:api` middleware
from C2) that serve the framework catalog in the context of the requesting
organization's pinned `FrameworkVersion`. The endpoints MUST be:

- `GET /api/framework/roles` — list all roles for the org's pinned version
- `GET /api/framework/roles/{roleCode}/competencies` — list competencies for a role
- `GET /api/framework/competencies/{competencyCode}/bars` — BARS indicators and anchors for a competency in a role context

All responses MUST be locale-aware: a `Accept-Language` or `?locale=` parameter
MUST select the translation; missing translations MUST fall back to `en`.
The API MUST NOT expose another organization's framework data.

#### Scenario: Org A user lists roles and sees their pinned version's data

- GIVEN user in Org A is authenticated (auth:api)
- AND Org A has a pinned FrameworkVersion
- WHEN GET /api/framework/roles is called
- THEN the response lists only roles valid under Org A's pinned version
- AND Org B data is NOT present in the response

#### Scenario: Cross-tenant isolation — Org B cannot access Org A's framework data

- GIVEN user in Org B is authenticated
- WHEN GET /api/framework/roles is called with Org A's organization_id injected
- THEN the response reflects only Org B's pinned framework data
- AND no Org A data leaks

#### Scenario: Requesting competency BARS returns indicators with anchors

- GIVEN role ICO and competency PRS have seeded BARS indicators
- WHEN GET /api/framework/competencies/PRS/bars is called with roleCode=ICO
- THEN the response contains each indicator's text and anchor text for levels 5, 3, 1

#### Scenario: Locale-aware response falls back to EN when IT is absent

- GIVEN a BARS indicator with EN anchor text and no IT anchor text
- WHEN the endpoint is called with locale=it
- THEN the response returns the EN anchor text for that field
- AND the response signals the translation gap (e.g. metadata flag)

---

### Requirement: Split-File and Unified-Shape Adapter Tolerance

The seeder MUST read the current split-file shape without requiring a flag or
configuration switch. The seeder adapter MUST also accept a future unified
competency object shape (where a single JSON entry carries both competency
metadata and its BARS indicators). When the unified shape is detected, the
seeder MUST parse it correctly and produce the same DB state as the split-file
path would for the same data.

#### Scenario: Split-file shape produces correct DB state

- GIVEN competencies.json and bars/ICO.json are present in split-file format
- WHEN the seeder runs
- THEN roles, competencies, and bars_indicators are populated correctly

#### Scenario: Unified shape produces the same DB state

- GIVEN a unified competency object (competency metadata + BARS co-located)
- WHEN the seeder adapter processes it
- THEN the resulting roles, competencies, and bars_indicators match what split-file seeding would produce

---

### Requirement: Data-Gap Authoring Requirements (Tracked, Not Fabricated)

The following domain data MUST NOT be invented or approximated by C3. Each
gap MUST be recorded as an explicit authoring task and surfaced (via seeder
gap log, README note, or migration comment) so the team knows what client or
expert input is required:

- `bars/SRX.json` — BARS indicators for Senior Executive role (missing file)
- MTG and LAT competency definitions and anchors — required for `potential` assessment type
- IT locale translations for all names, definitions, and anchor texts — gates non-EN scoring in C9
- BUL BARS gaps — competencies listed in roles.json but absent from bars/BUL.json

The system MUST remain queryable (returning partial data) while gaps persist.
A partial catalog MUST NOT cause API errors or seeder failures.

#### Scenario: API responds correctly with partial catalog

- GIVEN the catalog is in a partial state (SRX BARS absent, MTG/LAT absent)
- WHEN GET /api/framework/roles is called
- THEN the response lists all 5 roles including SRX
- AND SRX competencies are listed (from roles.json)
- AND no 500 error or exception is raised

#### Scenario: Gap log is inspectable after seeder run

- GIVEN the seeder has run with known gaps (SRX.json missing, MTG/LAT absent)
- WHEN the seeder gap log or report is inspected
- THEN it lists each gap with a human-readable description
- AND each gap has a status of "pending authoring"

---

## Non-Goals (Explicit)

The following are OUT OF SCOPE for C3 and MUST NOT be implemented here:

- **Scoring engine** — LLM invocation, indicator scoring, competency mean calculation (C9)
- **Project → framework_version FK and pin-at-creation** — C4 wires this FK after C3 creates the `framework_versions` table
- **Per-org BARS overrides or customization** — future additive capability; C3 base is global and immutable
- **MTG/LAT scoring flow** — blocked pending authoring; flagged but not implemented
- **Inventing missing domain data** — SRX BARS, MTG/LAT defs, IT translations are client/expert artifacts; C3 records the gap only
