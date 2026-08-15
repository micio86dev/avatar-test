# Proposal: Generated-Client Truth and Session Safety

## Intent

A census of every "known issue carried forward" across today's archives, re-verified against code, found three defects that matter and a process hole that hid one of them.

1. **Ten resources mistype the public contract.** `/** @var X $y */ $y = $this->resource;` is a LOCAL assignment; Scramble ignores it and defaults every field to `string` for a field it cannot otherwise infer. Affected: `Admin/{Organization,ParticipantDetail,Participant,User}Resource`, `{BarsIndicator,Competency,FrameworkVersion,Participant,Project,Role}Resource`. An earlier audit recorded five and cleared `Admin/UserResource` and `FrameworkVersionResource` — **that audit was wrong**. Damage is live in `backoffice/types/api.ts`: `id: string`, `status: string`, `role_code: string`, translatable fields typed `unknown[]` — Scramble's default for a field whose only static hint is an `array` cast it cannot resolve to an item type, not the bare `string` default (**corrected here**: an earlier draft of this document claimed `string`; `git show HEAD:types/api.ts` — the pre-change committed snapshot — confirms `unknown[]`, e.g. `RoleResource.name: unknown[]`).
2. **CI cannot see this class of drift.** `wrapper-ci.yml` diffs the three committed `openapi.json` copies against *each other*, never against a fresh export. Stale-but-consistent is invisible — that is how the above and a `ProfileResource.locale` staleness survived.
3. **Admin password reset leaves sessions alive.** `Api/UserController.php:120` updates the password without touching `password_changed_at`, so `RejectStaleCredentials` never retires the target's tokens. The self-service path (`ProfileController:90`) does. The one case where revocation matters most — an admin resetting a compromised account — is the one case that fails.

Plus two visible smaller ones and test noise that makes green runs less trustworthy in a session that has repeatedly caught green suites certifying broken code.

## Scope

### In Scope

| # | Deliverable | Evidence |
|---|---|---|
| 1 | `@scramble-return` shapes on the ten resources; re-export; regenerate all three clients | precedent: `ApiClientResource:45`, `AvatarTemplateResource:35` — declarative, zero runtime change |
| 2 | Regeneration gate in CI so this cannot recur | see Approach |
| 3 | `password_changed_at` set on admin password reset (`update()`, and `store()` for symmetry) | `UserController.php:120`, `:77` |
| 4 | `ApiKeysPanel.vue:308` reads the pagination envelope, not `response.data` | `paginate(20)`; demo seeder adds 3 keys |
| 5 | Quiet the noise: assertion on `TenancyTest`'s first test (`->throwsNoExceptions()` risky flag); stabilise or quarantine-with-reason `unsupported-gate.spec.ts:78`, `autocomplete-hygiene.spec.ts:132` (webkit), `ProvisionOrganizationCommandTest` | a flaky gate is a gate nobody trusts |

### Out of Scope — with reasons

