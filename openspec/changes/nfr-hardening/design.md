# Design: NFR Hardening (C13)

## D1 — `ai_requests` leaves the results transaction. This reverses a C9 decision.

Stated plainly because the change is not an oversight being corrected: C9 chose
the current behaviour on purpose, and C13 overturns it.

**What C9 decided** (`archive/2026-07-22-scoring-engine/design.md`, D2 CW):

> the `ai_requests` row and the `CompetencyResult` INSERT MUST run in the SAME
> transaction for each competency — so either BOTH commit or NEITHER does

**Why C13 reverses it.** A provider call is external, irreversible and **billed**.
The competency results are local and revocable. Nesting the record of the first
inside the transaction of the second means any later failure erases the evidence
of money already spent — and it fails in the direction that *hides* cost, at
exactly the moment something else has gone wrong, which is when spend tends to
spike.

**Why the reversal is safe, from C9's own text.** The stated purpose of the
coupling was to keep the resume-skip signal reliable. But the same design
document says:

> The resume-skip signal (the `CompetencyResult` row) is authoritative — do NOT
> use the presence of an `ai_requests` row as a skip signal.

and:

> Such duplicates are acceptable: `ai_requests` is append-only and the duplicate
> row is valid audit data.

So nothing depends on the coupling. The skip signal is `CompetencyResult` alone,
and C9 had already ruled that an extra `ai_requests` row is valid audit data
rather than an anomaly. Moving the write out produces, at worst, a row for a
competency whose results rolled back — which is not a defect, it is the correct
record of a call that really was made and really was billed.

The two decisions optimise for different things: C9 for atomicity of an audit
pair, C13 for never losing a cost record. Where they conflict, the cost record
wins, because the transaction can be replayed and the invoice cannot.

**Consequence for the existing test.** `tests/Feature/Jobs/AiRequestLoggingTest.php`
case (c) asserts the same-transaction behaviour by name. It is UPDATED, not
deleted, and its docblock records that it now asserts the opposite and why. A
test that quietly changes sides teaches nobody; one that says "this used to
assert X, and here is why it now asserts NOT X" survives the next reader.

## D2 — `estimated_cost_usd` is stored, not computed on read

Derived at write time from a config-driven rate table and persisted.

Computing it on read would let a later price change silently rewrite history:
last quarter's spend would move because this quarter's rates did. Stored values
are wrong only in the way an estimate is always wrong, and they stay wrong
consistently.

Named `estimated_` for the same reason. It is not an invoice, it is not
authoritative for billing, and the C11 dashboard reading it must present it as
an estimate.

## D3 — `failure_reason` carries a machine key, never a payload

An error string from a provider can echo prompt content, and prompts contain
candidate answers. This table is read by an org-scoped cost dashboard, so a
payload fragment here is a confidentiality leak with a UI in front of it.

A closed set of machine keys — `llm_parse_error`, `indicator_count_mismatch`,
`invalid_indicator_score`, `excerpt_not_verbatim`, `provider_error`,
`timeout` — is enough to aggregate by failure class, which is the only thing the
dashboard needs.

## D4 — Append-only stays, and is enforced

No `updated_at`; no `update()` in business logic; an arch guard rather than a
convention. A cost record that can be edited is not a cost record.

This is the same discipline C9 established, and C13 keeps it — the reversal in
D1 is about *when* the row is written, never about whether it can change
afterwards.

## D5 — The purge ships disabled

The mechanism is fully built and fully tested against **fixture** retention
values. The real durations are gated on open decision #2, which needs legal
sign-off, and that sign-off must additionally cover `webhook_deliveries.payload`
and `participants.display_name` — both of which postdate the original framing.

Shipping it enabled with placeholder durations would delete data nobody agreed
to delete, and deletion is the one operation with no undo. Shipping it disabled
means ratification is a config change rather than a code change.

## D6 — Audit log reuses the `ai_requests` shape

Append-only, tenant-scoped, arch-guarded, no `updated_at`. A second table with
the same discipline and the same guard, rather than a second discipline.

Before/after payloads exclude secrets by an explicit denylist
(`password`, `key_hash`, `webhook_secret`, token fields). An audit trail that
captures credentials is a breach with good intentions.
