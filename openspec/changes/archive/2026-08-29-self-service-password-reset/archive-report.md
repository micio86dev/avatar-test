# Archive Report — self-service-password-reset

**Archived**: 2026-08-29 · **Store mode**: `hybrid` · **Verdict inherited**: PASS WITH
WARNINGS — archivable as-is (0 CRITICAL) · **Archive class**: intentional-with-warnings.

**Destination folder**: `openspec/changes/archive/2026-08-29-self-service-password-reset/`
— **the move was NOT performed by `sdd-archive`.** The owner runs the `git mv` themselves so
git history is preserved across the rename. Everything else in this report is done.

## Artifact traceability

| Artifact | Engram | On disk |
|---|---|---|
| proposal | **#1686** `sdd/self-service-password-reset/proposal` | `proposal.md` |
| spec (4 deltas) | **#1696** `sdd/self-service-password-reset/spec` | `specs/{password-recovery,identity-auth,admin-backoffice,observability}/spec.md` |
| design | **none — by decision** | **absent by decision** |
| tasks | **#1698** `sdd/self-service-password-reset/tasks` | `tasks.md` |
| verify-report | **#1704** `sdd/self-service-password-reset/verify-report` | `verify-report.md` (transcribed at archive) |
| archive-report | `sdd/self-service-password-reset/archive-report` | this file |

**On the missing `design.md`.** This is a *stated decision*, not an omission, and it was NOT
backfilled. `proposal.md`'s **AD-1…AD-8** carry the design load and are cited by file-level
docblocks in the shipped code (`ForgotPasswordController`, `SendPasswordResetLinkJob`,
`routes/api.php`, `02.auth.global.ts`). A `design.md` written now would be a third document
derived from the same code, adding no independent constraint. Recorded here so a future reader
does not mistake the absence for a lost file.

## Task ledger reconciliation

Archive-time reconciliation was **explicitly authorised by the orchestrator** and is backed by
`verify-report` evidence, per the Strict-vs-OpenSpec archive policy.

**37/41 → 40/41.** Flipped: **0.4**, **3.8**, **4.8**. Closed in the P6 register: **6.4**
(runbook — re-read at archive and confirmed correct), **6.5** (executed by this archive).

**0.3 stays open permanently and says so in the file.** `api` commit `9632dbf` is one squashed
commit bundling this change with session excerpts and the deploy command, so red-before-green
is unprovable from history. The consequence is recorded on the same line: **the proposal's
per-slice P1→P4 rollback plan does not exist in the commit graph either** — there is no commit
to revert that yields "P1 only". Rollback is a full revert or nothing.

**6.1, 6.2, 6.3, 6.6, 6.7 remain open**, each now carrying an explicit "Carried forward to"
pointer. **6.8 was added** at archive to record the pre-existing E2E failure that was seen and
deliberately not absorbed.

**Both verification WARNINGs were already fixed** on `api` `develop` commit `520b66b` before
archive (three ghost `foreach` assertions made real; the deactivated-refusal assertion added
and proved by mutation). They are NOT re-reported as open.

## Specs synced

| Capability | Action | Detail |
|---|---|---|
| `password-recovery` | Updated | 9 ADDED requirements merged. `## Purpose` rewritten, `## Non-Goals` restructured, `## Superseded Non-Goals` and `## Open Decisions` added. |
| `identity-auth` | Updated | 1 MODIFIED requirement replaced, 1 ADDED requirement appended, 1 adjacent requirement annotated. |
| `admin-backoffice` | Updated | 1 MODIFIED requirement replaced, 3 ADDED requirements appended, 1 unrelated requirement restructured, 1 carried-forward requirement added. |
| `observability` | Updated | 2 ADDED requirements appended, 1 pre-existing requirement corrected. |

### The merge was not mechanical — what had to be restructured, and why

