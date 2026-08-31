# Candidate lifecycle

## States

State identifiers are literal enum values and are kept verbatim.

| State | Description | Typical transitions |
|-------|-------------|---------------------|
| *(null / not created)* | The candidate is not registered yet | → `in_attesa` on first SSO or API creation |
| `in_attesa` | Registered, interview not started | → `in_corso` |
| `in_corso` | Interview active | → `in_valutazione` |
| `in_valutazione` | Interview closed, scoring job running | → `completato` or `errore` |
| `completato` | Evaluation finished (definitive state, or a resolved pending) | — |
| `errore` | Technical or unrecoverable failure | Admin intervention possible |

> The state names are indicative. The supplier may use different naming as long as the semantics are equivalent.

## Data-read gates

| Resource | Minimum required state |
|---------|------------------------|
| Transcript | `in_valutazione` or `completato` |
| Structured evaluation | `completato` (with evaluation sub-state `completed` or `pending`) |

## Candidate uniqueness

- The **candidate identifier** must be unique within the defined context (globally or per project — to be documented in the technical specification);
- An attempt at duplicate creation → conflict error.

## Interview retry

- If the evaluation is in the `pending` state, the candidate may **repeat** part or all of the interview (exactly one retry attempt is allowed);
- After a failed retry (threshold not reached), the evaluation is marked `completed` definitively.

## Deletion and retention

- Deleting an organization/project → cascade to candidates and assessment data (hard delete recommended for compliance);
- Retention policy for audio/transcripts: to be agreed with the client (GDPR).

## Relation to progress webhooks

Every significant transition (a new answer, a competency change) may generate a progress event towards external systems.
