# Retention Durations — Decision Brief

**Status: awaiting sign-off. Nothing here is legal advice, and nothing here is
in force.** Every duration in `api/config/retention.php` is `null` and
`RETENTION_ENABLED` is `false`. This document exists so the decision is a
single ratification rather than a research project, and so that whoever signs
it can see exactly what they are signing.

Four artifact classes need a number. They are genuinely different questions and
a single blanket duration would be wrong for at least two of them.

---

## What is actually being deleted

| Class | What the purge does | What survives |
|---|---|---|
| `snapshot` | Deletes `interview_snapshots` rows **and** the stored objects they point at | Nothing of the image |
| `transcript` | Deletes `utterances` rows | The session, its scores, its results |
| `webhook_payload` | Nulls `webhook_deliveries.payload` | The delivery row: whether a customer's endpoint was told, and when |
| `participant_pii` | Nulls `participants.display_name` | `candidate_ref`, the calling system's own opaque identifier |

The last two are deliberately partial. Deleting the delivery row would destroy
an integration audit record; deleting the participant row would destroy the
audit trail without protecting anybody, since `candidate_ref` carries no
personal data on its own.

---

## The regulatory frame, and where the real weight sits

GDPR sets no fixed retention periods. Article 5(1)(e) requires personal data be
kept "no longer than is necessary" for the purpose, which means the number has
to come from the purpose, not from a table. So the question for each class is
not "what does the law say" but **"what is the last legitimate moment someone
needs this?"**

Three purposes plausibly extend the window here, and they should be named
explicitly rather than assumed:

1. **Delivering the assessment** — the customer needs the result. This is short.
2. **Contesting a result.** Article 22 gives a candidate the right to contest a
   decision based on automated processing and to obtain human review. If the
   proctoring snapshots and the transcript are deleted, that review cannot
   happen, and the candidate's right becomes unexercisable. **This is the
   binding constraint on the lower bound, and it is the one most likely to be
   overlooked**, because the pressure in a privacy review always runs toward
   shorter.
3. **Defending a discrimination claim.** Employment-discrimination limitation
   periods vary by jurisdiction and are frequently measured in years. If BEAI's
   customers rely on the assessment for hiring decisions, the evidence that the
   assessment was fair may need to outlive the assessment considerably. This is
   the argument for a longer window and it belongs to the customer's
   jurisdiction, not to BEAI's.

The snapshot class deserves separate attention: proctoring images of a person's
face are, at minimum, image data of an identifiable person, and depending on
how they are processed may attract the special-category regime in Article 9.
They are the highest-risk artifact in the system and the strongest candidate
for the shortest window of the four.

---

## What the signatory has to decide

For each class, one integer in days. Ratification is four environment
variables plus the master switch — `api/config/retention.php` is not edited,
which is what makes this a config change and never a code change:

```
RETENTION_SNAPSHOT_DAYS=          # ← decide
RETENTION_TRANSCRIPT_DAYS=        # ← decide
RETENTION_WEBHOOK_PAYLOAD_DAYS=   # ← decide
RETENTION_PARTICIPANT_PII_DAYS=   # ← decide
RETENTION_ENABLED=true
```

Set them on the Railway `api` service. Leaving one unset keeps that class
unratified and the purge keeps skipping it loudly, so the four can be ratified
independently if the snapshot question needs longer to settle than the others.

Questions the signatory needs answered first, which are business facts rather
than legal ones and which BEAI must supply:

- Which jurisdictions do customers operate in? The discrimination-claim
  limitation period is the longest constraint and it is per-jurisdiction.
- Is retention already promised to customers in a DPA or contract? A signed
  commitment overrides any number chosen here.
- Is BEAI processor or controller for this data? It changes who owns the
  decision, and different customers may put BEAI on different sides of it.
- Does any customer need a shorter window than the default? If so, retention
  is per-tenant and this config is the wrong shape — see below.

---

## One design consequence worth surfacing before ratification

`config/retention.php` is global. If any customer contract requires a shorter
window than the platform default, the purge as built cannot honour it, and
discovering that after ratification means re-opening a change that was
considered closed. This is not a reason to delay the decision — it is a reason
to ask the per-tenant question *during* it, while the answer is still cheap.

---

## Why the durations are `null` rather than a placeholder

`null` is not "keep forever" and not "delete now". It is an unratified
decision, and the purge skips that class **loudly**. A plausible-looking
default would have been the dangerous option: deletion has no undo, and a
number nobody chose is indistinguishable from a number somebody did once it is
in a config file.

---

## Verifying after ratification

```
railway ssh --service api --environment production 'php artisan beai:purge-expired-data --dry-run'
```

Run the dry run first and read what it proposes to delete, per class, before
setting `RETENTION_ENABLED=true`. The mechanism is built and tested against
fixture durations; the dry run is the only thing that will show it against
real ones.
