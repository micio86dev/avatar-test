# Delta for Audit Log

## ADDED Requirements

### Requirement: Credential and LLM-binding mutations are audited with the key value always redacted

Every credential lifecycle mutation MUST record an audit row via
`AuditRecorder` with action `llm_credential.created`, `.rotated`, `.deleted`,
or `.verified`. Every template binding/unbinding MUST record
`avatar_template.llm_bound` or `.llm_unbound`. Because `AuditRecorder`'s
redaction denylist already contains `api_key`, a rotation's recorded payload
MUST carry `{name, key_last_four, key_fingerprint}` and MUST NOT carry the
`api_key` value at any depth.

#### Scenario: Creating a credential is audited without the key value

- WHEN an admin creates a credential
- THEN an `llm_credential.created` row is recorded carrying `name` and `key_last_four`, and the `api_key` value is absent from the payload

#### Scenario: Rotating a credential is audited with fingerprint fields only

- WHEN an admin rotates a credential
- THEN an `llm_credential.rotated` row is recorded carrying `{name, key_last_four, key_fingerprint}`, with no `api_key` value present at any depth

#### Scenario: Binding a model to a template is audited

- WHEN an admin binds a model and credential to a template
- THEN an `avatar_template.llm_bound` row is recorded naming the model and credential, with no key value present

#### Scenario: Unbinding a template is audited

- WHEN an admin clears a template's LLM binding
- THEN an `avatar_template.llm_unbound` row is recorded for that template

#### Scenario: Verifying a credential's key is audited

- WHEN an admin triggers key validation for a stored credential
- THEN an `llm_credential.verified` row is recorded carrying the validation result's stable code, never the vendor's raw message
