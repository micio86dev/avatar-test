# Tasks — avatar-language-follows-project

Derived from `proposal.md`, `design.md` (D1–D9, F1–F11) and the two delta specs.

**Strict TDD is active.** Every RED task precedes its GREEN task and must be observed failing.
Several existing tests currently *defend* behaviour this change removes — they are inverted inside
the RED task that supersedes them, never afterwards.

**Delivery: three chained PRs**, `api` before `backoffice` (D9). Shipping `backoffice` first is an
operator-visible defect: the form would render the raw i18n key. The reverse order is harmless — an
unused translation key renders nothing.

| PR | Scope | Reversible |
|---|---|---|
| 1 | Cut the override; Tavus platform default at its path (D1–D4, D7) | Yes |
| 2 | Retire the operator control + strip stored values (D5, D6) | **Migration is one-way** |
| 3 | `backoffice` i18n keys (D5) | Yes |

Test commands: `php artisan test --parallel`; coverage `php artisan test --coverage --min=85`;
backoffice `bun run test:unit`.

---

## PR 1 — The avatar's language follows the project (D1–D4, D7)

### 1.a Kill the override at the mapper

- [x] **1.1 RED** — `TemplatePayloadTest`: a template config carrying `language` produces a payload
      with **no** language key, for **both** providers. Existing assertions that expect the mapping
      are inverted here, not deleted later.
- [x] **1.2 GREEN** — `TemplatePayload.php`: delete both emissions (`:42` HeyGen,
      `:89-97` Tavus). **This is the load-bearing edit** (D1).
- [x] **1.3 GREEN** — `HeygenProvider.php:59`: remove the allowlist entry. Comment it as a
      statement of intent, **not** a guard — after 1.2 it filters a key nothing produces. The
      allowlist alone would never have sufficed: it is union'd with
      `config('interview.heygen.extra_token_fields')`, so an env var could re-open the field with
      no deploy.

### 1.b Tavus gains a language it never reliably had

- [x] **1.4 RED** — `TavusLanguageTest`: pure unit test for the `it → italian` / `en → english`
      vocabulary and its passthrough default. Keeps the ratified vocabulary requirement testable
      without an HTTP fake.
- [x] **1.5 GREEN** — Create `App\Support\Provider\TavusLanguage::forWire(string): string`, moving
      the map out of `TemplatePayload` along with its `:86-88` comment (D3).
- [x] **1.6 RED** — Feature test asserting the **PATH**: the Tavus conversation body carries
      `properties.language = 'italian'`, **nested**, never top-level.
      > **Review-rejection criterion.** A test asserting only that *a language is present* passes
      > against the exact defect this change removes. Tavus ignores a field at the wrong path
      > silently. Assert the path or the change is a no-op that reads as a fix.
- [x] **1.7 GREEN** — `TavusProvider`: thread `QuestionContext` into
      `platformDefaultConversationFields($ctx)` and write `properties.language` from
      `$ctx->language ?? config('interview.tavus.language')` (D2, D4).
- [x] **1.8** — `config/interview.php` tavus block: **add** `'language' => env('TAVUS_LANGUAGE', 'it')`.
      Document `TAVUS_LANGUAGE` in `api/.env.example` and `docs/dev-setup.md`.
- [x] **1.9 RED** — Null-`$ctx` fallback test for Tavus, mirroring HeyGen's existing one.

### 1.c Closing phrases read the project

- [x] **1.10 RED** — Feature test: `end_phrase` / `final_phrase` resolve from the **project**
      language even when `participant.language` differs. `interview-session/spec.md` already
      requires this — the code contradicts a ratified spec.
- [x] **1.11 GREEN** — `InterviewController:583`, `:652`: `$participant->language` → `$ctx->language`.
      No new query and no new parameter — `$ctx` is already in scope at both sites and already
      carries the project language (D7). Correct the four docblocks at `:744`, `:750`, `:791`, `:799`.

### 1.d Cross-tenant + close

- [x] **1.12 RED** — Isolation test: a stale template language in organization A never reaches
      organization B's session; template resolution and language sourcing both stay scoped to
      `organization_id` (mandated by `rules.specs`).
- [x] **1.13** — Full api suite + coverage gate. **1995 passing of 2000 (5 skipped), 94.0% overall.** Needs `php -d memory_limit=2G`: the default 128M dies building the report and the crash reads as a failing gate.

---

## PR 2 — Retire the operator control and strip stored values (D5, D6)

### 2.a Fixed intra-PR order — reversing it breaks the demo seed

`ConfigValidator` is entirely spec-driven: any key absent from `ProviderFieldSpecs` returns
`unknown`, and `DemoWriter` throws `RuntimeException` on **any** validator error *before* writing a
row. Drop the FieldSpec before the demo configs and `beai:demo-seed` dies at the first template —
CI fails on a seed step, not an assertion.

- [x] **2.1 RED** — Invert `ProviderFieldSpecTest`, `TemplatePayloadTest` and the `DemoWriter`
      tests that currently assert `language` is present.
