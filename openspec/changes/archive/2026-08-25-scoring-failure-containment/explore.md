# Exploration — Scoring Failure Containment

Five related gaps in one family: **the scorer hits a problem and destroys an entire
competency instead of degrading**.

**Phase:** explore · **Status:** ready for proposal, with a recommended A/B split and two
open design questions.

---

## The incident this comes from

2026-08-24, participant 19, `evaluation_id` 6. Five competencies out of five at 0%:

```
WARNING: parse/validation error — llm_parse_error {"competency_code":"PRS","error":"JSON parse error: Syntax error."}
… identical for STG, DRV, COM, COL
INFO: evaluation finalized {"evaluation_id":6,"status":"pending","valid_count":0,"total_count":5}
```

**The root cause is still unknown, and that is itself the finding.** The raw response is
never persisted, so two very different failures are indistinguishable after the fact: a
markdown-fenced JSON body, or a response truncated at `max_tokens` (2048).

---

## Current State — the failure path end to end

1. `AnthropicLLMProvider::parseResponse()` (`:121-147`) reads `stop_reason` into
   `LLMResponse::$finishReason`, carries it to `ai_requests.finish_reason` — and **no code
   branch ever inspects its value**. `max_tokens` is indistinguishable from `end_turn`
   downstream.
2. `EvaluationParser::parse()` (`:46-50`) calls `json_decode()` with **no pre-processing**.
   A fence or any leading prose throws `JsonParseException` carrying the bare
   `json_last_error_msg()` — exactly the "Syntax error" seen in production.
3. `ScoreEvaluationJob::scoreCompetency()` (`:640-678`) validates **all** DTOs inside **one**
   `try`. A single catch spans the whole competency, so **any** failure discards **every**
   indicator — including ones that validated successfully earlier in the same loop.
4. On catch: one `ai_requests` row with `success=false` and a closed-set `failure_reason`,
   then `persistUnscorable()` writes `score=null`, `reliability=0.0`, `valid=false`,
   `unscorable_reason='llm_parse_error'` and **zero** `IndicatorScore` rows.
5. `CompletionGate` counts valid results against `project.competencies()->count()`.
   Five unscorable of five → `valid_count=0` → `pending`.

### What already exists

- `AiRequestFailureReason` is a **closed set of 6** machine keys enforced by a Postgres
  CHECK constraint (`ai_requests_failure_reason_check`). **No truncation value exists**, and
  adding one is a migration, not config.
- `CompetencyResult.unscorable_reason` is a **plain string column — no cast, no CHECK**.
  Adding a value is schema-safe. BUT `openspec/specs/scoring-engine/spec.md` (Coverage Note,
  ~line 823) pins the enum at exactly three values as normative text.
- `ScoreEvaluationJob` already has queue retry (`$tries = 3`, `$backoff = 60`), but D4 FIX-9
  deliberately RETURNS instead of throwing on parse errors, so it never fires for this class.
  There is no per-call retry-with-a-different-budget anywhere.
- `RetryClassifier` (`app/Services/Webhooks/`) is an architectural precedent for a
  "is this worth retrying" classifier — not reusable code, but the right shape.

### Confirmed: the operator is told nothing

`AdminEvaluationSerializer::serializeCompetencyResult()` (`:133-149`) returns exactly
`{score, reliability, behaviors}`. **`unscorable_reason` is not read, not serialized, not
exposed.** The operator sees `score: null`, `reliability: "0%"`, `behaviors: []` and no
indication of why. This is the operator-facing half of the bug.

---

## Retry semantics are NOT gated by open product decision #4

Worth stating loudly, because the word "retry" collides.

Product decision #4 / RT-B in `scoring-engine/spec.md` (`:713-784`) is a **domain-level
candidate retry**: re-issuing a magic link, re-interviewing invalid competencies, merging
into the same Evaluation row. A cross-slice C6/C7/C9 UX decision, deferred pending product
ratification.

What this change needs is a **queue-job-internal, same-competency, same-interview** retry of
one LLM call with a larger budget. Different concept entirely. The proposal must say so
explicitly so a reviewer does not conflate them.

---

## The GDPR constraint is sharper than assumed

`openspec/specs/data-retention/spec.md` (`:46-56`) enumerates exactly **four** candidate-data
classes: `snapshot`, `transcript`, `webhook_payload`, `participant_pii`. **`ai_requests` is
not among them** — correctly, because today it carries no verbatim content.

A raw substring of a scoring response — even ~120 characters — would very likely contain
candidate-derived content, since the response IS the model's rendering of the transcript. That
makes `ai_requests` a **fifth candidate-data class with no ratified retention duration**,
mirroring the "shipped but not legally closed" situation CLAUDE.md already flags for
`webhook_deliveries.payload` and `participants.display_name` (product decision #2, still
awaiting legal sign-off).

