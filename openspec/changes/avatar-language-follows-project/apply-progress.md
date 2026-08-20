# Apply progress — avatar-language-follows-project

Strict TDD is active. This is the cycle evidence. Written after `sdd-verify`
found it missing — the same omission as the previous change, which is itself
worth recording rather than quietly fixing twice.

## Releases

| Release | Contents |
|---|---|
| `api` v0.26.0 | PR 1 (cut the override, Tavus platform default at its path, closing-phrase source swap) and PR 2 (retire the operator control, one-way config migration, census comments) |
| `backoffice` v0.14.0 | PR 3 (two i18n keys) |

`api` shipped before `backoffice`. The reverse order is an operator-visible
defect: the api would still emit the FieldSpec while its translation was gone,
and the form would render the raw key.

## RED → GREEN cycles

| # | RED (observed failing) | GREEN |
|---|---|---|
| 1 | `AvatarLanguageTest` — an active template overrode the avatar's language (`expected 'it', got 'en'`) | `TemplatePayload` stops emitting the field for both providers |
| 2 | `TavusLanguageTest` — class did not exist | `App\Support\Provider\TavusLanguage::forWire()` |
| 3 | `AvatarLanguageTest` — Tavus had no language at all once the template stopped supplying it | `platformDefaultConversationFields($ctx)` writes `properties.language`, nested |
| 4 | `AvatarLanguageTest` — closing phrases resolved from the participant | both `buildSuccessResponse` call sites read `$ctx->language` |
| 5 | `StripTemplateLanguageMigrationTest` — no migration existed | one-way JSONB key-strip with a documented no-op `down()` |
| 6 | `ProviderFieldSpecTest` / `TemplatePayloadTest` / C14 API tests — configs carrying `language` were accepted | FieldSpec and `LANGUAGES` retired; the validator now rejects the key, which is correct |

## Superseded tests

Six existing tests defended the removed behaviour and were corrected in place
with the reason: the `TemplatePayload` vocabulary assertion, the Tavus golden
conversation body, and four C14 fixtures that sent `language` in a template
config.

Two fixtures were seeding BARS anchors in English only. Once the phrases
resolved from the project language, any non-English project failed composition
and the failure read as a phrase bug rather than a fixture gap.

## Defects found in my own tests, before they shipped

Three HTTP assertions in `AvatarLanguageTest` **could not fail**.
`Http::assertSent` passes when ANY recorded request satisfies its closure, and
mine returned `true` for the requests it did not care about — the `/contexts`
call alone made them green. Rewritten to pull the single `/sessions/token` body
out and assert on it directly.

The migration fixture pasted the migration's SQL inline, under a comment
claiming it "cannot drift from the thing it protects" — exactly backwards. It
now requires and runs the real migration's `up()`.

## Known gaps at close

- Two proposal questions remain OPEN and unanswerable from the repo: whether any
  real tenant has an active avatar template with a language set (needs a
  production query), and whether `participants.language` should exist at all.
- `backoffice/openapi.json` not regenerated: Scramble does not publish the
  field-spec response schema, so there is nothing to regenerate. Verified, not
  assumed.
- Pre-change template exports become unimportable — expected, not a regression.