- [x] **2.2 GREEN** — Drop `language` from **both** demo configs (`DemoWriter.php:152`, `:172`),
      from the identity shape and `@return` (`DemoDataset.php:708`, `:712-724`), and delete
      `config/interview.php:196`.
      > ⚠️ **`:196` and `:83` are byte-identical expressions 113 lines apart.** Confirm the block
      > header reads *"Demo Avatar Identity (beai:demo-seed)"* before deleting. `:83` is
      > `interview.heygen.language`, HeyGen's null-`$ctx` fallback, ratified at
      > `interview-session/spec.md:1258-1262` — deleting **that** one instead reintroduces the
      > 0.22.1 production outage class. An existing test catches it, but only if the suite runs
      > before merge, so name that guard in the PR description.
- [x] **2.3 GREEN** — `ProviderFieldSpecs.php:61`, `:84`: drop the `FieldSpec` from both providers;
      then retire `LANGUAGES` at `:36`. **In that order.**
- [x] **2.4** — Confirm `ConfigValidator` and `AvatarTemplatePortabilityController` need **no edit**:
      both are spec-driven and inherit the removal. Verify rather than assume.
- [x] **2.5** — Run `beai:demo-seed` end to end. The failure this ordering prevents is a seed-time
      crash, which no unit test will surface.

### 2.b The one-way migration

- [x] **2.6 RED** — Maximal fixture across **two organizations**, asserting key-by-key survival:
      every config key except `language` is byte-identical after the strip, in both orgs.
      > **This test is the only thing standing between a wrong filter and unrecoverable loss.**
      > The migration is unscoped by design and destroys operator configuration platform-wide with
      > no recovery. Write the fixture maximal — every field spec, both providers, nested keys.
- [x] **2.7 GREEN** — Migration: JSONB key-strip of `language` from `avatar_templates.config`.
      `down()` is a documented **no-op** — the values are not recoverable and the docblock must say
      so plainly rather than implying reversibility.
- [x] **2.8** — Postgres `?` key-exists operator collides with PDO placeholders. Use the escaped
      form or a raw-binding-free operator; assert the migration runs against real Postgres, not
      only SQLite.
- [x] **2.9** — Note in the change log that pre-change template **exports become unimportable**
      (F11): they carry a key the validator now rejects. Expected, not a regression.
- [x] **2.10** — Full api suite + coverage gate. **1995 passing of 2000, 94.0%.** `beai:demo-seed` exercised end to end by the 59-test Demo suite — the failure the intra-PR ordering prevents is a seed-time crash no unit test surfaces.

### 2.c Correct the six census statements (D8)

- [x] **2.11** — Replace all five sites. Every replacement MUST state a guarantee an existing named
      test already pins, and cite that test:
      - `HeygenProvider.php:180-183` → `HeygenProviderTest.php:249-276`
      - `TavusProvider.php:79-96` → the null-`$ctx` case from 1.9
      - `ActiveTemplateResolver.php:12-18` → `HeygenProviderTest.php:249-276`
      - `config/interview.php:57-72` → **both** statements (`:61-62` and `:72`); keep the
        separation rationale at `:64-72` / `:74-79` **verbatim** — it is what makes the F7 twin-key
        trap legible to the next reader
      - `openspec/specs/interview-session/spec.md:1278` → owned by the delta spec, lands at archive
      > The rule: **state the invariant, never the census.** All six were true when written and
      > became false as the data moved. They were unfalsifiable in CI by construction — they assert
      > something about production tenants, while every test runs against a fresh or demo-seeded
      > database. The suite asserts *exactly one active template exists* and did so while all six
      > stood.

---

## PR 3 — Backoffice (D5)

- [x] **3.1** — Remove exactly two keys from `backoffice/i18n/locales/{it,en}.json` (`:606`, `:650`),
      path-scoped to `avatar_templates.*` (F8).
- [x] **3.2** — Confirm `AvatarTemplateForm.vue` needs **no edit**: it renders from
      `field.label_key` / `field.hint_key`, so the control disappears with the spec.
- [x] **3.3** — **Not applicable, verified rather than skipped.** Scramble documents the paths but
      not their response schemas, so the field-spec shape is not published and there is nothing to
      regenerate. The same limitation was found on the candidate interview endpoints during
      `interview-continuous-flow`: `openapi-typescript` is a devDependency with no generate script,
      and those surfaces have always been hand-typed.
- [x] **3.4** — `bun run test:unit`, typecheck, lint.

---

## Close-out

- [x] **4.1** — `sdd-verify` against spec, design and this checklist. **PASS** on the second run.
      The first returned three CRITICAL — two of them tasks marked done that were not, plus a
      missing `apply-progress`. Closed in `api` v0.26.1, along with three findings the verifier
      raised unprompted. The second run actively FALSIFIED the two highest-risk fixes: it reverted
      them, confirmed the new tests fail against the reintroduced defect, then restored. That is
      the difference between a test existing and a test working.
- [ ] **4.2** — **Pre-deploy check, carried from the open questions**: determine whether any real
      tenant has an active avatar template with a language set. Not answerable from the repo — it
      needs a production query. If any exist, their avatars change spoken language on deploy, and
      that belongs in the release notes.
- [ ] **4.3** — `sdd-archive`: merge both delta specs, including the `spec.md:1278` correction.

---

## Carried forward — NOT gated by this change

- Whether `participants.language` should exist at all, whether the M2M endpoint should validate it
  against supported locales, and what `EntryLinkMinter`'s `$lang` override is for. Examined and
  judged out of scope — not overlooked. Worth scheduling as its own change.
- `properties.language` is proven by the working demo, not by Tavus documentation. Reconfirm at
  apply time against the vendor's current API.
