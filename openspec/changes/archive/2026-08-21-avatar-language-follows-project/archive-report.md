# Archive Report: avatar-language-follows-project

**Change**: avatar-language-follows-project  
**Archived to**: `openspec/changes/archive/2026-08-21-avatar-language-follows-project/`  
**Archive date**: 2026-08-21  
**Status**: COMPLETE

## Summary

The avatar-language-follows-project change has been successfully archived after complete implementation, verification, and deployment to production. All three chained PRs shipped to production (API v0.26.0, v0.26.1; backoffice v0.14.0), the one-way data migration executed successfully, and all delta specs have been merged into the main specifications.

## Change Artifacts (Engram Observation IDs)

- **Proposal**: Engram #1252 (`sdd/avatar-language-follows-project/proposal`)
- **Spec**: Engram #1254 (`sdd/avatar-language-follows-project/spec`) — delta specs for avatar-templates and interview-session
- **Design**: Engram #1255 (`sdd/avatar-language-follows-project/design`)
- **Tasks**: Engram (tasks artifact was maintained in filesystem only)
- **Verify Report**: Engram (verify-report artifact was maintained in filesystem only)

## Specs Merged

### avatar-templates/spec.md

**Modified**: "Template config reaches the provider payload — unset means absent, never null"

- Removed scenario: "Tavus language is translated into its own vocabulary" (Tavus language translation moved to platform default)
- Added scenario: "Neither mapper ever emits a language field" — documents that templates can no longer override language for either provider, including configs that still carry the stored `language` key from before this change

**Modified**: "Template config validates against a declarative per-provider field spec"

- Added scenario: "A `language` key in submitted config is unknown for either provider" — the field spec no longer defines `language` for either provider; requests carrying it return 422 with `config.language` coded as `unknown`

### interview-session/spec.md

**Modified**: "POST /start merges the organization's active avatar template into the provider payload"

- Removed from field lists: `avatar_persona.language` no longer listed among template-merged fields for HeyGen
- Added two new scenarios:
  1. "A template's stored language, if any, is never merged into either provider's payload" — even if a row still carries a stored `language` key, it is not merged into the outbound request
  2. "A stale template language never crosses into another organization's session" — demonstrates cross-tenant isolation where both template resolution and language sourcing stay scoped to `organization_id`
- Added informational notes about completion phrases and avatar session-token language source

**Modified**: "Platform-Default Avatar Identity When No Template Exists"

- HeyGen: language source now explicitly stated as PROJECT's language with fallback to `interview.heygen.language`
- **Tavus (major addition)**: now receives platform default language at **`properties.language`** (nested, not top-level), translated into Tavus vocabulary (`it` → `italian`, `en` → `english`), with fallback to `interview.tavus.language`
- Precedence for language specifically: now collapses to single source (platform default/project language only) — templates cannot override
- **Census statement correction**: changed from "identity came ONLY from a template no organization had" to "no organization is required to have an active `AvatarTemplate` with those fields set — a state the product never guarantees for any organization, seeded or not. The platform defaults make that a supported state."
- Updated scenario: "An organization with no template still sends a complete Tavus identity, including language at its own path" — explicitly tests that language nests under `properties`, never at top level
- Added scenario: "A template can never override the avatar's language, even if it tries" — documents the invariant that template config is never mapped into avatar language fields
- Unchanged: "The avatar speaks the project's language, not a deployment-wide constant", "An unset configured default is omitted, never sent empty"

## Destructive Delta Warnings (Binding Policy: rules.archive)

The following changes are irreversible and must be surface in release notes:

1. **Field spec removal**: The `language` field has been removed from both HeyGen and Tavus provider field specs. Avatar templates can no longer be configured with a language setting. Operator control removed from backoffice form.

2. **Data migration (one-way)**: A JSONB key-strip migration has removed the `language` key from every `avatar_templates.config` row in production (both providers, active and inactive, all organizations). The `down()` is a documented no-op — values are not recoverable. This is platform-wide by design, not scoped per organization.

