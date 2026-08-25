# Delta for Webhooks Integration

## MODIFIED Requirements

### Requirement: evaluation payload — status, reliability reuse, files (partial)

The `evaluation` webhook payload MUST carry: the `candidate_ref` verbatim (unchanged
from ingress), a project reference, `status` ∈ `{completed, pending}`, a `version`
field, and `evaluation.text` per competency (score, `reliability`, behaviors). The
`reliability` value MUST be produced by the existing C9 rendering rule
(`openspec/specs/scoring-engine/spec.md` Requirement: Reliability (R-A) and Validity
(V-A) — `(int) round($reliabilityDbValue * 100, 0, PHP_ROUND_HALF_UP)`) and MUST NOT be
recomputed or re-derived by this capability.

Each competency entry in `evaluation.text` MUST additionally carry `unscorable_reason`
when that competency was NOT scored (`anchor_translation_missing`, `role_no_bars`,
`llm_parse_error`, or `llm_truncated` — see `scoring-engine`), and MUST omit the field
(absent or null) when the competency scored normally. This lets an integrator making a
selection decision distinguish "the candidate gave no assessable evidence" from "the
scorer failed on our side" — today's payload gives a zeroed competency with no way to
tell those apart. `unscorable_reason` is a machine-facing value and MUST NOT be
localized by this capability — it is emitted literally, exactly as persisted.

The payload MUST also carry an `evaluation.files` object containing `transcript` (an
API-resolvable reference to the DB-backed transcript) and `evaluation_raw` (a reference
to the persisted C9 `Evaluation` record). `files` MUST NOT contain an `audio` key in this
version. `files` MUST be documented and treated by receivers as an OPEN, EXTENSIBLE map:
a spec-compliant receiver MUST NOT reject the payload or assume a closed key set, so that
adding an `audio` key in a future version is additive, not breaking. Per the Payload
Schema Versioning requirement, the addition of `unscorable_reason` to a competency
entry is likewise additive and does NOT require a `version` bump — a receiver
tolerating unknown/absent fields in `evaluation.text` entries (the same posture already
required for `files`) is unaffected.
(Previously: `evaluation.text` carried only score, `reliability`, and behaviors per
competency, with no way to distinguish an unscorable competency from one genuinely
scored at the floor of its rubric, and the payload contract was silent on whether
adding a field to a competency entry is additive or version-breaking.)

#### Scenario: Completed evaluation payload carries candidate_ref, status, and reused reliability

- GIVEN a terminal `Evaluation` with `status = completed` and competency SLF at 2/3 assessed indicators (reliability 0.667)
- WHEN the `evaluation` webhook payload is assembled
- THEN `candidate_ref` matches the ingress value byte-for-byte, `status = "completed"`, and SLF's rendered reliability = `"67%"` (same rounding as the C9 API boundary, not re-derived)

#### Scenario: files block present with transcript and evaluation_raw, no audio key

- GIVEN any terminal Evaluation
- WHEN the `evaluation` payload is assembled
- THEN `evaluation.files.transcript` and `evaluation.files.evaluation_raw` are present non-null references
- AND `evaluation.files` contains NO `audio` key
- AND the payload documentation states `files` is an open map (future keys are additive)

#### Scenario: Pending evaluation still produces a delivered webhook

- GIVEN a terminal `Evaluation` with `status = pending` (below the 90% valid-competency gate)
- WHEN scoring reaches this terminal state
- THEN an `evaluation` webhook is delivered with `status = "pending"` and partial competency data — delivery is not blocked by the pending status

#### Scenario: An unscorable competency's payload entry carries its reason

- GIVEN a terminal Evaluation where competency PRS is `unscorable_reason = 'llm_truncated'`
- WHEN the `evaluation` payload is assembled
- THEN PRS's entry in `evaluation.text` carries `unscorable_reason: "llm_truncated"` (unlocalized)
- AND a scored sibling competency's entry carries no `unscorable_reason` field

#### Scenario: unscorable_reason presence does not change payload_version

- GIVEN the current `payload_version`/`version` value shipped before this change
- WHEN a payload containing a competency with `unscorable_reason` is assembled after this change
- THEN the `version` field is UNCHANGED from its pre-change value — this addition is
  additive, not a schema-breaking change

---

### Requirement: Payload schema versioning

Every webhook payload body MUST carry an explicit `version` field identifying the
payload schema version, independent of and in addition to the `X-BEAI-Signature: v1=`
prefix (which versions the signature scheme, not the payload shape).

`version` MUST be bumped only for a BREAKING change to the payload's structure — a
field removed, a field's meaning or type changed, or a receiver's existing parsing
logic (built to tolerate unknown fields, per the `files` open-map precedent) would
plausibly fail. A NEW, purely additive field on an already-open structure (a new
optional key inside `evaluation.text`'s per-competency object, mirroring the existing
`files` open-map contract) MUST NOT bump `version`. This is a deliberate,
explicitly-decided rule, not an oversight: CLAUDE.md's "no legacy backward
compatibility" stance governs whether BEAI must keep old FORMATS alive forever (it does
not need to), which is a separate question from whether `version` itself carries
meaning for receivers deciding how to parse a body — it still does, and only bumps on
breaking change.

(Previously: stated only that every payload carries a `version` field, silent on what
triggers a bump versus what is additive.)

#### Scenario: Every delivered payload carries a version field

- GIVEN any `progress` or `evaluation` delivery
- WHEN the outbound JSON body is inspected
- THEN a top-level `version` field is present and non-empty, independent of the `v1=` signature prefix

#### Scenario: Adding unscorable_reason to a competency entry does not bump version

- GIVEN the `evaluation` payload gains `unscorable_reason` on unscorable competency entries (this change)
- WHEN the `version` value before and after this change is compared
- THEN it is unchanged — the addition is additive, matching the `files` open-map precedent, not a breaking structural change

#### Scenario: A future field removal or type change WOULD require a version bump

- GIVEN a hypothetical future change that removes `candidate_ref` or changes
  `reliability` from a percentage string to a raw fraction
- WHEN that change is evaluated against this requirement
- THEN it MUST bump `version` — such a change is breaking, unlike this change's
  additive `unscorable_reason` field
