# Design: Interview Review Surface and Template Portability

## D1 — Read the evidence that already exists; add only cost

`integrity_events.kind`/`payload`/`ts` and `interview_snapshots.s3_key`/`taken_at`
are already written per session, and `interview_sessions` already carries
`started_at`, `ended_at`, `ended_reason`, `provider`, `provider_session_ref`.

So this change is overwhelmingly a READ surface. Adding capture would be
solving a problem that does not exist, and would add write load to the
interview's hot path for data already on disk.

The single exception is **cost**, which nothing stores. It is derived, not
recorded — see D5.

## D2 — Backoffice only, enforced server-side

The review surface hangs off the admin read API behind `auth:api` +
`TenantContext`, never off `auth:api-candidate`.

This is not a UI decision that could be relaxed later. A candidate able to read
their own integrity timeline learns exactly which behaviours are counted and how
long the thresholds are — the taxonomy in `proctor-config.ts` is a list of
things to avoid doing, and handing it over defeats the measurement. The
candidate routes must not gain an integrity read, and an arch test should say so.

## D3 — Reuse the existing severity model, do not invent a second one

`legacy-demo/src/lib/proctor-config.ts` already defines `RISK_WEIGHTS`, the
`RISK_BANDS` thresholds (`medium: 15`, `high: 40`) and `summarizeIntegrity()`.
`CLAUDE.md` names that file as the thing to port.

The scoring MUST be computed server-side and returned with the payload, not
recalculated in the backoffice. Two implementations of a weighted score drift,
and the one an operator reads must be the one the API can defend.

## D4 — Snapshots are served through short-lived signed URLs, never public keys

`interview_snapshots.s3_key` is an object key, not a URL. The API MUST mint a
signed, short-expiry URL per snapshot at read time.

Returning the raw key would either require a public bucket — webcam frames of
identifiable people, publicly addressable, which is indefensible — or leak the
storage layout. Expiry keeps a copied URL from outliving the operator's session.

## D5 — Cost is an ESTIMATE, computed from duration, and labelled as one

Rates come from config with env overrides, mirroring `avatar-tester/pricing.ts`:
HeyGen bills credits/min at a $/credit rate; Tavus bills per conversational
minute. Neither provider exposes a per-session billed figure through an API.

Therefore the number MUST be rendered as an estimate in the UI, never as a
charge. An operator who reads it as an invoice line will eventually reconcile it
against a real bill and find a discrepancy that was never a defect.

Two costs are shown separately and never summed: **avatar minutes** (provider
duration × rate) and **LLM tokens** (already in `ai_requests`, via the existing
`AiRequestCostEstimator`). They come from different vendors on different meters;
one total would be a number with no owner.

## D6 — Export is a versioned document with an explicit shape

The export MUST carry a schema version. An unversioned config blob is an import
routine that has to guess, and guessing is how a stale export silently produces a
template pointing at an avatar that no longer exists.

```
{
  "schema": "beai.avatar-template/1",
  "exported_at": "<ISO-8601>",
  "templates": [
    { "name": "...", "description": "...", "provider": "heygen|tavus",
      "config": { ... }, "persona": { "body": "...", "greeting": "...", "language": "it" } }
  ]
}
```

`persona` is optional: a template may be pure provider configuration.

## D7 — Import validates against the SAME field specs the form uses

`ProviderFieldSpecs` already defines, per provider, which keys exist and what
they accept — the create/edit form is built from it.

Import MUST validate through that same source. A second validator would let a
file install a config the form would have refused, and the operator would meet
the difference as a provider error mid-interview.

Unknown keys are rejected, not silently dropped: a key the system does not
understand means the file came from a version this build cannot honour, and
importing the subset it recognises produces a template that is quietly not what
was exported.

## D8 — Import never overwrites; it creates

An import with a colliding name creates a new template with a derived name,
rather than mutating the existing one.

Overwriting would let a file silently change the configuration a live project is
running its interviews with. Creating is recoverable; overwriting is not, and the
operator cannot see what they lost.

Activation stays a separate, deliberate act: imported templates arrive inactive.

## D9 — Multi-provider files split into one template per provider

An `avatar-tester` row carries `heygen_config` and `tavus_config` together. A
BEAI template belongs to one provider, immutable after creation
(`AvatarTemplateForm` disables the field, and the API refuses the change).

The importer therefore emits one template per provider block present, with the
provider suffixed onto the derived name. Rejecting such files would push the job
of splitting JSON by hand onto the operator; collapsing them would lose a block.

## D10 — Export and import are admin-only, on the same policy as the templates

Both directions go through `AvatarTemplatePolicy`. Export is a read of
configuration an operator can already see in the form, but as one file it is
also the fastest way to remove configuration from the tenant, and import can
change what every future interview runs on.

## D11 — The review surface is a page, not a tab on the participant detail

Sessions are per-competency: one participant has several. The review belongs to
a SESSION, and hanging it on the participant would force a page that already
shows a lifecycle timeline, a transcript and a BARS report to also carry N
proctoring timelines.

The participant detail links to its sessions; each session has its own review.
