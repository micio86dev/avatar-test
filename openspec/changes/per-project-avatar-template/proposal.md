# Per-project avatar template

> **Recorded after implementation, and labelled as such.** This change was built in a
> single session directly from a reported defect, so the artefact below documents what was
> decided and why rather than pretending to have preceded it. Treating it as a
> written-first proposal would misrepresent how it happened.

## Problem

A project had no say in which avatar template it ran on.

`InterviewController` resolved the provider as `provider_override ?? INTERVIEW_PROVIDER`,
and `ActiveTemplateResolver` then returned the organization's ONE active template for that
provider. Activation is scoped per provider (`AvatarTemplateController:251-256` deactivates
only same-provider siblings), so holding one active HeyGen template AND one active Tavus
template is a legal, expected state — and in that state the env default silently decided
which one every project used.

Two consequences, both reported from real use:

1. Two projects on the same provider could never run different templates, since only one
   per provider can be `is_active`.
2. An operator who activated a HeyGen template and a Tavus template watched HeyGen win
   every time, with no control and no explanation.

`projects.provider_override` had existed since C7a and was **never exposed in the
backoffice** — half the mechanism, unreachable.

## Decision

Add `projects.avatar_template_id`, **nullable**, with the organization-wide active template
as the fallback.

Nullable was chosen over mandatory deliberately. Mandatory would require backfilling every
existing project, make the field required at creation, and force a decision about what
happens when a pinned template is deactivated or deleted. Nullable delivers the capability
with no migration of data and no behaviour change for any project that pins nothing. If
mandatory is wanted later it is an additive migration, not a rewrite.

### Resolution precedence

Most specific first: the project's pinned template, then `provider_override`, then the env
default.

A pinned template also decides the **provider**. Pinning one is already a statement about
which provider the project runs on, and it would be incoherent for the two to disagree.

### `is_active` is NOT required of a pinned template

Requiring both would defeat the column: only one template per provider can be active at a
time, so two projects on the same provider would still be impossible. Pinning IS the
project's choice; `is_active` is the fallback for projects that made none.

### Tenancy at validation, not at read

An org-scoped `Rule::exists`, matching `framework_version_id`. Relying on the resolver to
ignore a foreign pin would still leave a cross-tenant id persisted in our row — which
tenant isolation forbids regardless of whether anything later reads it.

### `nullOnDelete`, never cascade

Deleting a template must return its projects to the fallback, not delete them. A project is
far heavier than a template, and losing one because a cosmetic setting was removed would be
catastrophic and completely unexpected.

## Scope

| Repo | Change |
|---|---|
| `api` | migration, `Project` model + relation, `ActiveTemplateResolver::resolve($provider, $projectId)`, precedence in `InterviewController`, Store/UpdateProjectRequest, `ProjectResource`, OpenAPI |
| `backoffice` | template `<select>` in `ProjectForm`, `en`/`it` copy, typed client |
| `frontend` | OpenAPI snapshot + typed client only (does not read the field) |

Every consumer reaches the template through `ActiveTemplateResolver`, so threading the
project id into it — rather than into each caller — is what makes both providers, the live
clock and the LLM snapshot honour the pin without four separate changes.

## Not in scope

`provider_override` stays unexposed. The pinned template now covers the same need more
precisely, and exposing two overlapping controls for one decision would be worse than
exposing neither.
