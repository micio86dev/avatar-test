# Verify Report: webhooks-integration (C10)

Phase: `sdd-verify` (re-verification). Fresh, independent, adversarial verification of
PR8's claimed fixes — this pass did NOT implement any of PR1-PR8 and took nothing on
trust: every claim below was reproduced with fresh commands, and both mutation-test
guarantees were re-applied by hand in this session.

Verified: 2026-07-28 (re-verification pass).

## Verdict: **PASS** — 0 CRITICAL, 0 WARNING, 0 SUGGESTION

All three findings from the previous pass (1 CRITICAL, 2 WARNING) are genuinely closed.
The CRITICAL was closed correctly — by fixing the spec's prose, not by bending the code
to satisfy an impossible domain model. Both WARNINGs were closed with real,
mutation-verified discriminating tests, not soft/self-reported fixes. All quality gates
are green on both submodules, reproduced fresh in this session.

---

## Previous pass (summary — for full detail see git history of this file / Engram
revision history of `sdd/webhooks-integration/verify-report`)

The prior independent verify pass (also 2026-07-28, earlier in the day) found:

- **CRITICAL C1**: the spec scenario "Advancement progress payload reflects cumulative
  state" (`specs/webhooks-integration/spec.md:294-298`, old wording) required a
  competency to show **2 `answers` entries**, which is structurally impossible under the
  C7a domain model (one `interview_sessions` row = one competency, `question_index` is a
  static ordinal, never a per-question counter). `ProgressPayloadAssembler` can only
  emit 0 or 1 entries per competency, and its existing test only ever asserted that.
  Flagged as a pre-existing spec-authoring defect (missed by `tasks.md`'s own Δ1-Δ5
  reconciliation), not a C10 coding defect.
- **WARNING W1**: the "the exact transmitted body is what was signed" HTTP-boundary test
  (`DeliverWebhookJobTest.php:246-279` — same test, prior line range 218-251) had a
  fixture (`c10PendingDelivery()`) with zero slashes and zero non-ASCII bytes, so
  `json_encode($p)` and `json_encode($p, JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)`
  were byte-identical for that specific payload. Mutating `DeliverWebhookJob.php` to the
  explicitly forbidden `->post($url, $delivery->payload)` shape left all 67 C10 feature
  tests passing — the guarantee was unproven at the wiring level (the unit-level
  `WebhookSignerTest.php` still caught it in isolation).
- **WARNING W2**: dead-letter terminal idempotency (`if ($delivery->status !== Pending)
  return;`) was tested only from `Delivered` status, never from `Dead` specifically.

PR8 (commit `037ee95` on `api`, branch `feat/c10-pr8-verify-fixes` off
`feat/c10-pr6-progress-seams`) claimed to close all three: C1 by correcting the spec
prose (no code change — the implementation and its existing test were already correct
against the real domain model), W1 by enriching the fixture with a realistic
slash-bearing URL and a non-ASCII (`è`) excerpt, W2 by adding a `Dead`-status variant of
the terminal-row idempotency test. This pass re-verifies each of those three claims
independently, plus re-checks the wider chain since the whole PR1-PR8 sequence was in
scope.

---

## 1. Per-Finding Table

| Finding | Closed? | Evidence (this pass, reproduced fresh) |
|---|---|---|
| C1 — impossible spec scenario | **YES** | `specs/webhooks-integration/spec.md:279-317` now states 0-or-1 `answers` entries per competency, with an explicit new paragraph declaring per-question tracking out of scope for C10. `ProgressPayloadAssembler.php:62-77` still appends at most one `answers` entry per competency row (unchanged, correct all along). `ProgressPayloadAssemblerTest.php:106-124` still asserts `toHaveCount(1)` for the ended competency — the existing test already satisfied the corrected spec. No code was bent to satisfy old prose; the spec was fixed, not the domain model. |
| W1 — signature/body test lacked discriminating power | **YES** | Reproduced the exact prior mutation myself: `DeliverWebhookJob.php:141-142` changed from `->withBody($rawBody,'application/json')->post($delivery->target_url)` to `->post($delivery->target_url, $delivery->payload)`. `./vendor/bin/pest tests/Feature/C10` → **67/68 pass, exactly 1 failure**, at `DeliverWebhookJobTest.php:270` ("the exact transmitted body is what was signed"), with mismatched HMAC hex (`cbf17574...` expected vs `0c6f4f3b...` actual — see full transcript below). Restored `DeliverWebhookJob.php`, confirmed `diff` empty and `git status --short` clean, re-ran → 68/68 green. |
| W2 — dead-letter idempotency untested from `Dead` | **YES** | `DeliverWebhookJobTest.php:313-335` now has "terminal-row idempotency guard: a re-executed already-DEAD row is also a no-op". Mutated the guard myself: `DeliverWebhookJob.php:101` changed from `if ($delivery->status !== WebhookDeliveryStatus::Pending)` to `if ($delivery->status === WebhookDeliveryStatus::Delivered)`. Result: the new `Dead`-row test **failed with a genuine `SQLSTATE[23514]` CHECK constraint violation** (`webhook_deliveries_attempt_count_max_check`), proving the `Dead` row was actually re-processed. Restored, `diff` empty, re-ran → 68/68 green. |

