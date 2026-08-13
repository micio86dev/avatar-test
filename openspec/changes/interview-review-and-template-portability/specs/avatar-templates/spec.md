# Delta: avatar-templates — JSON portability

## ADDED Requirements

### Requirement: Avatar template configuration is exportable and importable as JSON

The system MUST allow an **admin** to export avatar template configuration as a
versioned JSON document, and to import such a document. Both directions MUST go
through the same policy that guards the templates themselves.

The document MUST carry a schema identifier. An unversioned blob forces the
importer to guess, and guessing is how a stale file silently produces a template
pointing at an avatar that no longer exists.

A template MAY carry a persona (system prompt body, spoken greeting, language)
alongside its provider configuration. Ordered question lists are NOT part of the
document: BEAI derives questions from BARS competencies with adaptive
follow-ups, and a hand-ordered list would contradict that.

Import MUST validate every provider key against `ProviderFieldSpecs`, the same
source the create/edit form is built from, and MUST reject unknown keys rather
than dropping them. A key this build does not understand means the file came
from a version it cannot honour; importing the recognised subset yields a
template that is quietly not the one exported.

Import MUST NOT overwrite an existing template. A colliding name produces a new
template under a derived name. Overwriting would let a file silently change the
configuration a live project runs its interviews on, with nothing shown of what
was lost.

Imported templates MUST arrive inactive. Activation stays a deliberate, separate
act.

A document carrying more than one provider block for the same logical template
MUST produce one BEAI template per provider, since a template belongs to exactly
one provider and that provider is immutable after creation.

#### Scenario: An admin exports templates

- GIVEN an organization with avatar templates
- WHEN an admin requests the export
- THEN a JSON document is returned carrying the schema identifier, an export
  timestamp, and one entry per template with its provider config

#### Scenario: A non-admin may not export or import

- GIVEN an authenticated operator or viewer
- WHEN they attempt either direction
- THEN the request is refused with 403

#### Scenario: A valid document imports as inactive templates

- WHEN an admin imports a valid document
- THEN the templates are created, inactive, in the caller's organization

#### Scenario: An unknown provider key is rejected

- GIVEN a document whose config carries a key absent from `ProviderFieldSpecs`
- WHEN it is imported
- THEN the import fails with a validation error naming the key
- AND no template is created

#### Scenario: A colliding name never overwrites

- GIVEN a template named "Interviewer IT" already exists
- WHEN a document containing that name is imported
- THEN a new template is created under a derived name
- AND the existing template is unchanged

#### Scenario: A multi-provider entry becomes one template per provider

- GIVEN an entry carrying both a HeyGen and a Tavus configuration
- WHEN it is imported
- THEN two templates are created, one per provider, each named for its provider

#### Scenario: A document from an unsupported schema version is refused

- WHEN a document carries an unrecognised schema identifier
- THEN the import is refused with a message naming the expected version
