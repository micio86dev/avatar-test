# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: Org-Scoped Navigation And Routes Are Absent With No Acting Organization

With `abilities.users.viewAny`/`projects.viewAny`/etc. suppressed (per the
`superadmin-clients-console` ability-suppression requirement), the existing
ability-gated nav and route-guard mechanism — `SidebarNav.vue`'s `requires`
map and `03.abilities.global.ts`'s `REQUIRED` map — MUST, with NO client-side
code change, hide Settings from the sidebar and redirect a direct navigation
to `/settings` away, for a superadmin with no acting organization. No new
client-side role or `is_superadmin` check MUST be introduced to achieve this.

#### Scenario: Settings is absent for a superadmin with no acting organization

- GIVEN a superadmin with no acting organization selected
- WHEN the sidebar renders
- THEN "Settings" is not present, because `abilities.users.viewAny` is `false`

#### Scenario: Direct navigation to /settings redirects away

- GIVEN the same superadmin
- WHEN they navigate directly to `/settings`
- THEN `03.abilities.global.ts` evaluates `can('users.viewAny')` as `false`
  and redirects them away

#### Scenario: Selecting an acting organization reveals Settings

- GIVEN a superadmin selects organization A as their acting organization
- WHEN the resulting page reload completes and `/auth/me` is re-read
- THEN "Settings" appears in the sidebar and `/settings` is reachable,
  identical to an ordinary admin of organization A
