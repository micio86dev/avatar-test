# Proposal: Backoffice Same-Origin API

## Intent

**Safari users cannot hold a backoffice session.** Every page reload sends them back to the
login screen. This is live in production and predates today's work; it became visible only
because repairing the E2E suite finally let the gate that watches for it run.

The proof chain, each link verified on 2026-08-25:

1. `up.railway.app` is on the **Public Suffix List** — line 15372, submitted by Railway itself.
2. Production hosts are `backoffice-production-ec05.up.railway.app` and
   `api-production-640e.up.railway.app`, with **no custom domains on either**.
3. Because `up.railway.app` is a public suffix, each service's registrable domain is its own
   full hostname. The two are therefore different **sites**, not merely different hosts.
4. `beai_refresh` is set by the api and sent from the backoffice, so it is a **third-party
   cookie**. `Secure` and `SameSite=None` do not override WebKit's third-party blocking.
5. `tests/e2e/session-cookie.spec.ts` reproduces it: green on Chromium, red on WebKit.
   Switching the probe to `https://` did **not** help, which eliminates the
   "WebKit rejects Secure over http://localhost" hypothesis that test's own docblock had
   pre-registered as the likely cause.

The access token is memory-only by design, so every hard reload depends on that cookie. On
Safari it was never stored. `CLAUDE.md` lists Safari as a **supported** browser.

Success = the browser talks to exactly one origin, so the refresh cookie is first-party and
the question of third-party blocking never arises.

---

## AD-1 — Serve the API from the backoffice's own origin, via nginx

The backoffice is a static SPA served by `nginx:1.27.5-alpine`. It gains one location block
that proxies `/api/` to the API service. The browser then sees a single origin.

**Why this and not custom domains.** Two hostnames under one registrable domain
(`app.beai.tld` + `api.beai.tld`) would also fix it, and is the textbook answer. It is
unavailable: the product currently has only Railway's generated domains, and buying and
wiring DNS is not something to do at 2am on someone else's behalf. The proxy needs no DNS,
no certificate, and no coordination — and it remains correct if custom domains arrive later.

**Why this is not merely a Safari patch.** Same-origin also removes CORS from the backoffice
path entirely. That allowlist is live configuration with its own incident history —
`hotfix/0.22.3`, *"fail loud on an empty allowlist outside local/testing"*. Deleting a
configuration surface is worth more than the bug that prompted it.

**The cookie needs no change.** It is scoped `Path=/api/auth/refresh`, and the API already
serves under `/api`. Proxying `/api/` straight through preserves the path exactly, so the
existing `Secure; HttpOnly; SameSite=None` cookie keeps working — now as a first-party
cookie. Nothing about its security properties is weakened; that is the point.

## AD-2 — The proxy target is a BUILD ARG, not runtime templating

`NUXT_PUBLIC_API_BASE` is already a build `ARG`, baked into the bundle and then **asserted to
have reached it** (`Dockerfile:108`). The proxy target follows the same pattern.

**Why not the nginx template + envsubst mechanism.** It is the more fashionable answer and it
is worse here. The runtime stage ends with `USER nginx` (non-root), so entrypoint substitution
writes into `/etc/nginx/conf.d` as an unprivileged user; and envsubst would happily eat
nginx's own `$uri`/`$host` unless fenced off with `NGINX_ENVSUBST_FILTER`. Both are solvable
and both are new failure modes, introduced to configure a value that does not change between
restarts. Baking it matches the decision this image already made for the API base.

A literal target also avoids nginx's rule that a `proxy_pass` containing a variable requires
a `resolver` — one more moving part removed rather than configured.

## AD-3 — A cross-origin API base must FAIL THE BUILD

The fix is one environment variable away from being silently undone. Set
`NUXT_PUBLIC_API_BASE` back to an absolute URL and Safari breaks again, with nothing
anywhere saying so — the same shape as every other defect found today.

So the build asserts the baked API base is **relative**, and says why when it is not. This
sits beside the two assertions already in that file, which exist for exactly this reason:
*"a value that is silently dropped between the platform and the bundle is invisible from the
outside, which is why it has to be asserted from the inside."*

## AD-4 — The WebKit cross-site probe is RETIRED, not repaired

`tests/e2e/session-cookie.spec.ts` verifies that WebKit stores a **cross-site**
`Secure; SameSite=None` cookie. Its docblock is explicit that it is a browser-behaviour probe,
not an app test, and that a WebKit failure *"MUST fail the build, never be silently skipped"*.

It did its job. It failed, it was right, and this change is the response.

Once the browser only ever sees one origin, the property it probes is **no longer one the
product depends on**. Keeping it would leave a permanently red gate guarding an architecture
that no longer exists; skipping it would be the silent-skip its own docblock forbids.

**Deleting a failing test is normally indefensible, so the distinction matters:** this test is
not being removed because it fails. It is being removed because the design decision it
gated — D11's cross-site refresh cookie — is superseded by AD-1. Its replacement is AD-3's
build assertion, which guards the new invariant instead of the retired one.

## Scope

**`backoffice` only.** `Dockerfile` (proxy location, build args, assertions), the
`NUXT_PUBLIC_API_BASE` value, and retiring the superseded probe.

**Out:** the candidate `frontend` — it authenticates with a short-lived JWT from the
magic link, not a refresh cookie, so it does not have this problem. The API's CORS
configuration stays as it is: other clients still use it, and removing it belongs to whoever
retires the last cross-origin caller.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Proxy misroutes and the whole panel 404s | **HIGH** | `^~ /api/` outranks the SPA fallback and the asset regex; verified against a running container before deploy |
| Cookie path stops matching | HIGH | Path preserved exactly — `proxy_pass` with no URI part keeps the original request URI |
| Someone reverts the API base later | MEDIUM | AD-3 fails the build |
| Extra hop adds latency | LOW | An operator panel, not the interview path |

## Open questions

None blocking. Custom domains remain the better long-term answer and this change does not
prevent them.
