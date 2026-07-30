# Proposal: Frontend Root Landing (informational dead-end)

## Intent

Give `GET /` on the candidate app something to say. Today it returns a bare 404.

## Why this exists at all

The 404 is not a bug, and this proposal does not treat it as one. There is no
`index.vue`, and no requirement anywhere in `openspec/specs` or
`docs/app_description` asks for one — verified. The design is coherent: a
candidate never types the address. They arrive on `/interview/{token}` from a
magic link minted by the calling system, and they leave via
`project.exit_redirect_url` back to that same system. Every entry is a token URL
and every exit is a redirect outward.

A home page in the conventional sense would have nothing to offer:

- no login — a candidate has no BEAI account, by design
- no sign-up — enrolment belongs to the calling system, and BEAI holds no
  candidate contact data (ratified decision #8)
- no listing — a candidate has exactly one interview and arrives holding its token

So this change does **not** add a home page. It adds an **informational dead
end**.

## The actual problem

People reach the root anyway, and a raw 404 is the wrong thing to show a human:

1. They open the link on a phone, see `/unsupported`, and trim the URL to work
   out where they are.
2. Their token expired, they go back to the root looking for a way in.
3. They bookmarked the site during a previous interview.

In all three the person is confused and looking for orientation. A 404 gives
them none, and worse, it reads as "this service is broken" rather than "you are
in the right place, you just need your link".

## Scope

One route. One screen. No API calls, no form, no state.

**In scope**

- `app/pages/index.vue` — a static, localized informational page
- i18n keys in `it` and `en`
- `noindex, nofollow`
- Unit test + E2E coverage, including the a11y check the other pages already run

**Explicitly out of scope**

- Any input field, link to a login, or "request access" affordance. Adding one
  would invent a self-service flow the product deliberately does not have.
- A support email or phone number. BEAI is not the candidate's support channel;
  the calling system is, and BEAI cannot know who to point them at.
- The `error` / `terminal` landing page. `interview-frontend/spec.md` marks that
  as out of C10 scope and "remains a future gap". It is a related hole and stays
  open here — this change fixes the root only, and does not quietly widen itself.

## Behaviour with the browser gate

`browser-gate.global.ts` is a global route middleware that skips only paths
ending in `/unsupported`. `/` is therefore gated like every other route: a
Firefox or sub-1024px visitor is redirected to `/unsupported` before this page
renders.

That is the right outcome and needs no special handling. Someone on a phone
needs to be told to switch device — that is more actionable than an orientation
message they cannot act on until they do.

## Risk

Low. A static page on a route that currently 404s; nothing depends on the 404.

The one thing to get wrong would be scope creep into a login-shaped screen. The
spec below states the prohibition as a requirement so it is testable, not just
intended.
