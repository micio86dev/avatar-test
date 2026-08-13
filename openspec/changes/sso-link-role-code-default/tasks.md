# Tasks: SSO Link Inherits the Project Role

> Strict TDD. One repo, one small change.

- [ ] 1.1 Failing test first: mint without `role_code` on a standard project, then exchange the token — currently 201 followed by 403.
- [ ] 1.2 `SsoLinkController` resolves the role from the project when the request omits it, for standard projects only.
- [ ] 1.3 Tests: inherited value present in the token; inherited token redeems; supplied-and-wrong still 422; potential project still mints null; exchange still 403 on a genuine mismatch.
- [ ] 1.4 api gates green; `openapi.json` unchanged (no shape change) or resynced if Scramble moves.

## Documented, Not Scoped

- **jti-before-gates.** Consuming the link before evaluating the gates is
  deliberate replay protection and stays. With the mint fixed, the case that
  made it painful stops arising.
- **The exchange's exact check.** Not relaxed; it still catches a role changed
  between mint and redemption.
