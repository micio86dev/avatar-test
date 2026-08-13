# Tasks: Interview Review Surface and Template Portability

> Strict TDD, red before green. Two repos. The API slices land first: the
> backoffice has nothing to render until the read surface exists.
>
> Nothing here is started. Boxes are unchecked because this is a plan, not a
> record.

## 0 — Blocked on

- [ ] 0.1 `avatar-provider-templates` archived with delta specs, creating the `avatar-templates` capability that slice 3 extends. Slices 1, 2 and 4 do not depend on it and can proceed.

## 1 — API: session review read surface

- [ ] 1.1 `SessionReviewResource`: timing, duration, provider, provider ref, ended reason, integrity timeline, risk score + band, snapshots, cost estimates.
- [ ] 1.2 Port `summarizeIntegrity()` + `RISK_WEIGHTS` + `RISK_BANDS` from `legacy-demo/src/lib/proctor-config.ts` into a server-side service. Server-side ONLY (D3) — the backoffice must not hold a second implementation.
- [ ] 1.3 Signed, short-expiry URLs per snapshot (D4). A test asserts no raw `s3_key` appears in any response field.
- [ ] 1.4 `GET /api/participants/{id}/sessions` and `GET /api/interview-sessions/{id}/review`, org-scoped, behind `auth:api` + `TenantContext`.
- [ ] 1.5 Arch test: no route under the `candidate` guard exposes integrity events or snapshots (D2). This is the constraint most likely to be eroded by a well-meaning future change.
- [ ] 1.6 Tests: payload shape, cross-tenant 404, candidate token refused, clean session renders an empty timeline rather than failing.

## 2 — API: cost estimation

- [ ] 2.1 `config/interview.php` provider rates with env overrides, mirroring `avatar-tester/pricing.ts` (HeyGen credits/min × $/credit; Tavus $/min).
- [ ] 2.2 `SessionCostEstimator` deriving from `started_at`/`ended_at`. Never persisted (D5).
- [ ] 2.3 Reuse the existing `AiRequestCostEstimator` for the LLM figure. Two separate numbers, never summed.
- [ ] 2.4 Tests: duration × rate per provider, unfinished session yields no estimate, rate override changes the result.

## 3 — API: template export / import

- [ ] 3.1 `schema: "beai.avatar-template/1"` document (D6). Version refused if unrecognised.
- [ ] 3.2 `GET /api/avatar-templates/export`, admin-only via `AvatarTemplatePolicy` (D10).
- [ ] 3.3 `POST /api/avatar-templates/import`, admin-only, validating every key through `ProviderFieldSpecs` (D7) and rejecting unknown keys.
- [ ] 3.4 Never overwrite: colliding names derive a new name; imports arrive inactive (D8).
- [ ] 3.5 Multi-provider entries split one-per-provider with the provider in the derived name (D9).
- [ ] 3.6 Optional `persona` block (body, greeting, language) mapped onto BEAI's versioned prompt composition. Absent persona is valid.
- [ ] 3.7 Tests: round-trip export→import, non-admin 403, unknown key refused with the key named, collision creates rather than overwrites, multi-provider splits, bad schema refused.
- [ ] 3.8 `openapi.json` regenerated and synced to BOTH consumers.

## 4 — Backoffice: session review view

- [ ] 4.1 Sessions list on the participant detail, linking to each review (D11).
- [ ] 4.2 Review view: timing, integrity timeline, risk band, snapshot strip, costs.
- [ ] 4.3 Events listed individually beside the score, never replaced by it.
- [ ] 4.4 Costs labelled as estimates, avatar and LLM separate.
- [ ] 4.5 Explicit "no events recorded" state — a clean session must not read as a broken page.
- [ ] 4.6 Tests: rendering, empty state, no total is displayed, snapshot images use the signed URL as given.

## 5 — Backoffice: template export / import

- [ ] 5.1 Admin-only controls; not rendered at all for operator/viewer (a control that 403s teaches the wrong lesson).
- [ ] 5.2 Import result panel: created vs refused, with the reason per entry.
- [ ] 5.3 Tests: controls hidden by role, partial-result reporting, refusal surfaced.

## 6 — Wrapper

- [ ] 6.1 `DESIGN.md` §8.2 gains the session review; §5 gains the new components.
- [ ] 6.2 Submodule pointers bumped.

## Open, to resolve before slice 2

- **Rate accuracy.** The `avatar-tester` defaults were verified in 2026 for its
  own plan. BEAI's plan may differ, and a wrong rate produces a confident wrong
  number. The estimate ships behind config; the values need confirming against
  the actual contracts before anyone treats the figure as guidance.

## Documented, Not Scoped

- **Retention.** Making snapshots visible does not extend how long they are
  kept. Open decision 2 still governs the durations, and the review surface must
  not become an argument for keeping evidence longer.
- **No new capture.** Events and snapshots are already written; this reads them.
- **No candidate-facing surface.** Not now, not behind a flag (D2).
- **No question templates.** Ruled out: BEAI derives questions from BARS
  competencies with adaptive follow-ups.