---

## 2. Verbatim Gate Output — api submodule (`feat/c10-pr8-verify-fixes`, tip `037ee95`)

**Full Pest suite:**
```
{"tool":"pest","result":"passed","tests":1067,"passed":1064,"assertions":2303,"duration_ms":67371,"skipped":3}
```
(3 skips pre-existing, unrelated to C10 — matches PR8's claim; +1 test / +1 assertion
vs. the previous pass's 1066/1063, accounting for the new W2 Dead-row test.)

**PHPStan (2G memory limit):**
```
{"tool":"phpstan","result":"passed","errors":0}
```
(develop baseline is 0 — no new errors introduced.)

**Pint, scoped to the 51 files changed in `develop..feat/c10-pr8-verify-fixes`:**
```
{"tool":"pint","result":"passed"}
```

**Aggregate repo-wide coverage (`php -d memory_limit=2G ./vendor/bin/pest --coverage`) —
Success Criterion 7, single number:**
```
Total: 94.4 %
```
Unchanged from the previous pass (only a test file and the wrapper-repo spec changed;
no new production lines were added). All C10 correctness-critical files remain at
100.0%: `WebhookSigner`, `SecretRedactor`, `RetryClassifier`, `WebhookDeliveryRecorder`,
`DeliverWebhookJob`, `EvaluationPayloadAssembler`, `ProgressPayloadAssembler`, all
`Events` and `Listeners`.

## 2b. Verbatim Gate Output — frontend submodule (`feat/c10-pr7-exit-redirect`, tip `07c5a00`, unchanged since previous pass)

**`bunx nuxi prepare` then `bun run typecheck`:** exit 0 (verified via explicit `echo
"EXIT: $?"` capture — not inferred from absence of error text). Only pre-existing
cosmetic shadcn-vue duplicate-component-name warnings, unrelated to C10.

**`bun run test:unit`:**
```
Test Files  22 passed (22)
     Tests  339 passed (339)
```

No frontend code changed between the previous pass and this one (PR7 tip is the same
commit, `07c5a00`); E2E was not re-run this pass since nothing in the frontend submodule
changed and the previous pass already reproduced 69/69 fresh.

---

## 3. Mutation-Test Transcripts (this pass, performed independently)

### W1 — signature/body coupling

**Mutation applied** (`app/Jobs/DeliverWebhookJob.php:141-142`):
```diff
-                ->withBody($rawBody, 'application/json')
-                ->post($delivery->target_url);
+                ->post($delivery->target_url, $delivery->payload);
```

**Result:**
```
{"tool":"pest","result":"failed","tests":68,"passed":67,"assertions":238,"duration_ms":8021,"failed":1,
 "failures":[{"test":"...the_exact_transmitted_body_is_what_was_signed...",
 "file":"tests/Feature/C10/DeliverWebhookJobTest.php","line":270,
 "message":"Failed asserting that two strings are identical.\n--- Expected\n+++ Actual\n@@ @@\n-'cbf175745694e56be271c73c9b18688b4e22a87b4f03eaf9242767e94383b4e8'\n+'0c6f4f3b17bc66b1c9aebe4ebdaa4a2039b6b597c6aafb22b1b268dabced2b75'"}]}
```

**Restore verification:**
```
$ diff DeliverWebhookJob.php.orig app/Jobs/DeliverWebhookJob.php ; echo "diff exit: $?"
diff exit: 0
$ git status --short app/Jobs/DeliverWebhookJob.php
(empty)
$ ./vendor/bin/pest tests/Feature/C10
{"tool":"pest","result":"passed","tests":68,"passed":68,"assertions":239,"duration_ms":6552}
```

### W2 — dead-letter idempotency

**Mutation applied** (`app/Jobs/DeliverWebhookJob.php:101`):
```diff
-        if ($delivery->status !== WebhookDeliveryStatus::Pending) {
+        if ($delivery->status === WebhookDeliveryStatus::Delivered) {
```

**Result:**
```
{"tool":"pest","result":"failed","tests":68,"passed":67,"assertions":235,"duration_ms":7499,"errors":1,
 "error_details":[{"test":"...terminal_row_idempotency_guard__a_re_executed_already_DEAD_row_is_also_a_no_op",
 "file":"vendor/laravel/framework/.../Connection.php","line":626,
 "message":"SQLSTATE[23514]: Check violation: 7 ERROR:  new row for relation \"webhook_deliveries\" violates check constraint \"webhook_deliveries_attempt_count_max_check\"\nDETAIL: ...\"attempt_count\" = 7..."}]}
```
A real database CHECK-constraint violation, not a soft assertion mismatch — proves the
`Dead` row was genuinely re-processed (attempt_count incremented past the max) once the
guard no longer covered that status.

**Restore verification:**
```
$ diff DeliverWebhookJob.php.orig2 app/Jobs/DeliverWebhookJob.php ; echo "diff exit: $?"
diff exit: 0
$ git status --short app/Jobs/DeliverWebhookJob.php
(empty)
$ ./vendor/bin/pest tests/Feature/C10
{"tool":"pest","result":"passed","tests":68,"passed":68,"assertions":239,"duration_ms":7134}
```

---

## 4. Re-checked chain items (whole PR1-PR8 chain in scope)

Since `git diff --stat feat/c10-pr6-progress-seams..feat/c10-pr8-verify-fixes` shows
**only `tests/Feature/C10/DeliverWebhookJobTest.php` changed** (54 insertions, 1
deletion) in the `api` submodule between the previous pass's reviewed tip and this
pass's tip — no other production code changed — the following items, already deep-dive
verified by the previous pass against unchanged code, were spot-re-confirmed rather than
re-derived from scratch:

- **Delivery state machine (4 branches, distinguishable `skip_reason`)**: unchanged code
  (`WebhookDeliveryRecorder.php:143-162`); not re-read this pass beyond confirming no
  diff touched it.
- **Retry classification boundaries**: unchanged (`RetryClassifier.php:26-54`); not
  re-mutated this pass (already mutation-verified by the previous pass on identical
  code).
- **Emission-on-rollback / SSO raw-SQL atomicity**: re-diffed independently this pass —
  `git diff develop..feat/c10-pr8-verify-fixes -- app/Http/Controllers/Sso/SsoExchangeController.php`
  shows exactly 2 additive hunks (an `$isNewCandidate` capture before the upsert, an
  `event(new ParticipantCreated(...))` call after the reload+null-check) and **zero**
  characters changed inside the raw-SQL upsert block. No `DB::transaction` was
  introduced or removed. Confirmed NOT weakened.
- **Tenancy / arch guard**: unchanged code; `tests/Fixtures/ArchGuardFixtures/Jobs/Nested/NonCompliantNestedJob.php`
  confirmed still present (`fd`), and `QueuedJobTenantContextArchTest.php:120-135`'s
  proof test (which directly asserts the fixture is caught via `toContain`, and that
  compliant/non-job fixtures are NOT flagged) passed in the full suite run above —
  genuinely discriminating by construction, not merely present.
- **Secret non-leakage (row/log/response/exception)**: unchanged code and unchanged
  tests; all 4 surfaces still exercised per the previous pass's citations
  (`WebhookDeliveryTenancyTest.php`, `DeliverWebhookJobTest.php`,
  `ProjectWebhookEventsTest.php`).
- **D8 frontend target**: `frontend` submodule unchanged since the previous pass (same
  tip `07c5a00`). Re-confirmed `git diff develop..feat/c10-pr7-exit-redirect --
  app/pages/interview/done.vue` is **empty** — `done.vue` remains untouched. The real
  implementation target is the inline `done` branch in `[token].vue`, per the 8-file
  diff stat (`done.vue` absent from it).

No regressions or scope changes were found in any re-checked item.

---

## 5. Task Completeness

All PR0-PR8 tasks previously verified `[x]` remain genuinely complete; PR8 adds no new
task-tracked scope beyond the fix batch itself (a test-quality hardening + a spec
correction), both confirmed above. "Open PR N" tasks remain correctly unchecked (no
push, no PR opened this pass either).

---

## 6. Issues

### CRITICAL

None.

### WARNING

None.

### SUGGESTION

None. Both submodules are clean, all gates are green, and the fix batch demonstrates the
correct discipline (mutation-verify a claimed fix before trusting it) that the original
verify pass was testing for.

---

## 7. Submodule State (restored exactly as found)

**api**: started on `feat/c11-a3-controllers`, checked out `feat/c10-pr8-verify-fixes`
for review, restored to `feat/c11-a3-controllers`. Final `git status --short`: (empty,
clean).

**frontend**: started on `fix/brand-token-shadowing`, checked out
`feat/c10-pr7-exit-redirect` for review, restored to `fix/brand-token-shadowing`. Final
`git status --short`: (empty, clean).

Both submodules match the wrapper's `git submodule status` recorded pointers; no
commits, stashes, or uncommitted changes were left behind by this verification session.

---

## 8. Recommendation

C10 (`webhooks-integration`) is ready for `sdd-archive`: all findings from the previous
verify pass are genuinely closed with independently-reproduced evidence, all quality
gates are green on both submodules, and no new issues were found in the re-checked
chain.
