# Default Interview Questions

**Data file**: [`default-questions.json`](default-questions.json), next to this file.

These are the platform's **default** primary questions for every competency in
the catalogue. They are a starting point, not a fixed script:

- A project receives a **snapshot copy** of the defaults for its competencies
  when it is created. Later edits to the defaults never reach a project that
  already exists.
- Operators can **edit a project's questions** per project. An edited question
  belongs to that project only.
- Inside the platform, defaults live in `framework_default_questions`, one row
  per question, versioned with the catalogue revision and edited through the
  catalogue API. This file is the reviewable, authored source for that content.
  `catalogue:import` / `catalogue:export` do **not** carry default questions —
  `catalogue:seed-default-questions` (api) is the loader: it reads the
  vendored copy at `api/database/framework/default-questions.json`, writes
  each competency's questions into the open draft, and can publish it.

## Vendoring

The Cross-Stack Consistency job (`.github/workflows/wrapper-ci.yml`, step (d))
requires every `*.json` under `framework/` to also exist, identical, in
`api/database/framework/` — the same rule `roles.json`/`competencies.json`/
`bars/*.json` already follow. `api/database/framework/default-questions.json`
is that vendored copy; keep the two in sync by hand until an export path
exists, exactly like the other framework JSON files.

## Shape

```json
{ "version": 1, "questions": { "<CODE>": [ { "position": 0, "text": { "en": "...", "it": "..." } } ] } }
```

`position` is 0-based and matches the `position` column of
`framework_default_questions`. `text` is a locale map, the same shape as that
column.

## Counts

| Assessment type | Competencies | Questions per competency |
|---|---|---|
| `standard` | the 18 standard codes (PRS ... INC) | exactly **1**: the avatar asks it, then the LLM asks follow-ups |
| `potential` | MTG, LAT | exactly **4** (the platform maximum and default), each covering a different part of the competency's definition |

## Authoring rules

This is a BEI (Behavioral Event Interview). Every question asks about
**behaviour that actually happened**, never a hypothetical.

1. **One real, recent episode.** Ask for one specific, recent situation that
   fits the competency's definition in `framework/competencies.json`. Never ask
   "what would you do if...".
2. **Spoken, and addressed to the candidate.** The avatar reads the text aloud
   as the opening for that competency, with no greeting added before it. Write
   for the ear: short sentences, no parentheses, no lists.
3. **One ask, at most one short follow-on.** For example, "Tell me about a
   time when... What did you do?". Never several questions in a row.
4. **End with a question mark.** The avatar then waits for an answer. A
   statement leaves the conversation with no turn to answer.
5. **Neutral and non-leading.** Do not suggest the right answer and do not
   judge. Do not presume a good outcome ("how did you solve it" becomes "what
   did you do").
6. **Never name the competency.** No competency names or codes read aloud.
7. **No jargon.** Plain business language any candidate understands.
8. **Role-neutral where the competency is shared.** One default serves every
   role that carries the competency, including ICO, which has no reports. Only
   leader-only competencies (TMG, INS) may assume the candidate manages people.
9. **Inclusive Italian.** Use informal *tu*, as the avatar's opening templates
   do (`api/lang/it/interview.php`). Avoid past participles and adjectives
   that take the candidate's gender ("ti sei trovato/a", "sei stato/a").
   Rephrase with an active verb instead ("hai dovuto", "ti è capitato").
10. **Faithful and natural in both languages.** The `en` and `it` texts ask the
    same thing. Neither is a word-for-word copy that reads as a translation.
11. **Orthography.** ASCII apostrophe only (`'`), no leading or trailing
    whitespace, no empty strings.

## Checking

```sh
jq . docs/app_description/02-domain/framework/default-questions.json
```

Beyond parsing, check that every code in `framework/competencies.json` is
present with the right count (1, or 4 for MTG/LAT), that positions run
`0..n-1`, that both `en` and `it` are non-empty, and that every text ends with
`?`.