- **SRX BARS indicators and Italian anchor translations** — expert data authoring, not code. `FrameworkCatalogSeeder` already records them as gaps.
- **`nfr-hardening`'s last task** — blocked on legal sign-off for retention durations.
- **The `--filter` fabrication** — observed once, never reproduced across two later probes.
- **The one-second `password_changed_at`/`iat` window** — inherent to `iat` being second-precision.
- **`KNOWN_DESTRUCTIVE_METHODS` as a one-entry allowlist; the date guard's blind spots** — documented ceilings of file-level guards, not defects.
- The four in-flight changes (`nfr-hardening`, `avatar-provider-templates`, `interview-error-redirect`, `org-provisioning`) are untouched.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ci-pipeline`: "API CI Job" gains a committed-vs-freshly-generated `openapi.json` gate; "Wrapper Cross-Stack CI" states explicitly that mutual equality is not freshness.
- `admin-read-api`: "Scramble Documentation Parity" — a resource's exported schema MUST reflect real field types, not the inferred `string` default.
- `user-management`: an admin-initiated password change MUST invalidate the target's existing sessions.
- `admin-backoffice`: the API-key table MUST show every key, not the first page.

## Approach

**Position on the CI question — gate on fresh regeneration, and it is nearly free.** The framing that it needs a Laravel container in a file-diffing job is wrong: `api/.github/workflows/ci.yml:114` **already runs** `php artisan scramble:export`, in a job that already provisions PHP and Postgres, and then only asserts the file exists (`:117`) and that `info.version` matches `VERSION` (`:125`) — a check that compares a generated field against its own source. The export already overwrites the committed `api/openapi.json`. So the gate is one step:

```
git diff --exit-code openapi.json   # after scramble:export
```

Zero new infrastructure, zero added minutes. The wrapper job keeps doing what it is good at — proving the three copies agree — and the API job proves the `api` copy is true. Without this, findings 1 and the `locale` staleness recur; that is not a prediction, it is what already happened twice.

Everything else is small and local: declarative annotations, one assignment in `update()`, one envelope read in Vue.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Http/Resources/**` (10 files) | Modified | `@return` + `@scramble-return` shapes |
| `api/.github/workflows/ci.yml` | Modified | `git diff --exit-code openapi.json` after export |
| `.github/workflows/wrapper-ci.yml` | Modified | comment/doc: equality ≠ freshness |
| `api/app/Http/Controllers/Api/UserController.php` | Modified | set `password_changed_at` on admin password write |
| `{api,frontend,backoffice}/openapi.json`, `*/types/api.ts` | Regenerated | consequence of 1 |
| `backoffice/app/components/organisms/ApiKeysPanel.vue` | Modified | paginate/envelope |
| `api/tests/Feature/Demo/TenancyTest.php`, 2 Playwright specs | Modified | assertion + flake |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Regenerated types break backoffice compile — types get *more* precise (`string` → `int`, object) | **High, and intended** | TS type-check surfaces every call site; fix them in the same change. This is the defect becoming visible, not a regression |
| Scramble export is non-deterministic across runs, making the new gate flaky | Med | Verify determinism (two consecutive local exports) before enabling; if unstable, compare canonicalised JSON as the wrapper job already does |
| Killing sessions on admin reset logs out a legitimately-reset user | Low | That is the requirement, not a side effect |

## Rollback Plan

Independent per deliverable. Revert the resource annotations and re-run `scramble:export` + client codegen to restore the previous `openapi.json`/`api.ts`. Remove the one `git diff` CI step. Revert the `UserController` line. Revert the Vue component. No migrations, no data changes, nothing to un-deploy.

## Dependencies

None external. Requires `scramble:export` + `check-client-drift.sh` in all three repos (already present).

## Open Questions — for the spec phase, deliberately undecided

1. **Flattened avatar-template config errors.** `AvatarTemplateController::assertConfigValid` (`:234`) throws `ValidationException::withMessages(['config' => ["{$e['key']}: {$e['code']}", ...]])` — every knob's error under one `config` key as a formatted string, forcing the backoffice to parse strings to place a message under the right control. Fix API-side with per-knob keys (a contract change plus a client update), or keep it and document the client-side parsing as deliberate?
2. **`ext-intl` in the production image.** `api/Dockerfile` installs `pdo_pgsql zip opcache pcntl posix redis` and no more, so `php artisan db:show` crashes on `Number::fileSize`. Honestly: this affects diagnostics only, never the application. Does a diagnostic command justify changing the production image?

## Success Criteria

- [x] All ten resources declare `@scramble-return`; a fresh `scramble:export` produces no diff against the committed file in any of the three repos (verified locally; `git diff --exit-code openapi.json` after export is zero on the working tree post-regeneration).
- [x] `backoffice/types/api.ts` types participant/project/framework-version `id` as `int`, `status`/`role_code` as their real unions, and translatable fields as `string` (**corrected**: not "objects" — `HasTranslations::getAttributeValue()` returns a scalar string at the property-read boundary these resources use; see `specs/admin-read-api/spec.md`'s Scramble Documentation Parity requirement for the evidence).
- [x] The API CI job fails on a stale committed `openapi.json` — proven by a deliberate red run before it goes green (reproduced locally: reverted one resource's `@scramble-return` annotation, ran the exact CI sequence, confirmed the gate fails; restored, confirmed it passes).
- [x] An admin password reset invalidates the target's existing tokens; covered by a Pest test asserting a pre-reset token is rejected.
- [x] The API-keys table shows all keys with the demo seeder's three present.
- [x] Zero PHPUnit risky flags; the two webkit specs pass ten consecutive runs.
