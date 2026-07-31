# Proposal: Configurable Error Redirect

## Intent

Close the gap `interview-frontend/spec.md` already names:

> Redirecting from `error`/`terminal` states to a distinct configurable error
> landing page is explicitly OUT OF SCOPE for C10 … and **remains a future gap**.

## What the binding doc asks for

`docs/app_description/04-integration-surface/04-uscita-utente.md:33`:

| Caso | Comportamento suggerito |
|---|---|
| Errore tecnico in intervista | **Redirect a pagina errore configurabile** |

Configurable, and per-project — the same table states the return URL is
"configurabile per progetto (non globale unico)". So this mirrors
`exit_redirect_url` rather than inventing a mechanism.

## Why it matters more than the happy path

`exit_redirect_url` already returns a candidate to the calling system when the
interview completes. When it FAILS, the candidate is left on a BEAI screen with
a retry button and no way back — stranded on a domain they have no account on,
belonging to a company they have no relationship with.

That is the worse outcome of the two, and it is the one currently unhandled. The
calling system is the only party that can tell them what happens next: whether
the interview will be re-issued, who to contact, whether their application is
affected. BEAI cannot answer any of those and should not pretend to.

## Scope

Mirrors `exit_redirect_url` exactly, because the two are the same mechanism with
different triggers.

**api** — `projects.error_redirect_url`, validated like its sibling, exposed on
the candidate session resource.

**frontend** — on `error` and `terminal`, redirect there when configured.

**Fallback is the existing inline screen, unchanged.** A project with no error
URL configured behaves exactly as it does today. This adds a route out; it never
removes the one that exists.

## Explicitly out of scope

- **Query-string contract.** The binding doc puts "formato esatto query string o
  fragment" out of scope. This change passes nothing beyond the URL — inventing
  an error-code parameter would be a contract nobody agreed to and that no
  caller is reading.
- **Retry semantics.** Open decision #4 governs retry; untouched.
