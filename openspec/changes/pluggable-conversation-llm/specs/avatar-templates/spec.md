# Delta for avatar-templates

## MODIFIED Requirements

### Requirement: Exactly one active template per organization and provider, enforced at the database

The database MUST enforce, via a partial unique index on
`avatar_templates (organization_id, provider) WHERE is_active`, that an
organization can hold at most one row with `is_active = true` **per
provider** at a time. Enforcing this in application code alone is
insufficient: two concurrent activations would each read "no other template
is active for this provider," each write, and both win, leaving the
organization with two active templates on the same provider and the next
interview picking whichever row a query happens to return first.

The index MUST be partial (`WHERE is_active`) and scoped to
`(organization_id, provider)`, not `(organization_id)` alone. Provider is
resolved per project, not per organization: an organization running one
project on HeyGen and another on Tavus needs two simultaneously active
templates — one per provider — and a plain `(organization_id)` index would
make that unconfigurable.

A newly created template MUST default to `is_active = false`. Creating a
template must never change what candidates are currently seeing; activation
is a separate, deliberate act.

(Previously: the partial unique index was scoped to `(organization_id)` alone,
capping an organization at exactly one active template across ALL providers —
insufficient once provider is chosen per project rather than per organization.)

#### Scenario: An organization cannot hold two active templates on the same provider, asserted at the database

- GIVEN organization O already has one active `tavus` template
- WHEN a second `AvatarTemplate::create(['is_active' => true, 'provider' => 'tavus', ...])` is
  attempted directly against the database for organization O, bypassing the
  service layer
- THEN the database raises `Illuminate\Database\QueryException` (unique
  violation on `avatar_templates_one_active_per_org_provider`)

#### Scenario: One organization may hold an active template on each of its providers simultaneously

- GIVEN organization O with an active `heygen` template
- WHEN organization O also activates a `tavus` template
- THEN both remain active — the constraint is scoped to `(organization_id, provider)`, not to `organization_id` alone

#### Scenario: Two organizations may each hold an active template

- GIVEN organization A and organization B, unrelated
- WHEN each activates a template of its own
- THEN both templates remain active — the constraint is scoped to
  `organization_id`, not global

#### Scenario: An organization may hold many inactive templates

- GIVEN organization O with two inactive templates already
- WHEN a third inactive template is created for O
- THEN all three rows persist — the partial index does not constrain inactive
  rows at all

#### Scenario: A newly created template is never active

- WHEN a template is created with no `is_active` given
- THEN `is_active` is `false`

### Requirement: Activation swaps the active template within the same provider, atomically, and re-validates

`POST /api/avatar-templates/{id}/activate` MUST deactivate the organization's
current active template **on the same provider** (if any) and activate the
requested one inside ONE database transaction, deactivate-then-activate in
that order. Activating a template on one provider MUST NOT deactivate an
active template on a different provider within the same organization.

The template's config MUST be re-validated against the current field spec at
the moment of activation. Activating an already-active template MUST be a
no-op that succeeds (200).

(Previously: deactivated the organization's single active template regardless
of provider, which is now incorrect — an organization may hold one active
template per provider.)

#### Scenario: Activating a template deactivates the previous one on the same provider

- GIVEN template A (`tavus`) is active and template B (`tavus`) is not, in the same organization
- WHEN template B is activated
- THEN template B is active and template A is no longer active

#### Scenario: Activating a Tavus template does not deactivate an active HeyGen template

- GIVEN organization O has an active `heygen` template and an inactive `tavus` template
- WHEN the `tavus` template is activated
- THEN the `heygen` template remains active and the `tavus` template becomes active — both are now active simultaneously

#### Scenario: Activation never leaves the organization with two active templates on the same provider

- GIVEN template A (`tavus`) is active
- WHEN template B (`tavus`) is activated
- THEN exactly one `tavus` template in the organization has `is_active = true`

#### Scenario: A template with an invalid config cannot be activated

- GIVEN a template whose config was written directly to the database and no
  longer satisfies the current field spec
- WHEN activation is attempted
- THEN the response is 422 and the template's `is_active` remains `false`

#### Scenario: Activating the already-active template is a no-op, not an error

- GIVEN a template that is already active
- WHEN it is activated again
- THEN the response is 200 and it remains active

### Requirement: Active template resolution requires an explicit provider and never crosses providers

`ActiveTemplateResolver::resolve(string $provider)` MUST take a **required**
`$provider` argument with no default value, and MUST filter on
`->where('provider', $provider)` in addition to `is_active`. An optional
argument would allow a future call site to omit it and reintroduce
cross-provider template leakage.

Resolving an organization's active template for a given provider MUST return
`null` rather than throw when no template is active for that provider —
including when the organization has an active template on a *different*
provider. Resolution failures or a `null` result MUST be swallowed at the
call site; a candidate session MUST NOT fail to start because a template
could not be resolved, and the provider payload falls back to
byte-identical pre-template behavior.

