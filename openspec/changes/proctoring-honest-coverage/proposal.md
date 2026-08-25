# Proposal: Proctoring Honest Coverage

## Intent

On **2026-08-25** the product owner ran a real interview, deliberately looked away from the
webcam and picked up a phone, and the session review reported **`0 eventi` — "Rischio basso,
punteggio 0"**.

Three defects sit behind that, and only two of them are about proctoring being broken.

| # | Defect | Consequence |
|---|---|---|
| 1 | Production serves **Git LFS pointer text** where `.wasm` and `.task` binaries should be | `FaceLandmarker` never initialises → `face_absent`, `looking_away`, `multiple_faces` cannot fire |
| 2 | `efficientdet_lite0.tflite` **was never committed to the repo** | `phone_detected` has never worked, in any environment, ever |
| 3 | A total absence of measurement renders as **"Rischio basso"** | The system asserts a candidate's integrity from zero observations |

**The third is the one that makes this urgent, and it is not a proctoring bug — it is a
truthfulness bug.** Defects 1 and 2 mean a feature is missing. Defect 3 means the product
makes a confident, reassuring, *false* statement about a real person on every single
interview. An operator reads "Rischio basso" as *this candidate behaved well*. The client
(Quint) may be making hiring decisions against that field.

A missing measurement and a clean measurement must never look the same.

Success = proctoring works again, **and** a proctoring outage is impossible to mistake for an
irreproachable candidate.

---

## AD-1 — "Could not observe" is an INTEGRITY EVENT, not a new subsystem

The instinct is a new endpoint, a new column, a capability handshake at session start. All
three are wrong, and the reason is already in the codebase.

`IntegrityController::store` accepts a batch validated against 13 `CANONICAL_KINDS`, enforces
participant + org ownership before any write, persists all-or-nothing, and every kind lands
in the timeline an operator reads. That pipeline already does everything a coverage signal
needs — ownership, tenancy, validation, persistence, display.

So the signal is a **14th canonical kind**: `proctor_unavailable`, whose payload names the
layer that failed to start (`face`, `phone`, `audio`).

**Why this is the right shape and not a workaround.** "The proctor could not watch this
candidate" *is* information about the integrity of the session. It belongs in the same
timeline, ordered against the same clock, as "the candidate left the frame". Modelling it
anywhere else creates a second source of truth about one question — *how much of this session
was actually observed* — and the two would drift.

**One consequence must be accepted deliberately:** `events` currently validates `min:1`, so a
client can only report that something happened. That stays. A degraded client now has
something to report, so the constraint stops being a problem instead of needing relaxation.

## AD-2 — The band becomes UNCOMPUTABLE when coverage is incomplete, not merely annotated

Adding a "coverage: partial" field beside an unchanged `band: low` is not a fix. An operator
scanning a list reads the band. Whatever we add beside it, "low" still says *fine*.

So when a layer reported itself unavailable, the summary MUST NOT return a reassuring band
for the metrics that layer feeds. The distinction is between:

- **measured, nothing found** → a genuine low-risk session, and the operator may rely on it;
- **not measured** → the system has no opinion, and must say so rather than default to the
  most flattering one.

`IntegritySummarizer` already knows this and says so in a comment at `:75-77` — *"A score of
zero does not mean nothing happened."* The insight was there; the consequence was never drawn.
This change draws it.

**Backwards compatibility is deliberately broken here, in one direction only.** Existing
sessions have no `proctor_unavailable` events, so they keep exactly today's behaviour. Only a
session that explicitly reported a dead layer renders differently. No historical evaluation is
reinterpreted.

## AD-3 — Assets come from the LOCKFILE, not from Git LFS

`scripts/proctor-assets.mjs` already exists and already does the right thing: it copies the
WASM runtime out of `node_modules/@mediapipe/tasks-vision/wasm`, which `bun install
--frozen-lockfile` has already placed there. **It is simply never run in the Docker build.**

Sourcing the WASM from the lockfile rather than LFS makes the binaries version-locked to the
MediaPipe package that the code imports — the two can no longer disagree — and removes the LFS
hydration step from every build environment forever.

The `.task` and `.tflite` **models** are different: the script downloads `face_landmarker.task`
from `storage.googleapis.com`, which puts a third-party network call inside the build. That is
a real tradeoff and is flagged as OQ-2 rather than settled here.

**`efficientdet_lite0.tflite` must be sourced regardless** — it is referenced by
`useProctor.ts:435` and has never existed. Note that `phone_detected` is **not** in
`IntegritySummarizer::WEIGHT_PER_SECOND`, so restoring it will populate the timeline without
moving the risk score. That is the behaviour ported verbatim from the legacy demo; whether it
is still intended is OQ-3.

