# Frontend same-origin API

## Why

`NUXT_PUBLIC_API_BASE` held `http://api:8000/api`. That is correct for SSR,
which runs inside the Docker network, and unresolvable in a browser running on
the developer's machine.

`pages/interview/[token].vue` is `ssr: false`, so the BROWSER made that call. It
failed on DNS, and that page routes every non-401 failure to `reason=403` — so a
candidate opening a freshly generated, never-used link was told their session
was not authorised. The link was valid. The request never left the laptop.

A `NUXT_PUBLIC_*` value is shipped to the browser by definition, so it has to be
browser-reachable; inside the container `localhost` is the container itself, and
a Docker hostname means nothing outside it. **One value cannot serve both
sides.**

## This proposal corrects the record, not only the code

`openspec/changes/backoffice-same-origin-api/proposal.md:100` says:

> **Out:** the candidate `frontend` — it authenticates with a short-lived JWT
> from the magic link, not a refresh cookie, so it does not have this problem.

That was written about the COOKIE problem, and it is still true about cookies.
It was read as "the frontend does not need same-origin", which is a different
claim, and the frontend then hit the same wall for an unrelated reason: DNS
rather than third-party cookie policy. Two documents disagreeing about one fact
is the drift that turned `AGENTS.md` into a symlink; the backoffice proposal is
amended to say which problem it was excluding.

## What changes

- `NUXT_PUBLIC_API_BASE` becomes **relative** (`/api`).
- A Nitro catch-all route (`server/routes/api/[...].ts`) proxies `/api` on the
  app's own origin, exactly as the backoffice does through nginx. The browser
  makes no cross-origin request at all.
- The proxy target lives in **server-only** runtime config (`apiOrigin`), never
  under `public` — shipping a Docker-internal hostname to the browser is the
  bug being removed.
- The variable is `NUXT_API_ORIGIN`. Not a preference: Nuxt maps only
  `NUXT_`-prefixed variables onto runtimeConfig, so any other name is read as
  undefined. The proxy's own 500 message and the config comment both said
  `BEAI_API_ORIGIN` — an operator hitting that error would have set the name it
  told them to, seen the same 500, and had nothing to go on. Compose hid it
  because the host-side variable happened to carry the other name.
- `.env.example` documents both, because compose was the only place on earth
  that set the origin: a deployment reading only that file would have shipped a
  frontend that 500s on every API call.

## Considered and rejected

**Two different values, one for SSR and one for the browser.** That is what the
single absolute URL was already trying to be, and it cannot work: the value is
either shipped to the browser or it is not. Splitting it into two variables
keeps both, and doubles the number of places a deployment can get it wrong.

**Setting `NUXT_PUBLIC_API_BASE` to `http://localhost:8000/api`.** Works for a
developer, breaks in every container and every deployment, and fails in the same
silent way — routed to `reason=403`, blamed on the token.

## Risk

"Someone sets the API base back to an absolute URL later." The backoffice listed
that risk and mitigated it with an arch test from the start; this app carried
the same risk with nothing underneath. `tests/unit/arch/same-origin-api.spec.ts`
now asserts the mechanism — the proxy route, its server-only target, its refusal
to run untargeted, and the documented name matching the one Nuxt reads.
Verified by regression: reintroducing the absolute base and the old variable
name fails 3 of its 5 assertions.