A blind append would have left four source-of-truth specs asserting both the superseded rule
and the new one. In three of the four capabilities the superseded behaviour was **not** under a
matching heading; it was buried in prose belonging to a *different* requirement, or in a
Non-Goal, or in a Purpose sentence.

**1. `password-recovery` — Purpose sentence (RESTRUCTURED).**
Opened *"Command-line only — this is not an HTTP-facing recovery flow."* No delta touched it,
because no delta could: it is not a requirement. Left alone, the capability's first paragraph
would have flatly denied the nine requirements appended below it. Rewritten to describe both
paths and to state why the CLI is **not** redundant — deleting it converts a degraded
dependency (mail is down) into a total one. The old sentence is quoted in place.

**2. `password-recovery` — four Non-Goals (OVERTURNED / SUPERSEDED, recorded in a table).**
AD-1 named one. Reading the section properly found **four**:

| Non-Goal | Disposition |
|---|---|
| *"Self-service email reset … Deferred until mail is configured…"* | **OVERTURNED** — this is **D2 of `archive/2026-08-18-admin-password-reset`**, reversed by AD-1. Recorded, not deleted silently. |
| *"Reset-token table, backoffice UI trigger, or any `--password=`-style option"* | **SPLIT.** The first two shipped. The `--password=` clause is still binding and was preserved into the surviving Non-Goals list. Dropping the bullet whole would have quietly repealed a live constraint on the CLI. |
| *"Rate limiting … belongs to `nfr-hardening` if a future email flow needs it"* | **SUPERSEDED** by the throttle requirement. Ownership did **not** pass to `nfr-hardening`; recorded explicitly, because a stale routing note is how a control ends up owned by nobody. |
| *"Non-admin roles for a future email flow"* | **OVERTURNED BY OMISSION.** The shipped flow applies no role check at all, so this was never a constraint in code. Carried forward as **OD-1** rather than quietly retired. |

**3. `admin-backoffice` — "Password Field Autofill Hygiene" (RESTRUCTURED).**
The buried conflict this merge existed to catch. It read: *"No form embedding a password-type
control … MAY carry an `autocomplete="username"` anchor ahead of it"*, with `login.vue` named
as *"the only exception"*. Verified against the shipped code rather than assumed:
`reset-password/[[token]].vue:63` carries `autocomplete="username"` on the email input, ahead
of two `autocomplete="new-password"` controls, and `forgot-password.vue:17` carries `username`
too. **Read literally, the shipped recovery pages violate that requirement.**

The requirement's own stated rationale, however, is about not teaching a password manager to
save an **organization's** webhook secret into an operator's personal vault
(`WebhookDefaultsForm`/`ProjectForm`). On the recovery pages the credential is the operator's
**own**, so the manager offer is correct behaviour, not a leak. The rule was over-broad; the
pages are right. Narrowed to scope-by-whose-credential, with the three pre-auth
operator-credential surfaces tabulated, and the old wording quoted in a `(Previously: …)` note.
No delta mentioned this — it would have shipped as a silent, knowing spec violation.

**4. `observability` — "Microsoft Clarity" (CORRECTED, pre-existing drift).**
Its scenario asserted the snippet *"is loaded on every page in both apps"*, which the new
*Session Replay Never Runs On A Recovery Page* requirement directly contradicts. Checking
`backoffice/app/utils/analytics-path.ts:38-39` showed the claim was **already wrong before this
change**: `participants` and `login` have been on the replay-unsafe list since the utility was
written. This change added `forgot-password` and `reset-password` to the same list and is the
*occasion* for the correction, not its cause — stated that way in the note. The two
requirements now cross-reference one shared implementation, and the new requirement enumerates
the complete unsafe set so they cannot drift.

**5. `identity-auth` — "Logout (Denylist)" (ANNOTATED, not changed).**
Said sign-out-everywhere *"is a SEPARATE capability, out of scope here"*. Still true of
logout's behaviour, but the user-scoped primitive `RefreshTokenStore::revokeAllForUser` now
exists, so a reader could infer it does not. Annotated to name the primitive **and** to state
that logout MUST NOT start calling it. No behaviour changed.