## AD-4 — A build that produces a broken asset must FAIL THE BUILD

This is the second incident of this exact class. `scripts/proctor-assets.mjs`'s own docblock
records the first: the asset list omitted the `.js` glue loaders, they 404'd in production,
*"and face detection was dead for every interview — silently, because useProctor degrades on
failure"*.

Two silent-degradation layers stacked on each other is how a feature stays dead for weeks:
the build does not check, and the runtime does not complain. AD-1 fixes the runtime half. The
build half needs a gate that asserts every proctoring asset in the built output is a plausible
binary — a `.wasm` starting with `\0asm`, a model above a sane byte floor — and fails the
build when it is not.

**A pointer file is exactly 130-odd bytes of ASCII beginning with `version https://`. Nothing
about detecting that is subtle.** The only reason it shipped is that nobody looked.

## AD-5 — Provider-agnostic by construction

The product owner ratified on 2026-08-25 that avatar logic must be identical across HeyGen
LiveAvatar and Tavus. Proctoring runs in the candidate's browser against their own camera and
microphone; it is entirely above the provider seam and touches no provider adapter. Recorded
so the Tavus smoke is not expected to reveal proctoring differences — if it does, something is
wired wrongly.

---

## Scope

**`frontend`** — Dockerfile asset provisioning; the build-time binary gate; emit
`proctor_unavailable` when a layer fails to initialise; source `efficientdet_lite0.tflite`.

**`api`** — accept the 14th kind; `IntegritySummarizer` carries coverage and withholds a
reassuring band for unmeasured metrics; expose it through `SessionReviewResource`.

**`backoffice`** — render "non misurato" where a metric was not observed, instead of a value
that reads as a clean result. Regenerate the typed client.

**Out:** the weighting table itself (OQ-3), the excerpt relocation the owner requested the
same day (separate change), anything in the scoring pipeline.

## Blast radius

`IntegritySummarizer` — server-side only by design (its docblock: the backoffice renders what
this returns and does not recompute it), so there is exactly one place the logic changes.
Guarded by `tests/Unit/C11/IntegritySummarizerTest.php`, whose weights and band thresholds are
pinned by test precisely because "changing either changes what an operator is told about a
candidate".

`IntegrityController` — `CANONICAL_KINDS` is validated all-or-nothing, so an unrecognised kind
returns 422 and drops the whole batch. The api MUST accept `proctor_unavailable` **before** any
frontend starts sending it, or the new client will have every integrity batch rejected.
**This forces the PR order.**

## Open questions

- **OQ-1 — RATIFIED 2026-08-25 (product owner): continue, and mark it.** The interview
  proceeds and the candidate sees nothing, but the session review states plainly which signals
  were not measured and withholds the risk band rather than reporting "low". **No candidate is
  ever penalised for a failure of ours** — which is precisely what refusing to start would do,
  and precisely the situation that arose today.

- **OQ-2 — DECIDED (orchestrator): the build MAY download the models, but every download MUST
  be pinned and checksummed.** The build is already non-hermetic — `bun install
  --frozen-lockfile` requires the network — so one additional well-known host does not change
  the class of risk, while a failed download now fails the build loudly instead of shipping a
  pointer (AD-4).

  **Found while deciding this, and it is a defect in its own right:** the script fetches
  `.../float16/`**`latest`**`/face_landmarker.task`. `latest` means two builds months apart can
  ship different models with nothing recording that they differ — a proctoring result would
  change under a deploy that touched no proctoring code. The URL MUST be pinned to an explicit
  model version and the download asserted against a recorded SHA-256. An asset the build cannot
  verify is an asset the build must refuse.

- **OQ-3 — LEFT OPEN, deliberately out of scope.** `phone_detected` carries no weight in
  `IntegritySummarizer::WEIGHT_PER_SECOND`; the comment at `:75` says it belongs in the
  timeline but not the score, ported verbatim from the legacy demo. Restoring the model will
  populate the timeline without moving the risk score. Whether that is still intended is a
  product decision about what the score MEANS, and rewriting the weighting table inside a
  change whose entire purpose is to stop the summary from lying would be the wrong place to
  argue it. Raised, recorded, not answered here.

## Non-goals

- Changing any existing weight or band threshold (AD-2 changes when a band is *withheld*, never
  what a computed one means).
- Reinterpreting historical sessions.
- Any provider-specific proctoring behaviour (AD-5).
