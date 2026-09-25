# BEAI SDKs

Client SDKs for the public `/v1` API, generated from `api/openapi.v1.json` with
[openapi-generator](https://openapi-generator.tech) (version pinned in
`openapitools.json` and `docs/version-catalog.md`).

| Directory | Package | Generator |
|---|---|---|
| `typescript/` | `@beai/sdk` | `typescript-fetch` |
| `php/` | `beai/beai-php` | `php` |
| `python/` | `beai` | `python` |

**These directories are generated. Never edit them by hand** — change the API
spec (or `generate.sh`) and regenerate. Docs and tests are skipped to keep the
tree small. Hand-written client code lives only in `@beai/embed`.

## Regenerate

```sh
sh sdks/generate.sh   # needs Bun, Java 11+, python3
sh sdks/smoke.sh      # typecheck + instantiate TS, lint PHP, parse Python
```

CI regenerates on every run and fails if the committed output differs.

`generate.sh` feeds the generators a copy of the spec in which the api's
`errors: null` schema is rewritten as a nullable string: generator 7.25.0 crashes
on it (Python) or imports a model it never emits (TypeScript).

## Publishing

Not done here. Splitting these directories into their own repositories and
publishing to npm, Packagist and PyPI is a separate release step.