### Clean merges (no restructuring needed)

- `identity-auth` → *Out-of-Session Password Reset Invalidates Prior Sessions* — MODIFIED
  matched an existing heading exactly; full-block replacement, 2 scenarios preserved verbatim,
  4 added.
- `admin-backoffice` → *Authenticated Session* — MODIFIED matched exactly; the guard-predicate
  paragraph, the second `(Previously…)` note, and 2 scenarios were inserted without disturbing
  the boot-refresh contract.

### Nothing was dropped

No requirement was deleted from any main spec. Four Non-Goals were retired, all four recorded
in a table with what overturned them. Requirements not named in a delta were preserved
unchanged, apart from the two corrections above, each carrying its own `(Previously: …)` record.

## Carried-forward items and where each now lives

None of these is duplicated into an entry that already existed.

| Item | Durable home |
|---|---|
| **No role check anywhere in the flow** (proposal Q1 never answered; every active user incl. superadmins can self-serve) | `specs/password-recovery/spec.md` → **OD-1**. Also records the implementation constraint: it cannot go on the request leg without reopening the timing oracle. |
| **Per-email rate cap deliberately not shipped** (Q4 / AD-7; `throttle:6,1` on IP, reasoning in `routes/api.php`) | `specs/password-recovery/spec.md` → the shipped-deviation blockquote on the throttle requirement, plus **OD-2** as a pointer only, so the two cannot drift. |
| **The flow is inert in production**; ship gate is `beai:mail-selftest` green on both `api` and `worker` | `specs/password-recovery/spec.md` → **OD-3**, and `docs/deploy.md` → *Recovering a Locked-Out User*. Owner's step; no engineering task closes it. |
| **Q2/Q3/Q5/Q6 shipped on unratified assumptions** | `specs/password-recovery/spec.md` → **OD-4**, a four-row table naming the shipped answer and its file. |
| **Pre-existing `/unsupported` axe `document-title` failure** — NOT this change | `openspec/ROADMAP.md` → Carried-forward risk **R-5**, and `specs/admin-backoffice/spec.md` → *The `/unsupported` Page Carries A Document Title* (**STATUS: OPEN**), following the R-1/R-4 owner-spec precedent. **Needs its own change.** |
| **PUBLIC_PATHS proposal constraint broken by deviation** (6.6) | `specs/admin-backoffice/spec.md` → *Authenticated Session*, second `(Previously…)` note. |

## Files written by this archive

- `openspec/specs/password-recovery/spec.md`
- `openspec/specs/identity-auth/spec.md`
- `openspec/specs/admin-backoffice/spec.md`
- `openspec/specs/observability/spec.md`
- `openspec/ROADMAP.md`
- `openspec/changes/self-service-password-reset/tasks.md`
- `openspec/changes/self-service-password-reset/verify-report.md`
- `openspec/changes/self-service-password-reset/archive-report.md`

**No implementation code was modified. Nothing was committed. The folder was not moved.**

## Risks

1. **The change is archived but not enabled.** The flow is inert in production and closing that
   is an owner action (OD-3). An archived change reads as "done"; this one is done *and*
   switched off.
2. **OD-1 is a live authorization question resting on an unmade decision**, not on a considered
   "yes". It is now visible in the owning spec rather than in a closed folder.
3. **R-5 leaves `bun run test:e2e` exiting 1 on a clean `backoffice` tree.** Same failure mode
   as R-4: a red unrelated to the diff trains a reader to dismiss red.
4. **`sentry-scrub.ts` at 83.49%** is the lowest-covered touched file (verify suggestion 3).
   The delegation path this change depends on is covered; the rest is not.
5. **The `git mv` is outstanding** and is the owner's step. Until it runs,
   `openspec/changes/self-service-password-reset/` still reads as an active change while its
   specs are already merged into the source of truth.
