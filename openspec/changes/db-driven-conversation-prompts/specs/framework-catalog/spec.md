# Delta for Framework Catalog

## ADDED Requirements

### Requirement: Per-Role×Competency Prompt-Override Surface Alongside BARS Indicators

The catalog MUST expose a per-role×competency prompt-override surface — owned by
`conversation-prompt-templates` — that lives alongside `framework_bars_indicators` and
follows the same global (non-tenant-scoped), platform-level versioning rules. No
per-organization override is introduced by this change.

#### Scenario: The override surface is global, not tenant-scoped

- GIVEN a per-role×competency prompt override
- WHEN its schema is inspected
- THEN it carries no `organization_id` column, matching `framework_roles`, `framework_competencies`, and `framework_bars_indicators`

#### Scenario: The override unique key mirrors framework_bars_indicators' key shape

- GIVEN the override's uniqueness constraint
- WHEN compared to `framework_bars_indicators`' unique key (scoped by role and competency)
- THEN the override's key follows the same role×competency shape, with role OPTIONAL to allow a competency-wide row
