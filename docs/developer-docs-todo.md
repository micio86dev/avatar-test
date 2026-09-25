# Developer docs — sections not yet authored

The API reference is generated: `backoffice` builds a self-hosted Scalar page
from the public `/v1` spec and serves it under `/developers/` (public-api SPEC
section 6, Q5). The reference covers every operation, schema and status code
in `api/openapi.v1.json`.

The sections below are listed in SPEC section 6 but are **not written yet**.
They are TODO and must not be presented as available.

- [x] Quickstart (backend create, hosted URL, then embed): `docs/quickstart.md`, executed by `api/tests/Feature/PublicApi/QuickstartTest.php` (part of the normal Pest suite, so no separate CI job)
- [ ] Authentication and keys
- [ ] Interviews lifecycle
- [ ] Data and exports
- [ ] Webhooks, including signature-verification sample code
- [ ] Embed SDK (`@beai/embed`)
- [ ] Test mode
- [ ] Errors reference (from the `code` enum)
- [ ] Rate limits
- [ ] Changelog
- [ ] Versioning and deprecation policy (at least 6 months notice, `Sunset` header)

Refreshing the reference after an API change:

```bash
cp api/openapi.v1.json backoffice/docs-src/openapi.v1.json
```
