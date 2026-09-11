# Conversation Prompt Templates Specification

## Purpose

Platform-level, revision-immutable, locale-keyed storage for the system-prompt template
sections `SystemPromptComposer` renders (Layer 1 — global) and per-role×competency prompt
overrides appended into the composed prompt (Layer 2). This capability governs storage,
resolution, activation, and the placeholder contract; composition itself belongs to
`interview-conversation`.

## Non-Goals

- Backoffice authoring UI (deferred to a later slice)
- Per-organization templates (deferred; platform-level/superadmin only in this change)
- REPLACE override mode (deferred; APPEND only)
- `api/lang/{en,it}/interview.php` content (different composer, different change)

## Requirements

### Requirement: Global Template Sections, Keyed by Revision and Locale

The system MUST store one global template section per (revision, section_key, locale)
combination, covering every section `SystemPromptComposer` renders. A revision MUST group a
complete, coherent set of sections across locales.

#### Scenario: A section is resolvable by revision + key + locale

- GIVEN an active revision R with a `star` section body for locale `it`
- WHEN the resolver looks up (R, `star`, `it`)
- THEN the stored body is returned verbatim

#### Scenario: Two locales of the same revision coexist independently

- GIVEN revision R has both `en` and `it` bodies for section `budget`
- WHEN each locale is resolved independently
- THEN each returns its own body; neither overwrites the other

---

### Requirement: Per-Role×Competency Prompt Override

The system MUST support at most one override body per (revision, role, competency, locale),
with role OPTIONAL — a null role scopes the override to the competency across every role. The
uniqueness constraint over (revision, role, competency, locale) MUST mirror the shape of
`framework_bars_indicators`' unique key.

#### Scenario: A role-specific override does not apply to a different role

- GIVEN an override exists for (revision R, role FLL, competency INN, locale en)
- WHEN resolution runs for (R, role MLL, competency INN, en)
- THEN no override is found

#### Scenario: A competency-wide override (null role) applies to every role

- GIVEN an override exists for (revision R, role = null, competency INN, locale en)
- WHEN resolution runs for any role, competency INN, R, en
- THEN that override body is returned

#### Scenario: A competency with no override resolves to none

- GIVEN no override row exists for (R, role, competency, locale)
- WHEN resolution runs
- THEN no override body is returned; only the default section set is available to compose

---

### Requirement: Revision Immutability and Single Active Revision

A revision, once ANY interview has composed against it, MUST NOT be mutated. Publishing new
text MUST create a new revision, never edit an existing one. Exactly ONE revision (per locale
set) MUST be marked active at any time; activation MUST record who activated it and when. An
edit — a new revision plus activation — MUST NOT alter any already-composed or already-scored
interview's stamped prompt.

#### Scenario: An already-referenced revision cannot be edited

- GIVEN revision R has been composed into at least one interview
- WHEN an edit to any of R's section bodies is attempted
- THEN the edit is rejected; a new revision must be created instead

#### Scenario: Exactly one active revision at a time

- GIVEN revision R1 is active
- WHEN revision R2 is activated
- THEN R2 becomes active and R1 is no longer active; never both simultaneously

#### Scenario: Activation records who and when

- GIVEN an operator activates revision R2
- WHEN the activation is inspected
- THEN it records the acting user and a timestamp

#### Scenario: Activating a new revision does not retarget past compositions

- GIVEN an interview was composed against revision R1, then R2 is activated
- WHEN R1's stamped prompt is reconstructed
- THEN it is byte-identical to what was composed at the time, unaffected by R2's activation

---

### Requirement: Placeholder Contract Enforced at Save Time

The system MUST refuse to save an `advance_*` section body that omits any of its required
placeholders (the advance-phrase token and the minimum-questions token). This save-time check
is a load-bearing substitute for the code-review gate that DB-driven prompts remove — not
defensive, since seeders and raw SQL bypass it (see `interview-conversation`'s
composition-time refusal for that case).

#### Scenario: Saving an advance_* body missing a required placeholder is refused

- GIVEN a new `advance_with_phrase` body missing its advance-phrase placeholder
- WHEN the save is attempted
- THEN it is refused; no row is persisted

#### Scenario: A body carrying all required placeholders saves successfully

- GIVEN an `advance_with_phrase` body containing both required placeholders
- WHEN the save is attempted
- THEN it succeeds

---

### Requirement: Seeder Idempotency Over Immutable Revisions

Re-running the seeder MUST NOT duplicate a revision it already created, and MUST NOT mutate
any revision that any interview has already composed against.

#### Scenario: Re-seeding does not duplicate the seeded revision

- GIVEN the seeder has run once and created revision R
- WHEN the seeder runs again
- THEN no second copy of R is created; row counts are unchanged

#### Scenario: Re-seeding never mutates a referenced revision

- GIVEN revision R has been composed into at least one interview
- WHEN the seeder runs again with different source text for R's sections
- THEN R's stored bodies remain byte-for-byte unchanged
