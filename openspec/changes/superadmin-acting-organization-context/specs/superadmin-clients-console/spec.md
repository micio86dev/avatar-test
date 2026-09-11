# Delta for Superadmin Clients Console

## ADDED Requirements

### Requirement: Org-Scoped Abilities Suppressed With No Acting Organization

Extends "Platform Capabilities Answer Through One Mechanism": `UserAbilities::for()`
MUST answer `false` for every ability in the org-scoped groups —
`organization`, `apiClients`, `users`, `llmCredentials`, `projects`,
`participants`, `avatarTemplates` — for a superadmin with no acting
organization selected. Suppression MUST live here, in `UserAbilities`, because
`Gate::before` grants a superadmin every policy before any policy body runs,
so no policy can itself answer "no organization is selected." `clients.viewAny`
and `platformSettings.viewAny` MUST remain `true` regardless, or the
superadmin loses the page used to select an organization.

`avatarTemplates.viewAny` (and its sibling abilities) is deliberately included:
`avatar_templates` is org-scoped data, so hiding it with none selected is
consistent with every other org-scoped group. This is orthogonal to, and
unaffected by, the separate deferred follow-up that would restrict
`AvatarTemplatePolicy::viewAny`/`view` to superadmin only — that follow-up
governs WHO may see avatar templates once an organization context exists;
suppression here governs whether the group means anything with NO
organization selected, and answers that the same way regardless of whether
that follow-up ever ships.

#### Scenario: A superadmin with no acting organization has every org-scoped ability suppressed

- GIVEN a superadmin has no acting organization selected
- WHEN `GET /api/auth/me` is called
- THEN `abilities.organization`, `.apiClients`, `.users`, `.llmCredentials`,
  `.projects`, `.participants`, and `.avatarTemplates` are all `false`

#### Scenario: clients and platformSettings survive suppression

- GIVEN the same superadmin with no acting organization
- WHEN `GET /api/auth/me` is called
- THEN `abilities.clients.viewAny` and `abilities.platformSettings.viewAny` remain `true`

#### Scenario: Selecting an acting organization restores the org-scoped abilities

- GIVEN a superadmin previously had all org-scoped abilities suppressed
- WHEN they select organization A as their acting organization and call
  `GET /api/auth/me` again
- THEN the org-scoped abilities answer exactly as they would for an ordinary
  admin of organization A

#### Scenario: An org-bound admin is never subject to suppression

- GIVEN an ordinary admin of organization B (not a superadmin)
- WHEN `GET /api/auth/me` is called
- THEN their abilities are computed exactly as before this change
