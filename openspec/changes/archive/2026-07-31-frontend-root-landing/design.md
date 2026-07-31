# Design: Frontend Root Landing

## Approach

One Nuxt page, `app/pages/index.vue`, modelled directly on the existing
`app/pages/unsupported.vue`. Same shape: a `role="main"` region labelled by its
own heading, copy from `$t()`, `useHead` for the title and the robots meta, a
`data-testid` for E2E. Nothing invented.

Copying that page rather than reaching for a component library is deliberate:
the two screens have the same job — say one sentence to somebody who took a
wrong turn — and matching them keeps a reader from wondering whether the
difference means something.

## Decisions

### D1 — A page, not a redirect

Alternatives considered:

| Option | Verdict |
|---|---|
| Static informational page | **CHOSEN** |
| Redirect `/` → `/unsupported` | Rejected — lies. The visitor's browser may be perfectly supported; they just have no token. Telling a Chrome user their browser is unsupported sends them to fix the wrong thing. |
| Redirect `/` → an external marketing site | Rejected — no such site is configured, and hard-coding a client's URL into the candidate app breaks multi-tenancy: one deployment serves many organizations. |
| Leave the 404 | Rejected — the status quo, and the reason this change exists. |

### D2 — No contact affordance, and this is load-bearing

The instinct on an orientation page is to add "problems? write to…". It is wrong
here, for a reason specific to this product rather than a general preference.

BEAI holds **no candidate contact data** (ratified decision #8) and has no
relationship with the person. The party that invited them — the HR portal, the
LMS — is the only one who can identify them, re-mint a link, or explain the
deadline. A BEAI-side contact would route confused people to an organization
that cannot help them and would have to ask, "who are you, and who sent you?"

Saying "use the link you were sent" is both shorter and more useful, because it
points at the party who actually holds the answer.

### D3 — Gated like every other route

`browser-gate.global.ts` skips only `to.path.endsWith('/unsupported')`. The root
therefore inherits the gate for free, and a mobile visitor sees `/unsupported`
instead of this page.

That ordering is correct rather than incidental. Somebody on a phone has two
problems — no token and the wrong device — and only one of them is fixable right
now. Telling them the device first is the actionable half.

No code is needed for this; the spec asserts it so a future edit to the skip
list cannot regress it silently.

### D4 — Copy

One heading, one sentence. Not three.

The visitor is disoriented and scanning. Every additional sentence is one more
thing to read before finding out they simply need their link. The Italian and
English strings live under a new `root` key in `i18n/locales/{it,en}.json`,
beside `unsupported`.

Explicitly not included: an explanation of what BEAI is, why they need a link,
or what an assessment involves. None of that helps them get in, and a candidate
who has not started has no reason to care.

## File changes

| File | Action | Description |
|---|---|---|
| `frontend/app/pages/index.vue` | Create | The page |
| `frontend/i18n/locales/it.json` | Modify | `root.title`, `root.message` |
| `frontend/i18n/locales/en.json` | Modify | Same keys |
| `frontend/tests/unit/root-page.spec.ts` | Create | Renders copy; asserts no form control, no login affordance |
| `frontend/tests/e2e/root-landing.spec.ts` | Create | 200, robots meta, title, axe scan, mobile→`/unsupported` |

## Testing strategy

| Layer | What |
|---|---|
| Unit | Copy renders from i18n; **no** `input`/`form`/submit button; no login or sign-up text |
| E2E | 200 not 404; `noindex, nofollow`; non-empty `<title>`; axe AA clean; mobile project redirects to `/unsupported` |

The prohibitions get tests rather than comments. A comment saying "do not add a
login here" survives exactly until somebody disagrees with it in a hurry.

## Open questions

None. The copy is the only judgement call, and it is one string per locale —
changed in a pull request, not a migration.
