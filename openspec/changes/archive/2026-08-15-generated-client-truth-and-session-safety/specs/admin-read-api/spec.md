# Delta for Admin Read API

## MODIFIED Requirements

### Requirement: Scramble Documentation Parity

Every endpoint's response resource MUST carry a Scramble-resolvable schema
whose field types reflect the resource's actual runtime types — never
Scramble's `string` default for a field type it cannot infer. A local
`/** @var X $y */` PHPDoc annotation inside a resource's `toArray()` is NOT
sufficient: Scramble does not read it, and a resource relying on it alone
silently exports every field as `string`. A resource field that is a genuine
integer MUST declare a `@scramble-return`/`@return` shape typing it `int`; a
field that is a bounded/enum-like value (e.g. `status`, `role_code`) MUST be
typed as its real union; a field that is a translatable attribute (e.g.
`Competency.name`, `Role.responsibilities`, `BarsIndicator.text`/`anchor_*`)
MUST be typed as `string`, never as an object or array.

**Why `string`, not an object**: these fields are backed by
`Spatie\Translatable\HasTranslations`, whose `getAttributeValue()` intercepts
every `$model->name`-style property read and returns
`getTranslation($key, $locale)` — a scalar string — bypassing the `array`
cast Scramble's static analysis sees on the underlying column. The `array`
shape is only ever produced by `$model->toArray()`
(`mutateAttributeForArray()`), which none of the ten resources call — each is
an explicit whitelist built from direct property fetches. An apply-phase
falsifiability check (`expect($json['data'][0]['name'])->toBeString()`
against a live endpoint) confirmed this empirically before any annotation
was written: the runtime value was already a string on every one of the ten
resources. Typing these fields as an object would have been a NEW lie in the
opposite direction — this requirement's original text had it backwards; see
`design.md` D1 ("Translatable fields — a correction to the direction") for
the full evidence trail.

This governs, by name, ten resources currently defaulting to `string` for at
least one non-string field: `Admin/OrganizationResource`,
`Admin/ParticipantDetailResource`, `Admin/ParticipantResource`,
`Admin/UserResource`, `BarsIndicatorResource`, `CompetencyResource`,
`FrameworkVersionResource`, `ParticipantResource`, `ProjectResource`,
`RoleResource`. `ApiClientResource` and `AvatarTemplateResource` are the
working precedent: both already declare a `@scramble-return` shape with zero
runtime change, and Scramble already resolves both correctly.

(Previously: required Scramble annotations for new endpoints only; silent on
the ten resources whose `@var`-only annotations Scramble ignores, producing
the `string` default across the board. An earlier draft of THIS delta also
claimed translatable fields must be typed as an object — that claim was
itself wrong, in the same direction as the original defect, and is corrected
above.)

#### Scenario: openapi.json includes every new route

- GIVEN Scramble regenerates `openapi.json` after this change
- WHEN the spec is inspected
- THEN all 7 admin endpoints are present with typed responses

#### Scenario: An integer field exports as integer, not string

- GIVEN `ParticipantResource`'s `toArray()` returns an integer `id`
- WHEN a fresh `scramble:export` runs
- THEN `openapi.json`'s schema for that resource types `id` as `integer`, not `string`

#### Scenario: An enum-like field exports as its real union

- GIVEN a resource returns `status` or `role_code`, each a bounded set of known values
- WHEN a fresh `scramble:export` runs
- THEN the exported schema types that field as a string-literal union of its known values, not a bare `string`

#### Scenario: A translatable field exports as a string, never an object

- GIVEN a resource returns a translatable attribute (`HasTranslations`,
  backed by an `array` cast at the column level)
- WHEN a fresh `scramble:export` runs
- THEN the exported schema types that field as `string` — matching what
  `HasTranslations::getAttributeValue()` actually returns on property
  read — never as an object or array

#### Scenario: A @var-only resource is a defect, not a supported pattern

- GIVEN a resource whose `toArray()` relies solely on `/** @var X $y */` with no `@scramble-return` annotation
- WHEN `scramble:export` runs
- THEN Scramble ignores the local `@var` hint and defaults every field to `string` — this is the condition this requirement forbids on the ten named resources