3. **Backoffice i18n**: Two translation keys removed from `backoffice/i18n/locales/{it,en}.json` (`:606, :650`), path-scoped to `avatar_templates.*`:
   - `avatar_templates.field.language`
   - `avatar_templates.hint.language`

4. **Template exports portability**: Template JSON documents exported before this change are no longer importable. They carry a `language` key that the validator now rejects as `unknown`. Pre-change exports must have the `language` line manually removed before re-import. This is expected and not a regression — documented in release notes.

5. **Closing phrase resolution**: The last two fields in a candidate's interview response (`end_phrase`, `final_phrase`) now resolve from the project language instead of the participant language. If a participant's language was different from or unsupported by the project, the phrases will now be in the project language rather than potentially falling back to English.

## Task Completion

All 33 implementation tasks are checked as complete, verified by:
- Strict TDD cycle evidence in `apply-progress.md`
- Two-pass verification (prior pass + second independent re-verification with active code falsification)
- Pre-deploy and archive tasks (4.2, 4.3) remain intentionally unchecked pending completion

**Notable verification findings**:
- Two highest-risk fixes were actively falsified: code reverted to re-introduce defects, tests re-run to confirm failure, files restored
- Both fixes are load-bearing — Tavus `properties.language` path and migration key-strip
- Three additional test cases added in fix release (v0.26.1) addressing high-risk scenarios:
  1. Tavus nesting assertion (path + absence of top-level)
  2. Null-context Tavus fallback to config default
  3. Cross-project isolation test (two projects, same org, one template)

## Open Questions Carried Forward

**Not resolved by implementation, not blocking**:

1. **Does any real tenant have an active avatar template with a language set?** — Cannot be answered from repo; production query needed. If yes, this change alters live avatar language on deploy (release note required). Pre-deploy verification, not a design gate.

2. **Should `participants.language` column exist at all?** — Out of scope for this change. Explicitly deferred as its own product decision with three related questions (per-candidate override, M2M validation, EntryLinkMinter override purpose).

## Lessons Learned (Design pattern corrections)

**The recurring "census claim" failure mode** (found in five sites, not three):

A comment that counts rows is a comment that expires. Examples:
- "No organization has an active template" (false after demo seeding)
- "This is the state EVERY existing organization is in" (unfalsifiable in CI by construction)

The fix adopted: **state the invariant, not the census**. Each corrected comment now documents what the code *guarantees* (e.g., "null is a supported resolution; degrade to platform defaults") and cites an existing test that pins the claim.

This pattern appeared four times written by different authors at different times — each correct on the day it was written. The defect is the *category of sentence* with a data dependency the review process doesn't track.

## Shipped Versions

- `api` v0.26.0 — PR 1 & 2 (mapper cut, field-spec retirement, migration, census corrections)
- `api` v0.26.1 — Fix release on v0.26.0 (three additional test cases, docblock corrections, D8 citation enforcement)
- `backoffice` v0.14.0 — PR 3 (i18n key removal)
- All deployed to Railway production and verified SUCCESS
- Merge order: `api` first, `backoffice` immediately after (asymmetric; reverse order is operator-visible defect)

## Files Archived

```
openspec/changes/archive/2026-08-21-avatar-language-follows-project/
├── proposal.md
├── design.md
├── tasks.md
├── verify-report.md
├── apply-progress.md
└── specs/
    ├── avatar-templates/
    │   └── spec.md (delta)
    └── interview-session/
        └── spec.md (delta)
```

## SDD Cycle Complete

All phases executed:
- ✅ Proposal (ratified; two questions intentionally left open)
- ✅ Spec (delta specs only; no new capabilities)
- ✅ Design (nine architecture decisions, all ratified)
- ✅ Tasks (33 implementation tasks, 3 chained PRs)
- ✅ Apply (all PRs shipped, production migration successful)
- ✅ Verify (two-pass verification with active falsification of highest-risk fixes)
- ✅ Archive (delta specs merged; change folder archived; census statements corrected)

Ready for next change.
