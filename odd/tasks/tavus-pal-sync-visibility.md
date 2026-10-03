# Tavus persona sync: make failures visible, know which personas are editable, keep the Italian TTS model

## Problem (verified 2026-09-29, local)
Template 4 (org 6, Tavus, palId p89b602b1174 "Theo - Trivia Master", ttsEngine cartesia, external voice set in the backoffice):
the candidate hears a different voice. Root cause: `TavusPalSync` PATCH `/v2/pals/p89b602b1174` answers HTTP 400
`{"message":"Invalid persona_id"}` (reproduced with the user's authorization; log lines "Tavus PAL sync failed status 400" x2), while GET on the same
persona works. The persona still has `layers.tts.external_voice_id = ""`. The persona is not one the team authored (own personas: "Colloquio IT",
"quint avatar tester", ...; it is in neither Tavus's `persona_type=user` (10) nor `system` (30) lists although the unfiltered list has 46).
Ownership/editability is NOT proven, only strongly suggested. The failure is invisible: `TavusPalSync::sync()` returns a transient warning, persists nothing,
and the catalogue picker exposes only id+name.
Second finding: the PATCH is `add /layers` (replaces the WHOLE node), and BEAI never sends `tts_model_name` (Tavus docs: Italian needs Cartesia `sonic-3`;
`sonic-2` has no Italian; the persona above has `sonic-3.5`), so a synced persona silently falls back to Tavus's default TTS model.

## Scope
- P1 API: (a) persist the LAST PAL sync outcome per template (status, sanitized code/message, timestamp) and expose it in the template resource;
  map Tavus 400/401/403/404/5xx to stable codes (e.g. `pal_not_editable` for "Invalid persona_id", `pal_sync_failed`, `pal_sync_unreachable`, `tavus_key_missing`, `pal_id_missing`),
  never storing provider bodies/keys; (b) catalogue: mark each Tavus persona as `editable` when it is in Tavus's `persona_type=user` list (document that definition), plus
  the `persona_type` if known; unknown stays unknown, not "editable"; (c) new Tavus field `ttsModelName` (palPath layers/tts/tts_model_name; Select of documented values for
  the chosen engine, sane default that supports Italian, e.g. cartesia -> sonic-3; ElevenLabs -> eleven_multilingual_v2), validated and sent in the layers; (d) on save with a non-editable persona
  and persona-level knobs set, keep saving but return the warning code.
- P2 Backoffice: show the sync state on the template (list row + form banner) with translated actionable messages ("Tavus refused to modify this persona: choose one of your own personas"),
  a badge/hint in the persona picker for editable vs not editable vs unknown, the new `ttsModelName` field, i18n it/en, tests, DESIGN.md.
- P3 Verify: suites, mutation checks, rebuild containers, user re-saves template 4 with one of his own personas (e.g. a "Colloquio IT") and listens from the frontend.

## Constraints
Strict TDD, no live provider calls in tests (Http::fake), AuthMatrix/openapi/typed-client conventions, repo language English, i18n it/en, conventional commits, branches stacked on
feature/avatar-template-duplicate (api) and feature/avatar-template-duplicate-ui (backoffice), local containers are built images (rebuild + hard reload).
User authorization on record (2026-09-29): read persona p89b602b1174 and replay the save PATCH once. NO other Tavus mutation without asking again.

## Tasks
- [x] P1 api (merged: api PR #82)
- [x] P2 backoffice (merged: backoffice PR #48)
- [x] P3 verify (user confirmed 2026-10-03: Tavus templates show the green "Persona sincronizzata" tag, correct) + user listens (voice listening is covered by avatar-voice-preview P4)

## Next step
P1 (api writer).
