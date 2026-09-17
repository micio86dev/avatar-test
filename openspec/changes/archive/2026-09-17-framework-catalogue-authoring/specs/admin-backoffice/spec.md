# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: Platform-Scope Catalogue Pages

A `catalogue.manage` ability MUST gate a Catalogue nav entry and its
route-guard map entry (`middleware/03.abilities.global.ts`), rendered only
for a platform superadmin, shaped after `avatar-templates/index.vue`'s page
pattern. The ability gates client-side rendering only — the server-side 403
in `catalogue-authoring` is the actual access control and MUST be enforced
independent of this UI gate.

#### Scenario: The nav entry is visible only to a superadmin

- GIVEN a signed-in platform superadmin
- WHEN the sidebar renders
- THEN the Catalogue nav entry is present

#### Scenario: A non-superadmin sees no nav entry and is blocked on direct navigation

- GIVEN a signed-in org `admin` who is not a platform superadmin
- WHEN they navigate directly to a catalogue route
- THEN the route guard blocks rendering, and no Catalogue nav entry was ever
  shown to them

#### Scenario: The ability alone never substitutes for the server 403

- GIVEN the `catalogue.manage` ability is somehow granted client-side to a
  non-superadmin session
- WHEN that session calls a catalogue-write endpoint
- THEN the server still returns HTTP 403 — the UI ability is not trusted as
  access control
