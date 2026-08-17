# Tasks: Configurable Error Redirect

> Strict TDD. Two repos, one PR each, mergeable in either order.

- [x] 1.1 `projects.error_redirect_url` migration, nullable, beside its sibling.
- [x] 1.2 Fillable, and validated in BOTH Store and Update requests on the same terms as `exit_redirect_url` — a divergence there would let an unvalidated URL reach a browser redirect.
- [x] 1.3 Exposed on the CANDIDATE session resource, not an admin endpoint: the party that needs it is a browser recovering from a failed interview, holding only a candidate token.
- [x] 1.4 Tests: persists, defaults to null, validated identically in both requests, reaches the resource.
- [x] 1.5 `openapi.json` regenerated. api gates green (1275 tests). **micio86dev/backend#40, merged.**
- [x] 2.1 Extend `useExitRedirect` rather than adding a second composable — same act, same endpoint; two would mean two fetches and two places for the https guard to drift.
- [x] 2.2 Shared https-only + well-formed guard for both destinations.
- [x] 2.3 Wire `error` and `terminal` to one destination. Identical candidate need; splitting would ask operators to configure a distinction candidates cannot perceive.
- [x] 2.4 Field typed OPTIONAL so the repos merge in either order; a test pins that.
- [x] 2.5 Six composable tests: both URLs from one fetch, missing field, https redirect, http refusal, malformed refusal, fetch failure degrading to the inline screen.
- [x] 2.6 Frontend gates green (422 unit, 83 E2E). **micio86dev/frontend#12, merged.**
- [x] 3.1 OpenAPI snapshot synced to both Nuxt apps so the field is contract-typed rather than a defensive guess. **frontend#13, backoffice#5, merged.**
- [x] 3.2 Wrapper submodule pointers bumped.

## Documented, Not Scoped

- **Query-string contract.** The binding doc puts "formato esatto query string o fragment" out of scope; the redirect passes nothing beyond the URL. Inventing an error-code parameter would be a contract nobody agreed to and no caller reads.
- **Retry semantics.** Open decision #4; untouched.