(Previously: `resolve()` took no arguments and matched on `is_active` alone,
returning an active template regardless of its provider — a project running
on Tavus could silently receive a HeyGen-shaped active template.)

#### Scenario: An active template on a different provider is not returned

- GIVEN organization O has an active `heygen` template and no `tavus` template
- WHEN `ActiveTemplateResolver::resolve('tavus')` is called for organization O
- THEN the result is `null` — the active `heygen` template is never returned

#### Scenario: resolve() has no default argument

- WHEN `ActiveTemplateResolver::resolve()` is called with no `$provider` argument
- THEN a compile/type error results — there is no legal no-argument call

#### Scenario: An organization with no active template on any provider resolves to null

- GIVEN an organization with zero templates
- WHEN `resolve('heygen')` is called
- THEN the result is `null`, not an exception

#### Scenario: Resolution never crosses tenants

- GIVEN organization B has an active `tavus` template and organization A has none
- WHEN `resolve('tavus')` is called for organization A
- THEN the result is `null` — organization B's template is never returned

## ADDED Requirements

### Requirement: A template may bind one conversation model and one credential, both or neither

`avatar_templates` MUST carry `llm_model_id` (FK → `llm_models`,
`restrictOnDelete`), `llm_credential_id` (FK → `llm_credentials`,
`restrictOnDelete`), and `heygen_llm_configuration_id` (string, nullable) as
real columns, never as `config` jsonb keys. A database `CHECK` constraint
MUST enforce `(llm_model_id IS NULL) = (llm_credential_id IS NULL)` (both set
or both null).

Binding validation MUST be enforced in `AvatarTemplate::booted()`, not only in
a FormRequest, so that `create`, `update`, and the portability controller's
`forceFill()->save()` path are all guarded identically. A credential
belonging to another organization MUST be treated as unresolvable (the
`TenantScoped` global scope returns null for it), and a credential whose
`vendor` does not match the bound model's `vendor` MUST be rejected with 422.

`ProviderFieldSpecs::tavus()` MUST NOT define an `llmModel` key: the binding
and the old select would otherwise write the same PAL path, and the last
writer would silently win.

#### Scenario: A raw half-bound insert is rejected by the database

- WHEN a row is inserted directly with `llm_model_id` set and `llm_credential_id` null
- THEN the insert fails on the CHECK constraint

#### Scenario: A cross-org credential cannot be bound

- GIVEN a credential belonging to organization B
- WHEN an admin of organization A attempts to bind it to their own template
- THEN the binding is rejected — the credential is unresolvable under organization A's tenant scope

#### Scenario: A vendor mismatch between model and credential is rejected

- GIVEN a registry model with `vendor = 'google'` and a credential with a different `vendor`
- WHEN the template is saved with both bound together
- THEN the response is 422

#### Scenario: llmModel is no longer an accepted Tavus config key

- WHEN a Tavus template payload includes a `config.llmModel` key
- THEN the response is 422 carrying `config.llmModel` coded `unknown`

### Requirement: Unbinding a template clears only that template's binding

`PATCH /avatar-templates/{id}` with both `llm_model_id` and
`llm_credential_id` set to null MUST clear the binding on that template
alone, leaving every other template referencing the same credential
untouched. Unbinding a HeyGen-provider template MUST delete its
`heygen_llm_configuration_id` resource.

#### Scenario: Unbinding one template leaves siblings intact

- GIVEN two templates bound to the same credential
- WHEN one is unbound via PATCH with both binding ids null
- THEN the other template's binding is unchanged

#### Scenario: Unbinding a HeyGen template removes its configuration

- GIVEN a bound HeyGen template with a stored `heygen_llm_configuration_id`
- WHEN it is unbound
- THEN the HeyGen `llm_configuration` is deleted and the stored id is cleared

### Requirement: Portability export and import never carry a credential id or key

`TemplateDocument::export()` MUST represent a bound template's LLM binding as
`{model_key, credential_name}` only — never `llm_model_id`,
`llm_credential_id`, or any key material. Import MUST resolve `model_key`
against the importing organization's registry and `credential_name` against
its own credentials; an unresolvable `model_key` MUST import the template
**unbound**, with a warning, never as a failed import.

#### Scenario: Exporting a bound template carries no id or key

- GIVEN a template bound to a model and credential
- WHEN it is exported
- THEN the document's `llm` block carries `model_key` and `credential_name` only

#### Scenario: An unresolvable model_key imports unbound with a warning

- GIVEN an export document naming a `model_key` absent from the importing organization's registry
- WHEN it is imported
- THEN the template is created unbound, and the import result reports a warning naming the unresolved key
