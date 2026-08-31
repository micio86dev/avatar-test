# Webhooks — events to notify

## Purpose

To send the calling system **push notifications** during and after the assessment, so it does not have to poll continuously.

## Configuration

Per **project** or per **organization** (an architectural choice):
- the destination webhook URL;
- a shared secret for authenticity verification;
- the enabled event types.

> In the rebuild, this configuration is **native** to the platform. No intermediary router is required.

---

## Event 1: Candidate progress

**When it is sent:**
- On candidate creation (first access or explicit creation);
- After every recorded answer (or at significant advancement intervals).

**Conceptual payload data:**

| Field | Description |
|-------|-------------|
| Candidate identifier | The same value received at SSO ingress |
| Project reference | Campaign ID or code |
| Progress | The list of competencies with their advancement state |

**Progress structure (per competency):**

| Field | Description |
|-------|-------------|
| Competency code | e.g. `PRS`, `STG` |
| Answers | The list of answers given: question id, timestamp |

**New-candidate case:** all the project's competencies are present with empty answer lists.

**Advancement case:** competencies with one or more recorded answers.

---

## Event 2: Evaluation completed

**When it is sent:**
- At the end of the asynchronous evaluation job (regardless of the exact end time of the interview).

**Conceptual payload data:**

| Field | Description |
|-------|-------------|
| Candidate identifier | Unchanged |
| Project reference | Campaign ID or code |
| Evaluation status | `completed` or `pending` (see the business rules) |
| Evaluation | A structured object with per-competency scores |

**Evaluation content (conceptual):**

| Sub-field | Description |
|-------------|-------------|
| `text` | Per competency: score, reliability, behaviors (indicator, score, explanation, excerpts) |
| `files` | References to assets: per-question audio, transcript, raw evaluation file |

**Status `pending`:** the evaluation was processed but competency coverage is insufficient; the candidate may be invited to retry.

**Status `completed`:** the evaluation is definitive.

---

## Notification authentication (generic requirement)

- Every webhook request must be **verifiable** by the receiver;
- The mechanism is the supplier's choice (HMAC signature of the body, a dedicated header, a bearer token, etc.);
- Document the verification format in the technical specification.

---

## HTTP semantics (indicative)

| Outcome | Expected receiver behaviour | BEAI action |
|-------|-------------------------------|-------------|
| Success | Acknowledge receipt | No resend |
| Temporary error | Retry with backoff | Automatic resend |
| Permanent error | Log + admin alert | No infinite resending |

---

## Narrative example — progress

> Webhook to `https://hr.acme.com/beai/events`: candidate `acme-672`, project 42, competency INN has 2 answers (questions 0 and 1), the other competencies have 0 answers.

## Narrative example — evaluation

> Same endpoint, evaluation event: status `completed`, competency COL score 3.67 with 3 assessed indicators, audio and transcript paths attached.

---

## Data structure reference

See `../03-ux-reference/evaluation-report-example.json` for the shape of the evaluation's `text` block.
