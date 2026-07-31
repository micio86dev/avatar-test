# Delta for Observability (admin-dashboards — C11)

Modifies: `openspec/specs/observability/spec.md`

`spec.md:308-331` obliges the C11 Admin Dashboard to surface MRR, trial
conversion, and subscription growth. No billing schema exists anywhere in
`api/database/migrations` (verified: `rg -i "subscription|billing|mrr|trial|plan"`
over that directory returns only an unrelated hit). This delta narrows the C11
obligation to what the current schema supports — usage and AI-cost metrics —
and explicitly defers business/billing metrics to a future billing slice,
rather than leaving an unbuildable requirement standing.

---

## MODIFIED Requirements

### Requirement: Internal Business Metrics — Database as Source of Truth

All authoritative business metrics MUST be derived directly from the BEAI
database. External analytics platforms (GA4, Clarity) MUST NOT be used as the
source of truth for any metric that drives a business decision. Metrics computed
from the database MUST be reproducible at any point in time from persisted data.

The following metrics MUST be computable from the database and MUST be surfaced
in the internal Admin Dashboard (implemented in C11):

**Usage metrics**

- Active organizations (at least one assessment in the current period)
- Active users (monthly active)
- Daily assessments started and completed
- Completion rate (completed / started)
- Average assessment duration

**AI usage metrics (delivered in C11)**

- AI credits consumed (token usage per model)

**AI metrics deferred — NOT in C11 scope**

- AI reports generated (count by period)
- Estimated AI cost (USD, based on logged pricing at request time)
- Token usage broken down **per provider**

These three require columns the `ai_requests` table does not have. Verified
against `api/database/migrations/*_create_ai_requests_table.php`: the shipped
schema carries `model`, `prompt_version`, `input_tokens`, `output_tokens`,
`finish_reason` and `latency_ms`, but **no `provider`, no `estimated_cost_usd`,
no per-period report counter**. Design D7 made the right engineering call by
narrowing the dashboard to token usage and latency rather than fabricating a
currency figure from pricing that is nowhere recorded — `DashboardController`
emits no cost field, and `AdminDashboardMetricsTest` asserts its absence
explicitly. This text was simply never updated to match that decision.
Ownership of these three passes to the `nfr-hardening` slice (C13), which owns
closing the `ai_requests` conformance gap; that slice MUST update this
requirement when it lands.

**Business metrics (deferred — NOT in C11 scope)**

- Conversion rate (trial → paid)
- Trial conversion timeline (median days to conversion)
- Subscription growth (month-over-month delta)
- Monthly recurring revenue (MRR)
- Feature adoption by organization

These five business metrics require a billing/subscription schema that does not
exist in the codebase as of C11. They MUST NOT be implemented, stubbed, or
faked in C11's Admin Dashboard. They are deferred to a future billing slice
that first introduces the subscription schema; that slice becomes the owner of
this sub-list and MUST update this requirement when it lands.
(Previously: listed usage, AI-cost, and business/billing metrics as one
undifferentiated obligation for C11, including MRR — unbuildable without a
billing schema, which does not exist. This split separates what C11 can and
does deliver from what a future billing slice must deliver.)

#### Scenario: Active organization count is derived from the database

- GIVEN the BEAI database with organization-scoped assessment rows
- WHEN an operator queries active organizations for a given billing period
- THEN the count is computed via a database query
- AND the result does not depend on a GA4 export or any external platform

#### Scenario: AI cost metrics are computable from the database

- GIVEN every AI request produces an `ai_requests` log record (see AI Request Logging requirement)
- WHEN an operator queries AI costs for a billing period
- THEN total token usage and estimated cost per provider and model are computable from those records alone

#### Scenario: C11 dashboard does not surface business/billing metrics

- GIVEN the C11 Admin Dashboard's KPI summary
- WHEN it is reviewed
- THEN it displays only usage and AI-cost metrics
- AND no MRR, trial-conversion, subscription-growth, or feature-adoption widget
  is present, disabled, or displaying placeholder/fake data
