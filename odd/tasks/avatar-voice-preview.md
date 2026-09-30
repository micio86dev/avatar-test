# Avatar voice preview

## Objective
An operator can LISTEN to a voice wherever a voice is selectable/settable in the avatar-template form
(HeyGen `voiceId`, Tavus voice + `ttsExternalVoiceId`, Cartesia/ElevenLabs catalogue pickers, plain text
inputs and combobox rows), to judge the Italian accent before activating a template.

## Decision (user, 2026-09-29): option C (hybrid), paying a few cents is fine
- Ready-made preview audio where the provider gives one (free): ElevenLabs `preview_url` (already mapped),
  Cartesia `preview_file_url` (needs `expand[]=preview_file_url`), HeyGen `GET /v1/voices/{id}/preview` (base64, generic, not Italian).
- Italian STATIC sentence synthesised server-side for Cartesia (`POST /tts/bytes`, model sonic-3, language it)
  and ElevenLabs (`POST /v1/text-to-speech/{voice_id}`, eleven_multilingual_v2, language_code it).
- Tavus stock voices: no preview exists (no endpoint, no field) -> button disabled with an explanation.
- Tavus/HeyGen voices routed through an external Cartesia/ElevenLabs id are previewed via that vendor.
- Limit to state in the UI copy/docs: the preview proves the vendor voice, NOT how Tavus/LiveAvatar render it.

## Constraints
- Phrase is server-side only (config `avatar_preview` with version + per-language), never client text.
- Endpoint: admin/superadmin only (AvatarTemplate `create` policy), throttled (~10/min/user), voice id format-restricted,
  cache per (provider, voice, model, phrase_version, language) on the configured disk, keys never leave the server,
  provider errors mapped to clean codes (401/429/404/not-configured -> legible 4xx/503), no key in logs.
- Repo rules: T-EXPOSE-001 entry, AuthMatrix catalogue entry + fixtures (guard fails otherwise), Pest tests with HTTP fakes
  (no live calls in CI), openapi client regenerated, i18n it/en, DESIGN.md updated first for any UI rule, Bun only, TDD strict.
- Language: repo English; the Italian sample sentence is data content (allowed).
- Branches: api stacked on fix/organization-context-required; backoffice stacked on feature/organization-context-required-message.
- Local containers are built images: rebuild api + backoffice before asking the user to test ([[local-containers-are-built-images]]).

## Tasks
- [ ] P1 API: `POST /api/avatar-templates/voice-preview` (+FormRequest, service, cache, config, throttle, policy) + tests + T-EXPOSE-001 + AuthMatrix entries — route: delegated writer
- [ ] P2 API catalogue: Cartesia `expand[]=preview_file_url` -> `preview_audio_url`; HeyGen preview fetch; fix stale docblock; tests
- [ ] P3 Backoffice: reusable VoicePreviewButton molecule (play/stop/loading/error/unavailable), wired next to every voice field/combobox row; blob playback; i18n; tests; DESIGN.md
- [ ] P4 Verify: suites, mutation checks on the endpoint authz, rebuild containers, user listens (Cartesia IT voice, HeyGen, Tavus)

## Acceptance
Every voice field/row has a working listen control or a clear "preview unavailable" reason; costs bounded by cache+throttle;
no key exposure; matrix/exposure guards green.

## Progress / evidence
(empty)

## Next step
P1.

## Addendum 2026-09-29 (user): hear the voice of a Tavus PERSONA (PAL) from the "ID persona" picker
- P5 API: extend `POST /api/avatar-templates/voice-preview` with `provider: tavus` + `pal_id` (mutually exclusive with `voice_id`): the SERVER reads
  `GET /v2/pals/{pal_id}` (Tavus key, read-only, short cache), resolves `layers.tts` (engine cartesia|elevenlabs + external_voice_id + tts_model_name),
  then synthesises the Italian sample like the voice path; unavailable (tavus-auto / no external voice / azure / persona not found) -> 422/404 with a reason code.
  `layers`, `api_key`, system prompt NEVER leave the server (no new fields in the catalogue).
- P6 Backoffice: in the `pal` picker panel show a labelled "Listen to this persona's voice" block (the current "Preview not available" square stays only for pickers with nothing to play),
  with reasons for unavailable and a note that saving the template overrides the persona's stored voice.
