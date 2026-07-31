# Observability

What BEAI reports, where it goes, and what each sink is allowed to see.

Delivered by C13 (`nfr-hardening`). The specification is
`openspec/specs/observability/spec.md`.

| Sink | Scope | Sees candidate data? |
|---|---|---|
| Sentry (`api`) | Errors and exceptions | **No** — scrubbed, see below |
| Laravel Pulse (`api`) | Application health: requests, queues, caches, workers | Cross-tenant, admin-gated |
| `ai_requests` table | Every LLM call: tokens, latency, cost, failure reason | Internal, never leaves |
| `audit_logs` table | Operator actions | Internal, never leaves |
| Health endpoints | `/up`, `/api/health/*` | No |

---

## Sentry

`SENTRY_LARAVEL_DSN` is a deployment credential. It lives in the platform's
variable store and appears in no file in any of these repositories. Without it
the integration is inert, which is the correct out-of-the-box state.

### What is scrubbed, and why it is not optional

`send_default_pii` is pinned `false` and is deliberately **not** env-overridable.
That flag stops Sentry *attaching* user and IP context automatically. It does
nothing about what this application's own exceptions carry — and in this product
they carry a great deal:

- an exception in the scoring pipeline has **prompt text** in scope, and prompts
  contain a candidate's spoken answers, transcribed;
- a failing SSO exchange has a **signed token** in the request;
- a webhook delivery failure has the **evaluation payload**.

`App\Support\Observability\SentryScrubber` is the actual control. It strips by
key at any depth, drops user context wholesale, and covers `_token`, `_secret`
and `_key` suffixes by convention so a newly-named field is protected before
anyone remembers to add it.

It is a **denylist, not an allowlist**, on purpose: an allowlist would silently
strip the diagnostic context that makes an error report useful, and an unusable
error reporter gets switched off — a worse outcome than a scrubbed one.

Adding a field that carries candidate data means adding its key to
`SentryScrubber::DENIED_KEYS`. `tests/Feature/C13/SentryScrubberTest.php` is
where that obligation is written down.

---

## Laravel Pulse

Mounted at `/pulse`. Records requests, queues, slow jobs, slow queries, caches
and servers into its own `pulse_*` tables.

The queue recorder is the reason it is here. Scoring is asynchronous with a p95
under 10 minutes, and a queue backing up is the failure this product notices
last and suffers from most: nothing errors, evaluations simply arrive late.

### Access is two conditions, not one

```
admin role  AND  email listed in PULSE_OPERATORS
```

**This is a deliberate deviation from `spec.md:242`**, which says "authenticated
users with the `admin` RBAC role".

`admin` in BEAI is **org-scoped** — spatie runs in teams mode with
`team_id = organization_id`, so every customer has an admin of their own. Pulse
has no `organization_id` anywhere: it aggregates the slow queries, exception
messages and job payloads of *every* tenant onto a single page, and there is no
scoping that could be applied to it.

Read literally, the spec therefore hands each customer's admin a view of every
other customer's data. `CLAUDE.md`'s "a tenant must never see another tenant's
data" is a binding constraint and outranks it.

Both conditions are required rather than either, because they go stale in
opposite directions: the allowlist is a deployment artifact that outlives the
person it names, while the role is revoked the day they leave.

```bash
# Comma-separated. EMPTY BY DEFAULT — an unconfigured install admits nobody.
PULSE_OPERATORS=ops@example.com,sre@example.com
```

### Known limitation: the dashboard is not browsable as-is

This API is stateless JWT with **no session login** — a ratified decision
(`CLAUDE.md`, auth section). Pulse's dashboard is Livewire, and Livewire's XHRs
come from the browser with no `Authorization` header, so `auth:api` rejects
them.

What this means in practice:

- **Recording works fully.** Every recorder writes to `pulse_*` regardless, so
  the health data is being collected and is queryable.
- **The HTML dashboard needs help to be opened by a human.** Either front
  `/pulse` with an edge authenticator (Railway/Cloudflare Access) that injects
  the bearer token, or read the `pulse_*` tables directly.

This is a consequence of the JWT-only decision, not an oversight. Adding a
session login purely so a dashboard can be browsed would introduce a second
authentication surface to secure, protect and test — a far larger change than
the dashboard is worth. Revisit it if and when an operator UI is specified.

The `web` middleware group is deliberately absent from `pulse.middleware` for
the same reason: its session, cookie and CSRF middleware have nothing to act on
in a stateless API.

### Cost control

Pulse's recorders hook the query, job and request lifecycles. They are disabled
under test (`PULSE_ENABLED` in `phpunit.xml`) so the suite never writes telemetry
about itself.

> A PHPUnit quirk worth knowing: `<env name="PULSE_ENABLED" value="false"/>`
> does **not** produce the string `"false"`. PHPUnit casts the attribute to
> boolean `false`, then interpolates it into `putenv()`, where it stringifies to
> `""`. The variable arrives as an empty string. Pulse gates on truthiness so it
> is correctly disabled — but any test asserting `=== false` would fail while
> the behaviour was right.

---

## Analytics consent

**One banner, in both apps, and never two on screen at once.**

Both Nuxt apps mount the same `ConsentBanner` component. It appears only where
there is something to ask permission for (a measurement or project ID is
configured) and only on routes where analytics is actually allowed to run.

### Why the recording consent is a separate thing

The interview page collects its own **recording** consent before a session
starts. That one is a precondition of the service: refuse it and there is no
interview. Analytics consent must be refusable at no cost whatsoever.

Bundling them into a single "Accept" is precisely what makes a consent invalid —
it is not freely given if saying no costs you the thing you came for. So they
stay two decisions, and the analytics banner simply never appears on the pages
where the other one lives. The candidate is asked one thing at a time.

### Design rules, and the single fact behind them

Not answering already means no. Analytics defaults to denied, so an ignored
banner is a safe banner — and that licenses everything else:

| Choice | Why |
|---|---|
| `role="region"`, not `role="dialog"` | A dialog implies a focus trap. Trapping somebody in a question they are free to ignore is hostile. |
| Accept and Reject have **identical** styling | A prominent Accept beside a faint Reject is a dark pattern regulators name explicitly. Asserted by test. |
| Refusal is first in the DOM | Whichever option a keyboard user reaches first should be the one with no consequences. |
| A refusal stores `denied`, not nothing | Absence is indistinguishable from never asking, so the banner would return every visit — nagging, which reads as pressure towards yes. |
| Granting starts the tags via an event, not a reload | Consenting and seeing nothing happen reads as a broken button; reloading would throw away the visitor's work. |

Consent is **never revoked in place**. Unloading a running third-party SDK is not
something any of them reliably support, so withdrawal is a reload — flipping the
flag without one would only look like it worked.

Storage key: `beai.consent.analytics`, values `granted` / `denied`. Deliberately
distinct from the interview recording consent. The two apps are on separate
origins and do not share storage: an operator's consent and a candidate's are
different decisions by different people.

### Where each app asks

- **Candidate app** — on the landing and orientation pages. Never on
  `/interview/**`.
- **Backoffice** — after sign-in, on the first real page. Every unauthenticated
  route either redirects to `/login` or is one the banner stands down on, and
  that ordering is correct: asking somebody to make a privacy choice before they
  are through the door is asking a stranger.

---

## Retention

Pulse trims its own tables on its own schedule. Candidate data is governed
separately by `docs/`-adjacent GDPR retention — see `config/retention.php` and
`beai:purge-expired-data`, which ships **disabled** pending legal sign-off on
open decision #2.