`openspec/specs/observability/spec.md` (`:383-465`) independently states that `failure_reason`
records why the result was unusable **"never the raw provider payload"**.

**Consequence:** the diagnostic fingerprint must be **derived signals only** —
`finish_reason`, `output_tokens`, response byte length, a "starts with a fence" boolean, a
response hash. Raw substrings must be explicitly deferred pending a legal answer, not
defaulted to "small enough to be safe".

And they are sufficient: with truncation detection in place, `finish_reason = max_tokens`
identifies a truncation and the fence boolean identifies the other case. The raw text buys
very little that the derived signals do not already give.

---

## Approaches

**1 — Fence and prose tolerance in `EvaluationParser`.** Strip a leading/trailing fence before
`json_decode`; keep hard-fail otherwise. *Low effort.* Fixes one suspected root cause, not the
other.

**2 — `finish_reason`-aware truncation detection.** Check `finishReason === 'max_tokens'`
before parsing and short-circuit to a distinct failure class. *Low–Medium.* Turns a guess into
a certainty at negligible cost — the signal already flows through the pipe unused. Needs a
migration (CHECK constraint) and a spec amendment (the pinned three-value enum).

**3 — In-job retry with a larger `max_tokens`, on truncation only.** *Medium.* Turns an
unrecoverable, already-billed failure into a self-healing one. Preserves D4 FIX-9 for the
classes it correctly applies to: fence, prose, count mismatch, invalid score and non-verbatim
excerpt all stay non-retryable. Only truncation-at-a-given-budget is carved out, because its
determinism does not extend to a *different* budget. Needs a cap, and the retry attempt needs
its own `ai_requests` row.

**4 — Per-indicator isolation.** *Medium–High. The hard one.* Catch validation failures
per-DTO, persist the indicators that passed. Requires deciding what a validation-failed
indicator IS — see Open Questions.

**5 — Bounded diagnostic fingerprint, derived signals only.** *Low.* See the GDPR section.
The raw-substring variant is *High* effort once its legal chain is counted, and is not
recommended.

---

## Recommendation — split into two increments

**Increment A (low risk):** approaches 1 + 2 + 5, plus surfacing `unscorable_reason` in
`AdminEvaluationSerializer`. This alone would have made the production incident visible
instead of silent, and each piece is independently testable.

**Increment B (higher risk, needs a design-phase decision):** approach 3 (depends on A's
detection existing) and approach 4.

---

## Open Questions for the proposal

1. **What is a validation-failed indicator?** (gates approach 4)
   - (a) fold into the existing `-1` unassessable sentinel;
   - (b) a new sentinel value — would break the `{1,2,3,4,5,-1}` domain just ratified and
     shipped;
   - (c) out-of-band metadata, with `-1` kept for the arithmetic.

   Whichever is chosen, `MeanCalculator`, `AssessableFractionReliability` and `CompletionGate`
   must agree on what "total" means. Note that (a) conflates "the model said there was no
   evidence" with "the model claimed evidence we could not verify" — two different facts the
   operator cannot then tell apart.

2. **Raw substrings in the fingerprint** — deferred pending legal sign-off, or dropped
   permanently in favour of derived signals?

---

## Risks

1. A new `AiRequestFailureReason` requires a coordinated Postgres CHECK migration — a
   blocking dependency for Increment A.
2. The pinned "three values" line in `scoring-engine/spec.md` is normative text that must be
   amended explicitly, or a future reader reads the new value as a regression.
3. Per-indicator isolation touches three formula classes tied to **RATIFIED** product
   decision #1. Any change to what counts in "total" must be argued against that ratification,
   never silently reinterpreted.
4. The raw-substring fingerprint variant intersects a **pending legal sign-off** — a genuine
   blocker for that variant specifically, not for the derived-signal one.
5. A truncation retry increases cost-of-failure (a second billed call); needs a cap, and the
   retry must get its own `ai_requests` row per the existing every-call-is-logged requirement.
6. **No existing cassette exercises a fenced or truncated response.** All three golden
   cassettes are clean JSON, so Increment A needs new fixtures, not just new assertions.

---

## Test Blast Radius

`EvaluationParserTest`, `ExcerptValidatorTest`, `ExcerptVerbatimTest`,
`ScoreEvaluationJobDefensiveBranchesTest`, `AiRequestLoggingTest`,
`AdminEvaluationSerializerTest`, plus new fenced/truncated cassette fixtures.

**Next recommended:** `sdd-propose`
