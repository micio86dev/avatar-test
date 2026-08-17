# Proposal: Avatar Provider Templates (C14)

## Intent

Give operators a managed catalogue of **avatar templates** — a named, versioned
bundle of provider + avatar + voice + tuning — with exactly **one active
template per organization** at a time, and make the candidate app incapable of
revealing which provider is behind the face.

Two halves, and only one of them is a feature.

The first is the configuration surface BEAI has never had. The second is a
**defect fix**: the product already promises the candidate a neutral experience,
and the current Tavus implementation breaks that promise in the most visible way
possible.

---

## Verified current state

Read from the code on 2026-08-01, not from documentation.

### BEAI has no provider configuration at all

`api/config/interview.php` contains three keys: `provider`, `heygen.api_key`,
`tavus.api_key`. That is the entire surface.

`HeygenProvider::issue()` posts `{competency_code, question_index,
system_prompt?}` and then `{context_id}`. There is **no** `avatar_id`, no
`voice_id`, no language, quality, encoding, voice speed/stability/style, and no
session duration. Whatever avatar and voice the provider account happens to
default to is what every candidate of every tenant gets.

So "the admin picks an avatar and a voice" is not a change to an existing
mechanism. There is no mechanism.

### BLOCKER 1 — the candidate can see the provider today

`frontend/app/providers/tavus.ts:69` calls `Daily.createFrame(mountEl, …)`.

That embeds a **visible `daily.co` iframe with Daily's own chrome** into the
interview page. Not a subtle network-level tell: the vendor's UI, on screen, in
front of the candidate. The requirement that the end user must not know which
service is in use is not merely unimplemented — it is actively contradicted by
shipped code, and no amount of configuration work fixes it.

`avatar-tester` solves the same problem with `createCallObject({audioSource:
true, videoSource: false})` and pipes the remote tracks into the app's own
`<video>` element. That is the shape to port.

### BLOCKER 2 — Tavus interviews probably never complete on their own

`frontend/app/providers/tavus.ts:112` detects completion **solely** via an app
message with `data.type === 'conversation.tool_call'` and `data.name ===
'end_interview'`.

`avatar-tester` investigated exactly this and found the tool is never registered,
so the message never arrives. It moved both providers onto the spoken end-phrase
sentinel instead. If that finding holds for BEAI — and the code is the same
shape — every Tavus session today runs until it times out rather than completing.

This is in scope because a template that lets an operator *choose* Tavus turns a
latent defect into a selectable one.

### What `avatar-tester` already solved

`/Volumes/Scheda SSD/avatar-tester` is an Astro testbed for the same two
providers. It is not production code, but it contains the design work:

| Asset | Where | Value here |
|---|---|---|
| Declarative field spec (30 typed knobs: 13 HeyGen / 17 Tavus) | `src/lib/provider-config.ts` | Drives form, validation and mapping from one definition |
| `validateProviderConfig()` with `required\|type\|range\|enum` | same | Ready-made validation contract |
| Template + ordered questions schema | `src/lib/db.ts`, `migrations/0004` | The preset concept, already normalised |
| Tavus PAL (persona) lifecycle, RFC-6902 patching | `src/lib/tavus-pal.ts` | Persona-level knobs cannot be set on a conversation |
| Session-cap clamping to plan ceilings | `src/lib/timing.ts` | HeyGen 1200s / Tavus 3600s are real limits |
| Tavus concurrency retry + `429 provider_busy` | `src/pages/api/interview/start.ts` | BEAI has the client half, not the server half |

What it does **not** have, and must not be copied: it names the provider
everywhere on purpose, because it is a comparison tool.

### The gap nobody has written down

There is **no organization-provisioning surface** in BEAI — projects and
participants have APIs, organizations have none. Templates are org-scoped, so
this change inherits that gap. Called out under Risks, not silently absorbed.

---

## Scope

### In Scope (C14)

1. **Template catalogue** — org-scoped CRUD: name, description, provider,
   per-provider config blob, active flag.
2. **Exactly one active template per organization**, enforced in the database,
   not only in application code.
3. **Declarative field specs** per provider, driving admin form, API validation
   and provider-payload mapping from a single definition.
4. **Provider wiring** — the chosen avatar/voice/tuning actually reaches HeyGen
   and Tavus at session start, which it currently does not.
