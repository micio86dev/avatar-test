# Delta for Interview Session

> **Implementation note — ordering constraint (HARD GATE)**
>
> This document is a **pre-merge addendum artifact** — a coordinated C7a follow-up
> change, not a modification to the archived C7a spec (`openspec/specs/interview-session/spec.md`).
> Do NOT promote this delta into the archived spec.
>
> Required delivery order:
> 1. This addendum MUST be merged into `api/develop` as a standalone C7a follow-up PR.
> 2. After the merge, `frontend` regenerates `openapi.json` from the merged `api/develop`
>    and runs `bunx openapi-typescript openapi.json -o types/api.ts` (per the C1 `codegen`
>    script, D8 in the C7b design).
> 3. ONLY after step 2 may the C7b `apply` phase begin. No C7b file that calls `/start`
>    or consumes `question_context.end_phrase` / `question_context.final_phrase` may be
>    written before `types/api.ts` includes these fields.
>
> Until this gate is cleared, C7b cannot correctly complete an `en`-language HeyGen session
> (the frontend would have no phrase to match and the HeyGen provider would error on `absent end_phrase`).

## ADDED Requirements

### Requirement: POST /start question_context — localized completion phrases

`POST /api/candidate/interview/start` MUST include `end_phrase` and `final_phrase` fields
in the `question_context` response object. Both strings MUST be the completion-signal
phrases the avatar will speak at the end of an intermediate question and at the end of the
final question, respectively, localized to the project language. The frontend consumes
these fields as the SOLE source for completion-signal detection; it MUST NOT contain
hardcoded phrase strings. If the project language is unavailable for a phrase, the backend
MUST fall back to the platform default language and MUST include the fallback phrase in the
response (an absent field is a contract violation).

This addendum is a backward-compatible addition to the existing `/start` response shape
(C7a). The five-endpoint contract and all other `question_context` fields are unchanged.
`POST /end` continues to return `200` on success — there is NO `203` variant. Last-competency
detection is performed client-side by the frontend (tracking `question_index` against the
total competency count from the C6 bootstrap); the backend does not signal "last question"
via a distinct HTTP status.

#### Scenario: /start returns end_phrase in project language (it)

- GIVEN a project with `language = 'it'`
- WHEN `POST /start` returns `201`
- THEN `question_context.end_phrase` is a non-empty string in Italian (the inter-question
  completion phrase) and `question_context.final_phrase` is a non-empty string in Italian
  (the closing thank-you phrase)

#### Scenario: /start returns end_phrase in project language (en)

- GIVEN a project with `language = 'en'`
- WHEN `POST /start` returns `201`
- THEN `question_context.end_phrase` and `question_context.final_phrase` are non-empty
  English strings; no Italian phrase is present in either field

#### Scenario: end_phrase and final_phrase are never absent

- GIVEN any valid project language
- WHEN `POST /start` returns `201`
- THEN `question_context.end_phrase` and `question_context.final_phrase` are both present
  and non-null in the response body
