# Delta: ci-pipeline — Framework Catalog Coverage Gate

## ADDED Requirements

### Requirement: Framework Catalog Completeness Gate Asserts Both Role-Level And Competency-Level Coverage

The wrapper catalog gate (`scripts/ci-guards.sh`, wired into
`.github/workflows/wrapper-ci.yml` step (d)) MUST fail when a role declared
in `roles.json` has no matching `bars/{ROLE}.json` UNLESS that role is on a
committed, reviewable known-gaps list, and MUST fail when a role IS on that
list but its BARS file now exists (the exemption has outlived its gap). This
role-level behavior already exists in the codebase; this requirement
codifies it as the baseline the competency-level extension below builds on.

The gate MUST apply the same two-direction check to the role×competency
pair: it MUST fail when a competency assigned to a role (per that role's
entry in `roles.json`) has no corresponding key in that role's
`bars/{ROLE}.json` UNLESS that exact pair is on a committed, reviewable
per-pair known-gaps list, and MUST fail when a pair IS on that list but the
role's BARS file now defines an entry for it. Both known-gaps lists MUST be
able to go green against today's committed tree (the 26 known role×competency
gaps — corrected from this delta's earlier draft of 44; see the note below)
while still failing on a newly introduced, undeclared gap.

> **Corrected count, recorded rather than silently rewritten.** An earlier
> draft of this requirement said "44 known role×competency gaps" — that
> number counts SRX's 18 pairs, but the per-pair gate above deliberately asks
> its question ONLY of roles whose `bars/{ROLE}.json` file EXISTS (see the
> "undeclared missing role×competency BARS entry" scenario below: the pair
> must have "no key in that role's `bars/{ROLE}.json`", which presupposes the
> file is there to look inside). SRX has no BARS file at all, so its 18 pairs
> stay under the role-level known-gaps list above, not the per-pair one — the
> role-level check already owns "no file"; the per-pair check owns "file
> exists but is partial". Declaring SRX's pairs in both lists would corrupt
> `scripts/framework-known-gaps.txt`'s own parser (`known_gap_roles()` reads
> only the first whitespace field of each line, so a `SRX:PRS`-shaped entry
> there would be read as a role code) and would make the day `bars/SRX.json`
> is authored a multi-line deletion instead of a single clean role-level
> removal. The correct composition, verified against `roles.json` and the
> four partial `bars/*.json` files: ICO 0 + FLL 10 + MLL 10 + BUL 6 + SRX 0
> (role-level exemption, not counted here) = **26**.

The gate MUST reuse the runtime's own gap vocabulary (`role_no_bars`,
`competency_no_bars` — already recorded by `FrameworkCatalogSeeder` as
`framework_gaps` rows) rather than inventing new terms.

The gate MUST NOT treat an empty anchor array (a competency key present in
`bars/{ROLE}.json` whose value is `[]`) as coverage — only a key whose array
is non-empty counts as anchored. A stub key is not an anchor set, and
treating it as one would make the cheapest way to green the gate an empty
array rather than real content.

The per-pair exemption check MUST also fail when a pair on the per-pair
known-gaps list names a role that IS declared in `roles.json` but has NO
`bars/{ROLE}.json` file at all. Without this, such a pair is caught by
NEITHER direction: the pair-level completeness check skips a role with no
file by design (that absence is the role-level list's business), and the
"anchors now exist" stale direction never runs without a file to read — so
the entry would sit as a permanent, unenforced statement until the day the
file is authored, at which point it fails in a commit that did not add it.

#### Scenario: An undeclared missing role-level BARS file fails CI

- GIVEN a role declared in `roles.json` has no `bars/{ROLE}.json` and no
  entry on the role-level known-gaps list
- WHEN the wrapper catalog gate runs
- THEN it fails

#### Scenario: A stale role-level exemption fails CI

- GIVEN a role is on the role-level known-gaps list and its
  `bars/{ROLE}.json` now exists
- WHEN the wrapper catalog gate runs
- THEN it fails

#### Scenario: An undeclared missing role×competency BARS entry fails CI

- GIVEN a competency assigned to a role has no key in that role's
  `bars/{ROLE}.json`, and the pair is not on the per-pair known-gaps list
- WHEN the wrapper catalog gate runs
- THEN it fails

#### Scenario: A stale per-pair exemption fails CI

- GIVEN a role×competency pair is on the per-pair known-gaps list and that
  role's BARS file now defines an entry for it
- WHEN the wrapper catalog gate runs
- THEN it fails

#### Scenario: An empty anchor array is not coverage

- GIVEN a competency key exists in a role's `bars/{ROLE}.json` but its value
  is an empty array (`[]`)
- WHEN the wrapper catalog gate runs
- THEN it treats that competency as missing anchors for that role, exactly
  as if the key were absent — either failing as an undeclared gap, or
  requiring the pair to be on the per-pair known-gaps list like any other
  missing pair

#### Scenario: A per-pair exemption for a role with no bars file at all fails CI

- GIVEN a role×competency pair is on the per-pair known-gaps list, and that
  pair's role IS declared in `roles.json` but has no `bars/{ROLE}.json` file
- WHEN the wrapper catalog gate runs
- THEN it fails, naming the pair and stating that the role belongs on the
  role-level known-gaps list instead

#### Scenario: The gate is green on the current committed tree

- GIVEN today's `roles.json`, the four partial `bars/*.json` files, and a
  per-pair known-gaps list declaring the 26 known gaps (see the corrected-count
  note above)
- WHEN the wrapper catalog gate runs
- THEN it passes

#### Scenario: A newly introduced, undeclared gap is caught

- GIVEN a competency is added to a role in `roles.json` without a matching
  BARS entry and without a per-pair known-gaps entry
- WHEN the wrapper catalog gate runs
- THEN it fails, naming the undeclared pair

### Requirement: Per-Pair Known-Gaps List Is Ordered For Review

The per-pair known-gaps file SHOULD group entries by role, then by
competency within each role, mirroring how an authoring specialist works
through the gap — the anchors are role-specific, so authoring proceeds role
by role.

#### Scenario: Entries are grouped by role

- GIVEN the per-pair known-gaps file
- WHEN it is inspected
- THEN all entries for a given role are contiguous, and roles are not
  interleaved