5. **Provider opacity** — replace the Daily iframe with a call object; a server-
   issued opaque handle; per-provider lazy SDK chunks; sanitised error strings;
   neutral DOM ids.
6. **Backoffice UI** — list, create, edit, duplicate, activate.
7. **Tavus PAL sync** for persona-level knobs.

### Out of Scope (explicit)

- **Per-tenant provider credentials.** One key pair per provider, as today.
  Bringing tenant-supplied keys in means a secrets-storage design and a blast
  radius this change should not carry.
- **An avatar/voice catalogue.** Ids stay free-text, validated for shape and not
  against the provider's live inventory. Fetching inventories is a second
  integration per provider and can be added without changing this schema.
- **Per-project template override.** The requirement is one active template per
  organization. A project-level override is a plausible next step and is
  deliberately not designed in now.
- **New providers.** Two, as today.
- **Cost metering.** `avatar-tester` has it; it belongs with a billing slice.

---

## Capabilities

### New

- `avatar-templates` — the catalogue, the single-active invariant, the field
  specs and validation.

### Modified

- `interview-session` — session start resolves the active template and sends its
  configuration to the provider.
- `interview-provider` — opacity requirements become normative; the Tavus media
  path and completion detection change.

---

## Approach

Six PRs, ordered so the **defect fixes land before the feature that would
multiply them**.

| PR | Content | Why here |
|---|---|---|
| 1 | Tavus: `createCallObject` + own `<video>`; end-phrase completion | Blockers 1 and 2. Independently shippable, valuable even if the rest slips |
| 2 | Schema + model: `avatar_templates`, partial unique index, tenancy | Foundation |
| 3 | Field specs + validation, shared shape, per-provider definitions | Pure logic, no I/O |
| 4 | API: org-scoped CRUD + activate, RBAC admin-only | Surface |
| 5 | Session start reads the active template and maps it to provider payloads; Tavus PAL sync | The part that makes it real |
| 6 | Backoffice UI + opacity hardening (lazy chunks, sanitised errors, neutral ids) | Operator-facing, plus the leaks that are not the iframe |

---

## Risks

**One active template, enforced where?** In application code alone, two
concurrent activations race and both win. This must be a database constraint —
a partial unique index on `(organization_id) WHERE is_active` — or the invariant
is decorative. Postgres supports it; the design will specify it.

**Activation with no template is a valid state.** A fresh organization has no
templates. Session start must degrade to the environment defaults rather than
fail, or installing this change breaks every existing tenant.

**Config blobs are schemaless in the database.** A JSON column validated only at
write time drifts when a field spec changes. Mitigated by validating on read at
session start too, and by never trusting a stored blob to be complete.

**Provider opacity is a property of the whole page, not one file.** Bundle
strings, network hosts, global objects (`window._daily`), error text and DOM ids
all leak independently. A test asserting one of them proves very little; the
design has to enumerate them and the spec has to make the list normative.

**No organization-provisioning surface.** Templates are org-scoped, and there is
still no supported way to create an organization. This change does not fix that;
it makes it more visible.

---

## Dependencies

- C7 (interview session), C8 (conversation) — both delivered.
- No dependency on the open GDPR retention decision.

---

## Success Criteria

1. An admin can create a template, set avatar and voice, and activate it; the
   next interview uses exactly those values.
2. Activating a second template deactivates the first, **atomically**, proven by
   a concurrent-activation test.
3. A tenant cannot see, edit or activate another tenant's template.
4. No string, host, global object, DOM id or error message reachable by a
   candidate identifies the provider — asserted per vector, not in aggregate.
5. A Tavus interview reaches `complete` on its own.
6. An organization with no active template still runs interviews.

---

## Open questions

**Q1 — one active template per organization, or per project?** Proceeding with
**per organization**, as stated in the request. Noting that projects already
carry `language` and `role_code`, so a single org-wide avatar may prove too
coarse once a tenant runs interviews in two languages. Per-project override is
listed as out of scope precisely so it stays easy to add.

**Q2 — what should an operator see when a provider rejects a config?** Provider
error text cannot be shown verbatim: it names the provider. Proceeding with a
sanitised, code-based message in the candidate app and the **full** provider
error in the backoffice, where naming the vendor is not a leak.
