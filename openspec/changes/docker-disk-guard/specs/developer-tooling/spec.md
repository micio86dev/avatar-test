# Delta for Developer Tooling

## ADDED Requirements

### Requirement: A local disk check reports Docker's headroom before space-hungry tasks

A script MUST report how much room Docker has left on the volume holding its
data root, and MUST be invoked ahead of every task that performs a large write —
in particular the tasks that pull the pinned Playwright image.

It MUST only ever REPORT. It MUST NOT delete images, containers, volumes or
build cache, and MUST NOT invoke `docker system prune`: re-pulling the pinned
images costs more time than the reclaimed space is worth, and a tool that
silently discards a 3.45GB image is a tool developers learn to skip.

#### Scenario: A healthy volume passes quietly

- GIVEN a Docker data root on a volume with ample free space
- WHEN the check runs
- THEN it exits 0 and reports the free space without recommending any action

#### Scenario: A constrained volume is named, not cleaned

- GIVEN a Docker data root whose volume is low on free space
- WHEN the check runs
- THEN it names the figure and exits 0, and no image, container, volume or build cache is removed

### Requirement: The disk check fails closed when it cannot measure

Every probe the check makes MUST be guarded. When a required tool is missing, or
its output cannot be parsed into a number, the check MUST print nothing about
that probe and MUST exit 0.

A disk guard that prints a fabricated figure is worse than no guard at all,
because a printed number is believed — and the whole reason this check exists is
to be trusted on the day it says something is wrong.

#### Scenario: An unusable measurement tool produces silence, not a zero

- GIVEN `du` is present but fails or returns output that does not parse as a size
- WHEN the check runs
- THEN it exits 0 and prints no size figure, rather than reporting 0 or a partial number

#### Scenario: A missing data root is not reported as an empty disk

- GIVEN the Docker data root cannot be located or read
- WHEN the check runs
- THEN it exits 0 and reports nothing about capacity

### Requirement: The check distinguishes claimed size from occupied blocks

Docker's disk image is sparse: the blocks it occupies and the size it claims are
different numbers, and only their relationship reveals over-provisioning.

When the claimed size exceeds the free space of the volume that holds it, the
check MUST report BOTH figures and state the headroom Docker believes it has —
because that configuration hits ENOSPC before Docker reaches its own quota, and
the occupied-blocks figure alone never shows it.

#### Scenario: An over-provisioned volume is reported with both figures

- GIVEN a sparse disk image whose claimed virtual size exceeds the volume's free space
- WHEN the check runs
- THEN it exits 0, reports the over-provisioning, names the real virtual size rather than 0, and states the headroom

### Requirement: The disk check has its own test tier, and CI runs it

The check MUST have an executable test suite, and that suite MUST run in CI
alongside every other tier. Its script MUST also be covered by the same
shell linting CI already applies to the guard library.

A guard whose own tests only ever run on one developer's machine is a guard
believed on faith, and this one exists precisely to be believed.

#### Scenario: The suite runs on every pull request

- GIVEN a pull request touching any file in the repository
- WHEN wrapper CI runs
- THEN the disk-check suite executes and a failure fails the build

#### Scenario: The script is linted like its siblings

- GIVEN the CI shell-lint step
- WHEN it runs
- THEN it covers the disk-check script, not only the guard library
