# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: Platform-Scope Clients Nav Item

`SidebarNav.vue`'s `navItems` MUST gain a `scope: 'platform'` entry for
`/clients` carrying `requires: 'clients.viewAny'`, following the same
gating pattern as the existing Avatar Templates and Settings entries: the
`requires` ability is checked against what the server publishes via
`GET /api/auth/me`, and `visibleNavItemsFor()`'s platform/client scope
filter applies to it exactly as it does to the two existing platform-scope
items.

#### Scenario: The item is present for a superadmin with no acting client

- GIVEN a superadmin with `actingClientId = null`
- WHEN `visibleNavItemsFor()` filters the nav items
- THEN the Clients item is included, alongside Avatar Templates and
  Settings

#### Scenario: The item is absent for any non-superadmin

- GIVEN a user for whom the server's `clients.viewAny` ability is `false`
- WHEN the sidebar renders
- THEN the Clients item does not appear, regardless of nav scope filtering
  — the ability gate alone withholds it

### Requirement: Route Guard Maps `/clients` To `clients.viewAny`

`03.abilities.global.ts`'s `REQUIRED` map MUST gain a `clients:
'clients.viewAny'` entry, keyed by the route's first path segment,
matching the existing `settings` and `avatar-templates` entries' pattern.

#### Scenario: A superadmin reaches /clients

- GIVEN a superadmin whose `/auth/me` response carries
  `clients.viewAny = true`
- WHEN they navigate to `/clients`
- THEN the route guard allows the navigation

#### Scenario: A non-superadmin is redirected away from /clients

- GIVEN a user whose `/auth/me` response carries `clients.viewAny = false`
- WHEN they navigate directly to `/clients`
- THEN the guard redirects them away, per the existing fail-closed pattern
  used for `settings` and `avatar-templates`
