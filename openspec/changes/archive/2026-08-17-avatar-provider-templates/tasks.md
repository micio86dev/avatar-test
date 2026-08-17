# Tasks — Avatar Provider Templates (C14)

All six units delivered. Every checkbox below was closed against a merged PR
with green CI, not against a local run.

## PR1 — Tavus opacity and completion (micio86dev/frontend#17)

- [x] 1.1 Replace `Daily.createFrame` with `createCallObject`; render remote
      tracks into the page's own `<video>`. The iframe carried the vendor's own
      chrome onto the interview page — the requirement was contradicted by
      shipped code, not merely unimplemented.
- [x] 1.2 Join with the camera off; the proctoring layer owns that device.
- [x] 1.3 Ignore local tracks — piping the candidate's microphone into the
      avatar's element plays their voice back at them on a delay.
- [x] 1.4 Complete on the avatar's spoken end phrase. The `conversation.tool_call`
      path is never sent, so every Tavus session ran to timeout and was never
      scored. Only the avatar's speech counts.
- [x] 1.5 Make `toggleMic` actually toggle. It was an empty method whose test
      asserted only that it did not throw.

## PR2 — Schema and the one-active invariant (micio86dev/backend#46)

- [x] 2.1 `avatar_templates`, org-scoped, `config` as jsonb.
- [x] 2.2 Partial unique index `(organization_id) WHERE is_active`. In
      application code two concurrent activations both win.
- [x] 2.3 Tests through the DATABASE, not a service that can be bypassed.

## PR3 — Field specs and validation (micio86dev/backend#46)

- [x] 3.1 `FieldSpec` + `FieldType` enum + per-provider definitions.
- [x] 3.2 `ConfigValidator` returning EVERY error, coded
      `required|type|range|enum|unknown`.
- [x] 3.3 Drop `voiceProvider` — avatar-tester collects it and never sends it.
- [x] 3.4 Cap durations at each provider's REAL ceiling (1200s / 3600s).

## PR4 — CRUD and activation (micio86dev/backend#47)

- [x] 4.1 Admin-only, including read.
- [x] 4.2 Cross-tenant → 404, never 403 (no enumeration oracle).
- [x] 4.3 Activation: deactivate-then-activate in ONE transaction.
- [x] 4.4 Re-validate the config AT activation, not only at write time.
- [x] 4.5 Provider immutable; active template not deletable (409).
- [x] 4.6 Audit every create/update/activate/delete.

## PR5 — Provider payloads and PAL sync (micio86dev/backend#48)

- [x] 5.1 `TemplatePayload::heygen()` / `::tavus()`, unset means ABSENT.
- [x] 5.2 Empty config → empty payload, merged not assigned, so a tenant with no
      template sends the body it sent before templates existed.
- [x] 5.3 Tavus language translated to its own vocabulary.
- [x] 5.4 `TavusPalSync` — nine of seventeen Tavus knobs live on the persona and
      do nothing on a conversation. Shipping them without this would be the
      dead-knob defect, nine times over.
- [x] 5.5 Sync never throws; reports a stable code, never the provider's words.

## PR6 — Operator UI and opacity hardening (frontend#18, backoffice#9)

- [x] 6.1 Provider errors carry a stable code. PR1's own catch block emitted
      `String(err)` under a comment claiming it did not.
- [x] 6.2 Measure the bundle: each SDK is already its own lazy chunk.
- [x] 6.3 No vendor name in any candidate-facing string, locale or template.
- [x] 6.4 Backoffice screen BUILT from the served field specs.
- [x] 6.5 Clearing a field removes the key; selects carry an explicit default.
- [x] 6.6 The vendor IS named to the operator — anonymity is a promise to the
      candidate, and an operator who cannot tell which service a template
      targets cannot know which dashboard to copy an id from.

## Open

- [x] 7.1 Regenerate the typed API client — **DONE** (micio86dev/frontend#20,
      micio86dev/backoffice#11). Both apps regenerated from the same spec
      snapshot; the template types now DERIVE from it. Two fields stay narrowed
      with a stated reason: `config` generates as `unknown[]` (PHP has one array
      type for lists and maps, and this one is a map — adopting it would have
      the client confidently wrong rather than merely untyped), and `provider`
      generates as `string` because the union lives in a PHP `match` and a
      database CHECK, neither of which reaches OpenAPI. `FieldSpec` stays
      hand-written: the endpoint returns a provider-keyed map of arbitrary
      descriptors and Scramble types the whole response as `data: string`.
- [ ] 7.2 **Per-project template override.** Out of scope by decision: the
      requirement is one active template per ORGANIZATION. Worth revisiting,
      because projects already carry `language`, so a single org-wide avatar may
      prove coarse for a tenant running interviews in two languages.
- [ ] 7.3 **Avatar/voice catalogue.** Ids stay free-text, validated for shape and
      not against the provider's live inventory. Fetching inventories is a
      second integration per provider and needs no schema change.
