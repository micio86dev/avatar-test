# Delta for Scoring Engine

No behavioural change: the L-2 hard-fail, the no-EN-fallback rule, and the
`unscorable_reason` enum stay exactly as delivered. What changes is a fact
about the catalogue this requirement reads: `anchor_translation_missing`
stops firing for `it` on role×competency pairs the
`framework-catalog-it-translations` change has translated. The requirement
below is copied in full (per delta convention) with new scenarios that
restate coverage against the real, partially-translated catalogue instead of
only against fixtures — mirroring how `bars-catalogue-completion` had to
restate its SRX-named scenarios once SRX stopped being a fixture-only case.

## MODIFIED Requirements

### Requirement: Non-EN Anchor Language (L-2 Hard-Fail)

The engine MUST score each competency in the project's configured language.
`PromptBuilder` MUST check translations via `hasTranslation($field,
$projectLocale)` for ALL FOUR translatable fields of each `BarsIndicator`:
`text`, `anchor_5`, `anchor_3`, and `anchor_1`. It MUST NOT use the
convenience method `hasTranslationGap()` (hardcoded to `'it'`, which would
silently mis-evaluate non-IT projects). A missing `indicator.text`
translation in the project locale is as corrupting as a missing anchor — the
prompt would inject an EN indicator description alongside localized
anchors, producing an incoherent rubric. If ANY of the four fields is
missing a project-locale translation, the engine MUST hard-fail that
competency: mark it unscorable and record the reason as
`anchor_translation_missing`. The engine MUST NEVER silently fall back to
English for any of the four fields. An unscorable competency counts against
the 90% gate (see Completion Gate requirement for the full policy and
config-flaggable override).
(Previously: no real catalogue row carried an `it` translation, so every
scenario against `it` exercised only factory/fixture data; this restates
scenarios against the real, partially-translated catalogue.)

#### Scenario: Missing IT anchor → competency hard-failed, no EN fallback

- GIVEN project language = `it` and competency COL has no Italian anchor translations for `anchor_5`
- WHEN the engine attempts to score COL
- THEN COL is marked unscorable with reason `anchor_translation_missing`
- AND NO LLM call is made using English anchors
- AND the `hasTranslation($field, 'it')` check (not `hasTranslationGap()`) is used for each of {text, anchor_5, anchor_3, anchor_1}

#### Scenario: Missing IT indicator text → competency hard-failed (text field in scope)

- GIVEN project language = `it` and competency INN has all three anchor translations but no Italian `text` for one indicator
- WHEN the engine checks translations for INN
- THEN INN is marked unscorable with reason `anchor_translation_missing`
- AND no LLM call is made (missing `text` in project locale is a hard-fail, same as missing anchor)

#### Scenario: Present anchor passes through normally

- GIVEN project language = `it` and competency COM has Italian anchor translations
- WHEN the engine scores COM
- THEN the Italian anchor texts are injected into the prompt and scoring proceeds normally

#### Scenario: A fully-translated role scores every competency in Italian (real catalogue, ICO scope)

- GIVEN a project pinned to role ICO with language = `it`, and ICO's full
  role×competency scope is translated per `framework-catalog-it-translations`
- WHEN the engine scores every competency for that participant
- THEN no competency is marked unscorable with `anchor_translation_missing`
- AND every prompt is composed entirely from Italian text (no EN fallback
  occurs for any of the four fields on any indicator)

#### Scenario: Partial coverage — one role translated, a sibling role is not

- GIVEN role ICO is fully translated to `it` and role FLL is not yet
  translated (still mid-slice)
- WHEN an `it`-language project pinned to ICO is scored
- THEN all of that project's competencies score normally with no hard-fail
- GIVEN a separate `it`-language project pinned to FLL, scored in the same
  deployment
- WHEN FLL's untranslated competencies are scored
- THEN each untranslated FLL competency is still marked unscorable with
  `anchor_translation_missing` (the per-competency hard-fail is unaffected
  by ICO's translated state — coverage is evaluated per pair, not globally)
