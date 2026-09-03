#!/bin/sh
# BEAI — shared CI guard mechanisms.
#
# Every function below is the ONE implementation of a rule that
# .github/workflows/wrapper-ci.yml enforces. The real gate sources this file.
# The self-test step sources the SAME file. Neither re-types the logic.
#
# That is the entire reason this file exists. The self-test used to declare its
# own copies of `tag_pinned`, the Dockerfile guard, the Bun-only regex, the
# Sanctum pipeline and the openapi canonicaliser — so what it proved was that
# the COPIES could fail. Change a real gate, or fat-finger it, and the
# self-test stayed green over the broken original. That is exactly the defect
# shape this workflow was written to eliminate ("the text stated the rule while
# its mechanism excluded the violation"), reintroduced by the mechanism meant
# to catch it. One definition, two consumers, nowhere for a copy to drift.
#
# POSIX sh on purpose, and the CONSUMERS are held to it too: no `local`, no
# arrays, no `[[`, no process substitution, no `${VAR:0:n}`. Where state has to
# survive a `while` loop, the loop reads from a redirected FILE — never from
# `< <(...)` — because the right-hand side of a pipe is a subshell and
# assignments made there do not come back.
#
# The claim is stated as narrowly as it is true, because an earlier draft of
# this header did not. It said the guards run under any shell while every
# consumer step used bash process substitution, so the property was already
# void the day it was written — a rationale describing something the file did
# not have, which is the exact note-outliving-its-fact defect these guards
# exist to catch, in the guards' own documentation.
#
# What is true now, and CHECKED BY A REAL GATE ("Lint scripts/ci-guards.sh"
# in .github/workflows/wrapper-ci.yml, run before anything sources this
# file): `shellcheck -s sh` and `dash -n` both pass on THIS FILE. What POSIX
# compatibility buys is that `shell: sh` on a step would not silently break a
# guard, and that `shellcheck -s sh` stays able to check the functions
# themselves.
#
# The claim stops at this file on purpose, and used to overreach: an earlier
# draft said it also covered "every `run:` block that sources it", which
# nothing checked either — a second instance of the same note-outliving-its-
# fact defect, inside the paragraph about that defect. The steps that source
# this file EXECUTE under bash (Actions' default, unchanged), not sh, so
# checking them under `-s sh` would be the wrong dialect even if something
# ran it. Making that half true would mean parsing this workflow's YAML,
# extracting every `run:` block, and shellchecking each under `-s bash` —
# real, separate machinery this file does not build. They are held to the
# no-`local`/no-arrays/no-`[[` discipline stated above by review, not by a
# gate. Do not restore the wider claim unless that machinery exists and a CI
# step runs it.
#
# Usage:  . scripts/ci-guards.sh          (from the repository root)

# ---------------------------------------------------------------------------
# The tag-pinning rule (D24/D25).
#
# ONE rule, shared by compose images and Dockerfile bases. Two pinning rules in
# one repository is how one of them drifts, and one of them had: the compose
# copy accepted any tag containing a dot ANYWHERE, so `node:24-alpine3.19`
# passed on the alpine variant's version while node's major floated across
# every patch release.
#
# Accepted:
#   * a digest — `repo@sha256:<hex>`. Content-addressed and immutable: the
#     strongest pin that exists. Both guards used to REJECT it, because both
#     took "the tag" to be everything after the LAST colon, which for a digest
#     is hex with no dots in it. The strongest possible pin was reported as
#     floating.
#   * a tag STARTING with a dotted version — `8.0`, `v1.22`, `0.8.0-pg17`.
#   * the literal `local`, this repo's convention for locally built images.
#
# Rejected: a bare major (`redis:8-alpine`), `latest`, no tag at all, and the
# versioned variant above. "Starts with" is load-bearing: it stops a suffix's
# own version standing in for the base image's.
# ---------------------------------------------------------------------------
tag_pinned() {
  case "$1" in
    *@sha256:*|*@sha512:*) return 0 ;;
  esac
  case "$1" in
    *:*) ;;
    *) return 1 ;;
  esac
  printf '%s' "${1##*:}" | grep -qE '^v?[0-9]+\.[0-9]+|^local$'
}

# ---------------------------------------------------------------------------
# Dockerfile base-image pinning.
#
# Deliberately small. Earlier versions parsed stage names and refs by hand and
# kept breaking on real syntax — `FROM builder AS runtime`,
# `FROM --platform=$BUILDPLATFORM node:24`, lowercase `from`. Each fix grew the
# parser and revealed another case, which is the signal that the medium is
# wrong: it was a Dockerfile parser written in bash.
#
# It asks one question per LINE. Per line, not over a flattened token list — an
# earlier version broke out after the first registry reference, so a pinned
# builder stage hid a floating runtime stage entirely.
#
# What changed, and why it had to: the skip rule used to be "a reference
# containing ':' or '/' is an image, a bare word is a stage name". `FROM node`
# has neither, so it was read as a stage name and waved through — but `FROM
# node` IS `node:latest`, the single violation this guard exists to block. The
# old comment called that a "known limit, stated rather than parsed around";
# documenting a hole does not close it, and it was a hole in the guard's
# PRIMARY defect class.
#
# It is closed by collecting the stage names the file actually DECLARES (the
# `AS <name>` clauses) and skipping only a reference that matches one of them.
# A bare word that names no declared stage is an untagged image, and is now
# rejected. Stage names are compared case-insensitively because Docker itself
# lowercases them.
#
# `scratch` is allowed by name. It is not an image reference at all — it is
# Docker's reserved empty base, has no tag to pin and cannot float.
# ---------------------------------------------------------------------------
ci_dockerfile_from_lines() {
  grep -iE '^[[:space:]]*from[[:space:]]' "$1" 2>/dev/null || true
}

ci_dockerfile_stage_names() {
  ci_dockerfile_from_lines "$1" \
    | sed -n 's/.*[[:space:]][Aa][Ss][[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' \
    | tr '[:upper:]' '[:lower:]'
}

# The first non-flag token after FROM. `--platform=$BUILDPLATFORM` and friends
# are dropped by the `^--` filter rather than by knowing their names.
ci_dockerfile_ref() {
  # shellcheck disable=SC2020
  # The duplicated '\n' is deliberate, not the word-versus-set mistake SC2020
  # warns about: BOTH space and tab must become a newline so the line splits
  # into one token per line. A single-character replacement set would rely on
  # tr's padding behaviour, which POSIX leaves to the implementation.
  printf '%s' "$1" \
    | sed 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]\{1,\}//' \
    | tr ' \t' '\n\n' | grep -v '^--' | grep -v '^$' | head -1
}

# Exit 0 when every FROM in $1 is pinned.
# Exit 1 and print the first offending reference otherwise.
# Exit 1 silently when the file does not exist — a guard that cannot read its
# subject must never pass it.
df_guard() {
  [ -f "$1" ] || return 1
  CI_DF_STAGES=$(ci_dockerfile_stage_names "$1")
  ci_dockerfile_from_lines "$1" | while IFS= read -r CI_DF_LINE; do
    CI_DF_REF=$(ci_dockerfile_ref "$CI_DF_LINE")
    [ -n "$CI_DF_REF" ] || continue
    CI_DF_LOWER=$(printf '%s' "$CI_DF_REF" | tr '[:upper:]' '[:lower:]')
    [ "$CI_DF_LOWER" = "scratch" ] && continue
    if printf '%s\n' "$CI_DF_STAGES" | grep -qxF "$CI_DF_LOWER"; then
      continue
    fi
    tag_pinned "$CI_DF_REF" || { printf '%s\n' "$CI_DF_REF"; exit 1; }
  done
}

# ---------------------------------------------------------------------------
# `COPY --from=<ref>` pinning — the SAME rule as FROM (D24/D25), for a
# construct df_guard never read at all. `COPY --from=` takes either a STAGE
# name (`COPY --from=builder`) or an IMAGE reference (`COPY --from=composer:2`
# — a floating major, exactly what tag_pinned exists to reject), same
# ambiguity FROM has. df_guard already solved stage-versus-image
# (`ci_dockerfile_stage_names`); this reuses that helper rather than
# re-deriving a second stage-versus-image parser, which is how the FROM
# parser above ended up broken more than once.
#
# The line shape is not FROM's, though. FROM's reference is "the first
# non-flag token" because FROM has no other flags worth naming. COPY's
# `--from=` is not positional — `--chown` and `--chmod` can sit on either
# side of it — so the reference is the VALUE of the `--from=` flag
# specifically, found by token, not by position.
# ---------------------------------------------------------------------------

# COPY lines that carry a --from= flag, one per line. A COPY with no
# --from= copies from the build context, not another stage or image, and is
# out of scope for this guard entirely — it has nothing to pin.
ci_dockerfile_copy_from_lines() {
  grep -iE '^[[:space:]]*copy[[:space:]]' "$1" 2>/dev/null | grep -E -- '--from=' || true
}

# The --from=<value> token off one COPY line, comment-free by construction
# (grep -iE above only ever matches instruction lines, not comments). Split
# the same way ci_dockerfile_ref splits a FROM line (space/tab -> newline,
# one token per line) so a flag on either side of --from= cannot confuse it.
ci_dockerfile_copy_from_ref() {
  # shellcheck disable=SC2020
  # Same duplicated '\n' as ci_dockerfile_ref above, and the same reason:
  # BOTH space and tab must become a newline so the line splits into one
  # token per line, which a single-character replacement set cannot do
  # portably (tr's padding behaviour is implementation-defined in POSIX).
  printf '%s' "$1" | tr ' \t' '\n\n' | sed -n 's/^--from=//p' | head -1
}

# Exit 0 when every COPY --from= reference in $1 is pinned (or is a declared
# stage). Exit 1 and print the first offending reference otherwise. Exit 1
# silently on a file that does not exist — same "cannot read its subject"
# contract df_guard obeys above.
df_copy_from_guard() {
  [ -f "$1" ] || return 1
  CI_DF_STAGES=$(ci_dockerfile_stage_names "$1")
  ci_dockerfile_copy_from_lines "$1" | while IFS= read -r CI_DF_LINE; do
    CI_DF_REF=$(ci_dockerfile_copy_from_ref "$CI_DF_LINE")
    [ -n "$CI_DF_REF" ] || continue
    CI_DF_LOWER=$(printf '%s' "$CI_DF_REF" | tr '[:upper:]' '[:lower:]')
    if printf '%s\n' "$CI_DF_STAGES" | grep -qxF "$CI_DF_LOWER"; then
      continue
    fi
    tag_pinned "$CI_DF_REF" || { printf '%s\n' "$CI_DF_REF"; exit 1; }
  done
}

# ---------------------------------------------------------------------------
# GitHub Actions `uses:` SHA-pinning — this workflow's own version of
# D24/D25, applied to itself. A `uses: owner/repo@v4` tag is exactly as
# movable as a floating Docker tag: the action's owner can repoint `v4` to a
# different commit at any time, the same way a registry can repoint a bare
# major. The only pin that is actually immutable is the commit SHA; the
# human-readable version belongs in a trailing comment, never in the ref
# itself, which is why this rejects it there too.
#
# Deliberately narrower than tag_pinned: there is no dotted-version or
# `local` carve-out here, because there is no equivalent of a locally-built,
# untaggable action. Every `uses:` line names a real, externally-owned
# action, so every one of them must resolve to a SHA.
# ---------------------------------------------------------------------------

# `uses:` lines in a workflow file, one per line. `uses:` is a step-level
# key, which YAML allows written two ways — on its own line as a sibling of
# `- name:` (every real line in this file), or compressed onto the list
# item's own dash (`- uses: ...`, valid YAML this guard must still read
# correctly rather than silently missing). The optional `-` is matched, not
# assumed absent.
ci_workflow_uses_lines() {
  grep -E '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*' "$1" 2>/dev/null || true
}

# The <owner>/<repo>@<ref> value off one `uses:` line, the same optional
# leading `-` stripped, trailing comment (the human-readable version,
# `# v4.4.0`) stripped.
ci_workflow_uses_ref() {
  printf '%s' "$1" \
    | sed -e 's/^[[:space:]]*\(-[[:space:]]\{1,\}\)\{0,1\}uses:[[:space:]]*//' -e 's/[[:space:]]*#.*$//'
}

# Exit 0 when a `uses:` value is pinned to a full 40-character commit SHA
# (hex, case-insensitive — Git itself is). A tag (`@v4`), a branch
# (`@main`), or a short SHA are all rejected: none of them is immutable, and
# a short SHA is not even guaranteed unambiguous as a repository grows.
workflow_action_pinned() {
  case "$1" in
    *@*) ;;
    *) return 1 ;;
  esac
  printf '%s' "${1##*@}" | grep -qE '^[0-9a-fA-F]{40}$'
}

# Exit 0 when every `uses:` reference in workflow $1 is SHA-pinned. Exit 1
# and print the first offending reference otherwise. Exit 1 silently on a
# file that does not exist — same "cannot read its subject" contract every
# other guard in this file obeys.
workflow_actions_guard() {
  [ -f "$1" ] || return 1
  ci_workflow_uses_lines "$1" | while IFS= read -r CI_WF_LINE; do
    CI_WF_REF=$(ci_workflow_uses_ref "$CI_WF_LINE")
    [ -n "$CI_WF_REF" ] || continue
    workflow_action_pinned "$CI_WF_REF" || { printf '%s\n' "$CI_WF_REF"; exit 1; }
  done
}

# ---------------------------------------------------------------------------
# docs/version-catalog.md — bidirectional consistency with reality (D25).
#
# The catalog exists because the archived design section it replaced
# drifted: `openspec/changes/archive/2026-07-16-project-skeleton-ci/design.md`
# D25 listed `oven/bun:1.3`, `node:24-slim` and `nginx:1.27-alpine` — three
# bare-major tags `tag_pinned` above would reject — while every Dockerfile
# had already moved on to a patch pin. docs/version-catalog.md's own rules
# section says the table and reality "are checked against each other" —
# this is that check, in BOTH directions:
#
#   * every image tag reality actually uses (Dockerfile FROM bases, compose
#     image: references) must be a row in the catalog — a tag bumped
#     without updating the row FAILS.
#   * every row the catalog declares must still be used somewhere — a row
#     left behind after an image is dropped or renamed FAILS too. This is
#     the same note-outliving-its-fact defect scripts/framework-known-gaps.txt,
#     scripts/framework-competency-gaps.txt and
#     scripts/framework-crossrole-baseline.txt already guard against,
#     applied to a fourth control file.
#
# Wired into .github/workflows/wrapper-ci.yml as step (h), and proved
# against a genuinely broken fixture — both directions — in step (f)'s
# self-test.
#
# Reality is the source of truth for what is USED; the catalog is the
# source of truth for what is ALLOWED. The three locally-built tags
# (beai-api:local, beai-frontend:local, beai-backoffice:local) are excluded
# by the SAME "the literal `local`" convention `tag_pinned` above already
# documents: they are built FROM the Dockerfiles this guard reads, and a
# row pinning "whatever was just built" would assert nothing.
#
# Multi-stage `FROM builder AS runtime` references an earlier STAGE, not an
# image — `catalog_dockerfile_images` below reuses `df_guard`'s own
# stage-exclusion helpers (`ci_dockerfile_from_lines`,
# `ci_dockerfile_stage_names`, `ci_dockerfile_ref`, all defined above)
# rather than re-deriving the same parsing this file already got wrong once.
# ---------------------------------------------------------------------------

# Non-stage FROM image references in a Dockerfile, one per line. Fails
# closed (return 1, nothing printed) on a file that does not exist — the
# same contract df_guard obeys, using the exact same stage-collection and
# per-line parsing it does.
catalog_dockerfile_images() {
  [ -f "$1" ] || return 1
  CI_CDI_STAGES=$(ci_dockerfile_stage_names "$1")
  ci_dockerfile_from_lines "$1" | while IFS= read -r CI_CDI_LINE; do
    CI_CDI_REF=$(ci_dockerfile_ref "$CI_CDI_LINE")
    [ -n "$CI_CDI_REF" ] || continue
    CI_CDI_LOWER=$(printf '%s' "$CI_CDI_REF" | tr '[:upper:]' '[:lower:]')
    [ "$CI_CDI_LOWER" = "scratch" ] && continue
    printf '%s\n' "$CI_CDI_STAGES" | grep -qxF "$CI_CDI_LOWER" && continue
    printf '%s\n' "$CI_CDI_REF"
  done
}

# The image: values in a `docker compose config` OUTPUT (a multi-line
# string passed as $1, not a path — the caller already has it and should
# not have to invoke docker compose a second time to get it), one per
# line, excluding the `:local` build-only convention `tag_pinned` above
# already documents. Always exits 0: this is a pure filter over text the
# caller already obtained, with nothing of its own left to fail on.
compose_declared_images() {
  printf '%s\n' "$1" \
    | grep -E '^[[:space:]]*image:' \
    | sed 's/^[[:space:]]*image:[[:space:]]*//' \
    | while IFS= read -r CI_CDI_IMG; do
        [ -n "$CI_CDI_IMG" ] || continue
        case "$CI_CDI_IMG" in
          *:local) continue ;;
        esac
        printf '%s\n' "$CI_CDI_IMG"
      done
}

# Every image tag docs/version-catalog.md declares in its "Docker base
# images" table, one per line — read from the Tag column's backtick span
# directly, rather than a second hand-maintained list somewhere else.
#
# The table lives between "## Docker base images" and the NEXT "## "
# heading. A sed range `/^## Docker base images/,/^## /p` gets this
# wrong: that heading line itself starts with "## ", matching BOTH
# boundaries of its own range on the same line, so the range opens and
# closes on the heading and prints nothing after it. Tracked as an
# explicit `insection` flag in awk instead, which is not fooled by one
# line satisfying both patterns: the heading sets the flag and moves on
# (`next`, so it is never itself scanned for a table row); a LATER
# "## " heading clears the flag and exits before that line is scanned
# either.
#
# Matches the FIRST backtick span on each row, always the Tag column —
# the Image column carries no backticks, so nothing upstream of it can be
# mistaken for one.
# shellcheck disable=SC2016
# Single-quoted on purpose: `$0`, `insection` and the awk regexes below
# are AWK's own syntax and must reach it untouched, not shell variables.
CI_VERSION_CATALOG_AWK_SCRIPT='
  /^## Docker base images/ { insection = 1; next }
  insection && /^## / { exit }
  insection && /^\|/ {
    if ($0 ~ /^\|[[:space:]]*-/) { next }
    if (split($0, cell, "|") >= 4 && match(cell[3], /`[^`]+`/)) {
      print substr(cell[3], RSTART + 1, RLENGTH - 2)
    }
  }
'

# Reads the Tag COLUMN of table ROWS, not the first backticked token on any
# line of the section — which is what it used to do, and what broke it. A
# paragraph added between the table and the next heading mentioning
# `docs/version-catalog.md` was returned as an image tag, and step (h) then
# reported three images that exist nowhere. The section is prose plus a table;
# only the table names images, so only the table is read.
#
# The header separator row (|---|---|) is skipped by its leading dash, and the
# Image column is deliberately not read: a name in backticks there must never
# be mistaken for the tag beside it.
#
# Fails closed: a missing file returns 1 with nothing printed. A file that
# exists but no longer has a "Docker base images" table returns 0 with
# EMPTY output — the caller in step (h) treats a zero-row result as a
# guard that FAILED TO RUN, the same "empty list read as nothing missing"
# doctrine guard (a)'s `compose_image_refs_present` and guard (e)'s
# submodule-status check already apply to their own evidence.
version_catalog_images() {
  if [ ! -f "$1" ]; then
    echo "ci-guards: $1 does not exist." >&2
    return 1
  fi
  awk "$CI_VERSION_CATALOG_AWK_SCRIPT" "$1"
}

# Image refs a shell SCRIPT pins for `docker run` — invisible to both a
# Dockerfile `FROM` and a compose `image:`.
#
# Step (h) defined "reality" as three Dockerfiles plus `docker compose config`,
# which is narrower than the set of image tags this repo actually pins:
# scripts/e2e-container.sh pulls the 3.45GB Playwright image itself. That pin
# was therefore invisible in BOTH directions — it could never be reported as
# uncataloged, and cataloging it fired the stale-row check instead. A guard
# whose notion of "used" is narrower than the set of pins reports the honest
# answer as a defect.
#
# Matched by CONVENTION, not by shape: the ref must be assigned to a variable
# named IMAGE. Recognising "things that look like an image ref" in arbitrary
# shell matches a URL eventually, and this file's whole thesis is that a guard
# which fires on the wrong thing gets disabled.
script_pinned_images() {
  if [ ! -d "$1" ]; then
    echo "ci-guards: $1 is not a directory." >&2
    return 1
  fi
  find "$1" -type f -name '*.sh' -exec grep -h -E '^[[:space:]]*IMAGE=' {} + 2>/dev/null |
    sed -E 's/^[[:space:]]*IMAGE=["]?([^"[:space:]]+)["]?.*$/\1/' |
    grep -v '^$' |
    sort -u
}

# The Bun the WRAPPER installs against the Bun the APPS are built with.
#
# Prints one line per disagreeing Dockerfile, empty when they agree. Exits 1
# only when the workflow carries no bun-version at all — a guard that cannot
# find its own subject has failed to run, and must not read as agreement.
#
# This is the drift the `Set up Bun` comment says that pin exists to prevent,
# and nothing checked it: step (h) reads Dockerfile FROM bases and compose
# image refs, and `bun-version:` is neither. The comment above that pin has now
# outlived its fact twice, which is what an unguarded claim does.
#
# Each file is read for whichever form it uses to pin Bun: `FROM oven/bun:X`
# in a Dockerfile, `bash -s bun-vX` where a script runs the official installer.
# scripts/e2e-container.sh was the third copy of this version and the only one
# no gate touched, which is exactly how it kept a stale pin.
#
# The catalog is deliberately NOT a fourth comparison here. Step (h) already
# compares docs/version-catalog.md against Dockerfile FROM bases in BOTH
# directions, so catalog == Dockerfile is gated there; this gates
# workflow == Dockerfile and installer == Dockerfile. The chain closes, and a
# redundant guard over the same fact is one more thing to drift.
bun_version_divergence() {
  CI_BVD_WF="$1"
  shift
  CI_BVD_WANT=$(grep -E '^[[:space:]]*bun-version:' "$CI_BVD_WF" 2>/dev/null |
    head -1 |
    sed -E "s/.*bun-version:[[:space:]]*['\"]?([^'\"[:space:]]+).*/\1/")
  if [ -z "$CI_BVD_WANT" ]; then
    echo "ci-guards: no bun-version found in $CI_BVD_WF." >&2
    return 1
  fi
  CI_BVD_UNREADABLE=0
  for CI_BVD_DF in "$@"; do
    # A file that is not there is NOT a file that agrees. Renaming or moving any
    # one of the four live subjects used to make this gate go green having
    # compared nothing — the green-over-no-evidence shape `compose_image_refs_present`
    # and step (e) both refuse by name. "Declares no Bun stage" and "does not
    # exist" are different answers and only the first is silence.
    if [ ! -f "$CI_BVD_DF" ]; then
      echo "ci-guards: bun_version_divergence: $CI_BVD_DF does not exist." >&2
      CI_BVD_UNREADABLE=1
      continue
    fi
    CI_BVD_GOT=$(grep -E '^FROM oven/bun:' "$CI_BVD_DF" 2>/dev/null |
      head -1 |
      sed -E 's|^FROM oven/bun:([^ ]+).*|\1|')
    if [ -z "$CI_BVD_GOT" ]; then
      CI_BVD_GOT=$(grep -oE 'bash -s bun-v[0-9][^"'"'"' ]*' "$CI_BVD_DF" 2>/dev/null |
        head -1 |
        sed -E 's|^bash -s bun-v||')
    fi
    [ -n "$CI_BVD_GOT" ] || continue
    [ "$CI_BVD_GOT" = "$CI_BVD_WANT" ] ||
      echo "$CI_BVD_DF pins Bun $CI_BVD_GOT but the workflow installs bun-version $CI_BVD_WANT"
  done
  [ "$CI_BVD_UNREADABLE" -eq 0 ]
}

# The Bun version the PROSE documents claim, against the one actually pinned.
#
# `bun_version_divergence` covers workflow, both Dockerfiles and the installer
# script; step (h) covers the catalog against Dockerfile FROM bases. That left
# CLAUDE.md's toolchain line and docs/dev-setup.md — the two documents a human
# reads FIRST — in no verification chain at all. They are where the last stale
# Bun version was found, and finding it needed a human reading the file.
#
# Prefix comparison, not equality: prose legitimately says "Bun 1.4" or "1.4.x"
# where the pin says "1.4.0". A doc claiming 1.3 against a 1.4.0 pin still
# fails, which is the case that matters.
#
# Exits 1 when a document names no Bun version at all — a guard that cannot
# find its subject has failed to run, and must not read as agreement.
bun_doc_divergence() {
  CI_BDD_WANT="$1"
  shift
  CI_BDD_UNREADABLE=0
  for CI_BDD_DOC in "$@"; do
    CI_BDD_FOUND=$(grep -oE 'Bun[^0-9]{0,8}[0-9]+\.[0-9]+(\.[0-9x]+)?' "$CI_BDD_DOC" 2>/dev/null |
      sed -E 's/^Bun[^0-9]*//' |
      sort -u)
    # Accumulated, not returned from inside the loop. Returning here named the
    # first bad document and left every later one unexamined — so a stale
    # docs/dev-setup.md could hide behind an unreadable CLAUDE.md.
    if [ -z "$CI_BDD_FOUND" ]; then
      echo "ci-guards: no Bun version found in $CI_BDD_DOC." >&2
      CI_BDD_UNREADABLE=1
      continue
    fi
    for CI_BDD_V in $CI_BDD_FOUND; do
      CI_BDD_BASE=$(printf '%s' "$CI_BDD_V" | sed -E 's/\.x$//')
      case "$CI_BDD_WANT" in
        "$CI_BDD_BASE" | "$CI_BDD_BASE".*) ;;
        *) echo "$CI_BDD_DOC documents Bun $CI_BDD_V but the pinned version is $CI_BDD_WANT" ;;
      esac
    done
  done
  [ "$CI_BDD_UNREADABLE" -eq 0 ]
}

# bars/ files that name neither a declared role nor a declared non-role
# catalogue. Prints one basename per offender; empty means clean.
#
# Every completeness check in this repo runs ONE direction: roles.json declares
# a role, does bars/<ROLE>.json exist. Nothing ran the mirror, so any .json
# dropped into bars/ was silently promoted to a role — measured against the
# leader anchor ceiling, shape-checked for 3 indicators, made a peer in
# cross-role duplicate detection — while getting zero pair coverage, zero
# locale-gap tracking and zero role-level accounting.
#
# POTENTIAL.json is the real case and the reason this exists: `potential` is an
# ASSESSMENT TYPE, not a role. It carries MTG and LAT, which no role declares,
# so its two competencies sit outside the 83 role x competency pairs the rest
# of the catalogue governs. That is legitimate and it is why the exception is
# DECLARED here by name rather than inferred from a filename. A file nobody
# listed is a file nobody decided on.
# Overridable like CI_KNOWN_GAPS_FILE and CI_COMPETENCY_GAPS_FILE, so a
# self-test can prove the mechanism against a fixture instead of the
# committed list. Declared HERE, beside its guard, which is where every
# other constant in this file lives (CI_EXPECTED_COMPOSE_SERVICES, the
# gap-file paths, the awk and Bun scripts) — there is no top-of-file
# cluster to join.
CI_NON_ROLE_BARS_FILES="${CI_NON_ROLE_BARS_FILES:-POTENTIAL}"

bars_files_without_declared_role() {
  CI_BFDR_TREE="$1"
  if [ ! -d "$CI_BFDR_TREE/bars" ]; then
    echo "ci-guards: $CI_BFDR_TREE/bars is not a directory." >&2
    return 1
  fi
  if ! CI_BFDR_ROLES=$(role_keys "$CI_BFDR_TREE/roles.json"); then
    echo "ci-guards: bars_files_without_declared_role: could not read roles from $CI_BFDR_TREE." >&2
    return 1
  fi
  for CI_BFDR_FILE in "$CI_BFDR_TREE"/bars/*.json; do
    [ -e "$CI_BFDR_FILE" ] || continue
    CI_BFDR_NAME=$(basename "$CI_BFDR_FILE" .json)
    if printf '%s\n' "$CI_BFDR_ROLES" | grep -qxF "$CI_BFDR_NAME"; then
      continue
    fi
    case " $CI_NON_ROLE_BARS_FILES " in
      *" $CI_BFDR_NAME "*) continue ;;
    esac
    printf '%s\n' "$CI_BFDR_NAME"
  done
}

# Locale completeness for the NON-ROLE bars files.
#
# Declaring POTENTIAL.json in CI_NON_ROLE_BARS_FILES stops the mirror guard
# firing. It does NOT give the file coverage, and treating the declaration as
# the fix would be the same "documented, therefore handled" move this file
# rejects everywhere else. Every locale and pair guard is keyed on
# role_competency_pairs, and MTG and LAT are in no role, so nothing checked
# whether their Italian exists. They are complete today. Clean today is not the
# same thing as checked.
#
# Emits LOCALE:FILE:COMPETENCY per incomplete competency; empty means clean.
# shellcheck disable=SC2016
CI_NON_ROLE_LOCALE_SCRIPT='
  const tree = process.env.CI_TREE;
  const file = process.env.CI_NRB_FILE;
  const locale = process.env.CI_NRB_LOCALE;
  const path = `${tree}/bars/${file}.json`;

  let bars;
  try {
    bars = JSON.parse(await Bun.file(path).text());
  } catch (e) {
    console.error(`ci-guards: cannot read ${path}: ${e.message}`);
    process.exit(1);
  }
  if (bars === null || typeof bars !== "object" || Array.isArray(bars)) {
    console.error(`ci-guards: ${path} is not a JSON object.`);
    process.exit(1);
  }

  const out = [];
  for (const comp of Object.keys(bars)) {
    const entries = bars[comp];
    if (!Array.isArray(entries) || entries.length === 0) {
      out.push(`${locale}:${file}:${comp}`);
      continue;
    }
    let complete = true;
    for (const entry of entries) {
      if (entry === null || typeof entry !== "object") { complete = false; break; }
      const values = [entry.indicator, entry.scale?.["5"], entry.scale?.["3"], entry.scale?.["1"]];
      for (const v of values) {
        if (v === null || typeof v !== "object" || Array.isArray(v)) { complete = false; break; }
        const t = v[locale];
        if (typeof t !== "string" || t.trim() === "") { complete = false; break; }
      }
      if (!complete) break;
    }
    if (!complete) out.push(`${locale}:${file}:${comp}`);
  }
  if (out.length > 0) console.log(out.join("\n"));
'

non_role_bars_locale_gaps() {
  CI_NRBLG_TREE="$1"
  CI_NRBLG_LOCALE="$2"
  if [ ! -d "$CI_NRBLG_TREE/bars" ]; then
    echo "ci-guards: $CI_NRBLG_TREE/bars is not a directory." >&2
    return 1
  fi
  for CI_NRBLG_FILE in $CI_NON_ROLE_BARS_FILES; do
    [ -f "$CI_NRBLG_TREE/bars/$CI_NRBLG_FILE.json" ] || {
      echo "ci-guards: non_role_bars_locale_gaps: $CI_NRBLG_TREE/bars/$CI_NRBLG_FILE.json is declared in CI_NON_ROLE_BARS_FILES but does not exist." >&2
      return 1
    }
    CI_TREE="$CI_NRBLG_TREE" CI_NRB_FILE="$CI_NRBLG_FILE" CI_NRB_LOCALE="$CI_NRBLG_LOCALE" \
      bun --eval "$CI_NON_ROLE_LOCALE_SCRIPT" || return 1
  done
}

# A repo whose VERSION file and manifest disagree about its own version.
#
# Prints one line per disagreeing repo; empty means clean. Exits 1 when a repo
# it was asked about has neither file, because a version check that finds no
# version has not passed, it has failed to run.
#
# The api already asserts VERSION == composer.json == openapi.json in its own
# CI. The two Nuxt apps asserted nothing, and both drifted: patch releases
# bumped package.json and left VERSION behind (backoffice 0.24.0 vs 0.25.1,
# frontend 0.11.0 vs 0.11.2), and the wrapper did the same in the other
# direction (VERSION 0.27.0, package.json 0.28.0). Three repos, one released
# artifact each, two answers each about which version it is.
#
# Checked HERE rather than in each app because this is the only place that can
# see all four at once — and because a guard living in the repo it guards is a
# guard that ships with the mistake.
version_manifest_divergence() {
  CI_VMD_FAILED=0
  for CI_VMD_DIR in "$@"; do
    CI_VMD_VFILE="$CI_VMD_DIR/VERSION"
    if [ ! -f "$CI_VMD_VFILE" ]; then
      echo "ci-guards: $CI_VMD_VFILE does not exist." >&2
      CI_VMD_FAILED=1
      continue
    fi
    CI_VMD_VERSION=$(tr -d ' \t\n\r' < "$CI_VMD_VFILE")
    if [ -z "$CI_VMD_VERSION" ]; then
      echo "ci-guards: $CI_VMD_VFILE is empty." >&2
      CI_VMD_FAILED=1
      continue
    fi
    CI_VMD_SEEN=0
    for CI_VMD_MANIFEST in "$CI_VMD_DIR/package.json" "$CI_VMD_DIR/composer.json"; do
      [ -f "$CI_VMD_MANIFEST" ] || continue
      CI_VMD_MVERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CI_VMD_MANIFEST" | head -1)
      [ -n "$CI_VMD_MVERSION" ] || continue
      CI_VMD_SEEN=1
      [ "$CI_VMD_MVERSION" = "$CI_VMD_VERSION" ] ||
        echo "$CI_VMD_MANIFEST says $CI_VMD_MVERSION but $CI_VMD_VFILE says $CI_VMD_VERSION"
    done
    if [ "$CI_VMD_SEEN" -eq 0 ]; then
      echo "ci-guards: $CI_VMD_DIR has a VERSION file but no manifest declaring a version." >&2
      CI_VMD_FAILED=1
    fi
  done
  [ "$CI_VMD_FAILED" -eq 0 ]
}

# Lines in set $1 (newline-separated) absent, byte-for-byte, from set $2.
# Shared by BOTH directions of the catalog check: "used but not cataloged"
# is this called as (used, catalog); "cataloged but no longer used" is the
# SAME function with the two arguments swapped. A symmetric failure mode
# gets one implementation, not two copies that could drift from each
# other — the exact defect shape this whole file exists to rule out,
# applied to itself.
#
# Blank lines in $1 are skipped rather than reported. Always exits 0 — a
# pure set operation over text the caller already validated non-empty
# (see the min-evidence checks in step (h) for both operands).
image_set_difference() {
  printf '%s\n' "$1" | while IFS= read -r CI_ISD_ITEM; do
    [ -n "$CI_ISD_ITEM" ] || continue
    printf '%s\n' "$2" | grep -qxF "$CI_ISD_ITEM" && continue
    printf '%s\n' "$CI_ISD_ITEM"
  done
}

# ---------------------------------------------------------------------------
# Bun-only, in the Nuxt apps.
#
# Matched as COMMANDS rather than bare words, so a line documenting the
# prohibition ("npm, pnpm and yarn are not used") is not itself a violation.
#
# --exclude-dir, not a post-filter on the output. `grep -v node_modules`
# matched the whole `path:line:text` string, so a README line that merely
# MENTIONED node_modules was dropped along with the directory.
#
# DOCKERFILES ARE IN SCOPE. The comment beside the real gate says "No
# carve-outs" and the file list quietly contained one: frontend/Dockerfile and
# backoffice/Dockerfile ARE the install and build path for both Nuxt apps — the
# most load-bearing place a stray `npm ci` could appear — and neither was ever
# read. They are clean today, which is not the same thing as being checked.
#
# TWO PASSES, because `#` does not mean the same thing in every file the guard
# reads. In YAML, shell and Dockerfiles it starts a comment, and a commented-out
# command does not run: without that exemption the guard flagged the comment in
# each submodule's CI explaining why it STOPPED using npm, and a check that
# cannot tell code from an explanation of the fix will keep reporting the fix.
#
# In MARKDOWN, `#` starts a HEADING. Applying the comment filter there silently
# dropped `# npm install` — a heading instructing the reader to run it — and
# Markdown was added to this guard precisely because both READMEs once shipped
# `npm install` as the first instruction a new developer read. The exemption
# meant to protect an explanation was deleting the violation instead.
#
# JSON has no comment syntax at all, so it goes with Markdown: a `#` line there
# is not a comment either.
#
# Prints every offending `path:line:text`. Empty output means clean.
# ---------------------------------------------------------------------------
CI_BUN_ONLY_PATTERN='(^|[^a-z-])((npm|pnpm|yarn)[[:space:]]+(install|run|add|exec|create|dlx|ci|test|build|dev|start|link|update|why|list)|(npx|pnpx)[[:space:]]+[a-zA-Z@])'

scan_bun_only() {
  # Pass 1 — file types where a leading `#` really is a comment.
  grep -rn -E \
    --include="*.yml" --include="*.yaml" --include="*.sh" --include="Dockerfile*" \
    --exclude-dir=node_modules --exclude-dir=.nuxt --exclude-dir=.output \
    "$CI_BUN_ONLY_PATTERN" "$@" 2>/dev/null \
    | grep -v -E '^[^:]*:[0-9]+:[[:space:]]*#' || true

  # Pass 2 — Markdown and JSON, where it is a heading or a syntax error.
  grep -rn -E \
    --include="*.md" --include="*.json" \
    --exclude-dir=node_modules --exclude-dir=.nuxt --exclude-dir=.output \
    "$CI_BUN_ONLY_PATTERN" "$@" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Sanctum — the sharpest rule in the standards ("JWT, NOT Sanctum") and the
# most fragile mechanism here: a `-l` pass piped through xargs into a second
# grep. Untested, it was one pipe away from silently passing everything.
#
# composer.json/lock are included deliberately: the dependency manifest is the
# ONE place `laravel/sanctum` would ever actually appear, and it used to be
# excluded — so the strongest auth rule in the standards had a guard blind to
# the only file that could break it.
#
# The `-l` pass filters PATHS; the second grep re-reads the survivors so the
# "NOT Sanctum" carve-out can be applied to LINE TEXT. Doing it in one pass
# would let a genuine violation hide behind a nearby sentence that says the
# rule out loud.
#
# Prints every offending `path:text`. Empty output means clean.
# ---------------------------------------------------------------------------
scan_sanctum() {
  grep -rl \
    --include="*.php" --include="*.ts" --include="*.vue" \
    --include="composer.json" --include="composer.lock" \
    --exclude-dir=vendor --exclude-dir=node_modules \
    "Sanctum\|sanctum" "$@" 2>/dev/null \
    | grep -v "design.md\|openspec/" \
    | xargs -r grep -H "Sanctum\|sanctum" \
    | grep -v "NOT Sanctum\|not Sanctum\|not use Sanctum" || true
}

# ---------------------------------------------------------------------------
# MySQL/MariaDB — the stack is Postgres.
#
# The exclusions are each a hit that is legitimate rather than a violation:
# this workflow contains the search pattern itself; Laravel's config/database.php
# ships a connection block for every driver it supports; the Pulse migration is
# vendor-published and multi-driver by design.
#
# The include and exclude lists are part of the RULE, not incidental flags, and
# that is why this had to become a function. The self-test used to re-type this
# guard as `grep -rl --include="*.php"` — one include where the real gate has
# six, no --exclude-dir where it has three, no path filters where it has five.
# Adding `--exclude-dir=api` to the real gate would have left the self-test
# green over a guard that no longer looked at the API at all.
#
# Prints every offending path. Empty output means clean.
# ---------------------------------------------------------------------------
scan_mysql() {
  grep -rl \
    --include="*.php" --include="*.ts" --include="*.vue" \
    --include="*.json" --include="*.yml" --include="*.yaml" \
    --exclude-dir=vendor --exclude-dir=node_modules --exclude-dir=.nuxt \
    "mysql\|mariadb" "$@" 2>/dev/null \
    | grep -v "design.md" \
    | grep -v "openspec/changes" \
    | grep -v ".github/workflows/wrapper-ci.yml" \
    | grep -v "api/config/database.php" \
    | grep -v "create_pulse_tables.php" \
    || true
}

# ---------------------------------------------------------------------------
# Laravel 12 — we are on 13.
#
# `-l`, so the exclusions filter PATHS. Without it the output is path:line and
# a genuine violation whose LINE TEXT happens to mention design.md is silently
# swallowed. The self-test's copy used `--include="notes.md"`, which is not a
# rule anybody wrote — it was a fixture filename.
#
# Prints every offending path. Empty output means clean.
# ---------------------------------------------------------------------------
scan_laravel12() {
  grep -rl \
    --include="*.php" --include="*.json" --include="*.md" \
    --exclude-dir=vendor --exclude-dir=node_modules \
    "Laravel 12\|laravel/laravel:^12" "$@" 2>/dev/null \
    | grep -v "design.md" \
    | grep -v "openspec/" \
    | grep -v "legacy-demo" \
    || true
}

# ---------------------------------------------------------------------------
# Horizon stays uninstalled. Ratified 2026-07-28 and stated in CLAUDE.md:
# workers run Laravel's native queue:work + schedule:work — the compose
# `worker` and `scheduler` services — and Horizon "is deferred, NOT installed".
#
# BOTH manifests. composer.json is what somebody edits; composer.lock is what
# actually got installed, and a transitive pull-in shows up only there. The
# self-test's copy read composer.json alone, so it proved half the rule.
#
# Prints every offending path. Empty output means clean.
# ---------------------------------------------------------------------------
scan_horizon() {
  grep -rl \
    --include="composer.json" --include="composer.lock" \
    --exclude-dir=vendor \
    "laravel/horizon" "$@" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The pgsql pin — a POSITIVE assertion, and the only one here.
#
# Grepping for a forbidden word says nothing about configuration: Laravel's
# stock config mentions every driver it supports and always will. What matters
# is which one the stack SELECTS, and that is an invariant about a line being
# PRESENT.
#
# Its failure mode is therefore inverted, which is what made the self-test's
# version worthless: it asserted that `grep -q "DB_CONNECTION: pgsql"` failed
# on a fixture that had never contained the string. Of course it failed. That
# row exercised no mechanism and would have stayed green with the guard
# deleted. Both directions are asserted now.
#
# Exit 0 when $1 pins pgsql, 1 otherwise — including when the file is missing.
# ---------------------------------------------------------------------------
compose_pins_pgsql() {
  grep -q "DB_CONNECTION: pgsql" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# The compose service set.
#
# `docker compose config -q` proves the file PARSES. It says nothing about what
# is in it, so the comment claiming "all 8 services" was asserted by nothing:
# delete `worker` or `scheduler` and the step stayed green while the comment
# claimed coverage. That is not a cosmetic gap — guard (g)'s entire rationale
# for keeping Horizon deferred is that those two services exist and run
# `queue:work` / `schedule:work`. A claim that load-bearing has to be checked.
#
# Asserted as an exact SET, not a count. A count passes when one service is
# renamed and another added, which is precisely when you want to be told.
#
# $1 is the actual service list (whitespace-separated, any order). Prints the
# expected and actual sets and returns 1 on mismatch; silent 0 on match.
# ---------------------------------------------------------------------------
CI_EXPECTED_COMPOSE_SERVICES='api backoffice frontend mailpit postgres redis scheduler worker'

compose_service_diff() {
  CI_WANT=$(printf '%s' "$CI_EXPECTED_COMPOSE_SERVICES" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')
  CI_GOT=$(printf '%s' "$1" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')
  if [ "$CI_GOT" = "$CI_WANT" ]; then
    return 0
  fi
  printf 'expected: %s\n' "$CI_WANT"
  printf 'actual:   %s\n' "$CI_GOT"
  return 1
}

# ---------------------------------------------------------------------------
# Minimum-evidence guard for the compose image-pin check.
#
# `docker compose config | grep -E '^\s*image:' | while read -r _ REF; do ...`
# matching ZERO lines walks that loop zero times, prints nothing to
# /tmp/unpinned.txt, and the step announced "All compose image tags are
# pinned" having examined NOTHING. Same shape guard (e) already refuses for
# submodule pointers ("An empty list would walk the loop zero times ... a
# green gate over no evidence") — a rule that binds one gate and not the next
# is a preference, not a rule. Triggers: a compose format change, a service
# becoming build-only, or the `image:` key moving.
#
# Extracted (rather than left inline in the workflow step) for the same
# reason `tag_pinned` and `compose_service_diff` are: so the self-test in (f)
# exercises the SAME predicate the real gate calls, not a private copy of it.
#
# $1 is the count of `image:` lines matched (an integer, e.g. from
# `grep -cE '^\s*image:'`). Exit 0 when at least one was found — there is
# evidence to check — 1 otherwise.
# ---------------------------------------------------------------------------
compose_image_refs_present() {
  [ "$1" -ge 1 ] 2>/dev/null
}

# ---------------------------------------------------------------------------
# Submodule pointer reachability — can everybody else FETCH this commit?
#
# Lives here rather than inline in step (e) because it was inline in step (e),
# and that made two statements in this repo false at once: this file's header
# claim that the guard mechanisms are not written into the workflow, and the
# workflow's own promise that every guard is proven against a known-bad
# fixture. There was no reachability row in the self-test — not one. Changing
# `--contains` to `--no-contains`, or dropping the namespace argument so the
# question is asked of every local ref, would have left the self-test green
# over a guard that then approves a pointer nobody can fetch.
#
# That is verbatim this workflow's own diagnosis — "three of them had never
# once gone red, and all three were broken" — landing on the newest and most
# intricate guard in it, the one added specifically for release and hotfix
# branches. Extracted, so the fixture rows below it can exist.
#
# The namespace is load-bearing. Everything under refs/remotes/ci-verify/
# demonstrably arrived from origin during THIS run, which is what makes a hit
# mean "published" rather than "present on this disk". Asking refs/tags
# directly would let a purely local tag — one nobody else can fetch — vouch for
# a commit as fetchable by everyone.
# ---------------------------------------------------------------------------
CI_VERIFY_REFS='refs/remotes/ci-verify'

# Fetch every published head and tag from origin into the verification
# namespace. Non-zero means the question could not be ASKED — a network,
# credentials or remote-name failure — which callers must report differently
# from an unreachable pointer. stderr is left alone so the cause survives.
submodule_fetch_published_refs() {
  git -C "$1" fetch -q origin \
    "+refs/heads/*:$CI_VERIFY_REFS/heads/*" \
    "+refs/tags/*:$CI_VERIFY_REFS/tags/*"
}

# Print the published refs containing commit $2 in repo $1, one per line.
# Exit 0 when at least one does, 1 when none does — including when the commit
# is not in the object store at all, which is the same answer for the same
# reason: nobody can fetch it.
commit_reachable_from_remote() {
  CI_CONTAINED=$(git -C "$1" for-each-ref --contains "$2" \
    --format='%(refname:short)' "$CI_VERIFY_REFS" 2>/dev/null \
    | sed 's|^ci-verify/||')
  [ -n "$CI_CONTAINED" ] || return 1
  printf '%s\n' "$CI_CONTAINED"
}

# Put the repository back as it was found. On a CI runner the clone is thrown
# away and this costs nothing, but this guard gets run by hand to debug a red
# pipeline, and there it would otherwise leave dozens of stray refs in
# somebody's working clone forever.
submodule_clear_verify_refs() {
  git -C "$1" for-each-ref --format="delete %(refname)" "$CI_VERIFY_REFS" \
    | git -C "$1" update-ref --stdin
}

# ---------------------------------------------------------------------------
# Canonical-JSON equality — the mechanism behind BOTH the openapi cross-repo
# gate and the framework-catalog gate.
#
# Compared as PARSED JSON with keys sorted RECURSIVELY, not as bytes: prettier
# reformats these files in the Nuxt repos, so a byte comparison fails on
# whitespace while the contract is identical.
#
# The obvious-looking JSON.stringify(v, Object.keys(v).sort()) does NOT do
# this. That second argument is a replacer ARRAY: it FILTERS properties by
# name, at every level, so almost the whole document drops out of the
# comparison. Written that way the openapi gate reported "identical" against a
# deliberately corrupted spec — verified, and it is why the failure path is
# part of the self-test.
#
# The paths travel through the ENVIRONMENT. `bun --eval 'script' A=...` puts
# that in argv, where process.env cannot see it; the first version of the
# catalog gate merely ASSIGNED the variables without exporting them, so every
# file threw inside the script and every file was reported as differing.
#
# Bun, not Python. Python is not in the required toolchain (docs/dev-setup.md:
# PHP, Composer, Bun, Node, Docker, Playwright, go-task, git, k6), and
# installing a whole language runtime to do a JSON.parse and an equality check
# is a D37 dependency question rather than a style preference.
#
# Exit 0 when both files parse to the same document, 1 when both parse but
# differ, 2 when either file is missing, unreadable, or is not valid JSON.
#
# 1 and 2 are DELIBERATELY different exit codes, not the same "nonzero" —
# this file's own doctrine, applied to itself. "Could not be read" and
# "differs" are separated everywhere else a guard in this repo touches a file
# it did not author (step (a)'s missing-Dockerfile check, step (e)'s
# fetch-failure-versus-unreachable-pointer split, and the comment above step
# (b)'s call site here) — before this fix `json_canonical_equal` did the
# separation in every OTHER caller's intent but not in its own mechanism: an
# uncaught JSON.parse throw and a real content mismatch both exited 1, so a
# genuinely malformed file was reported with the exact same wording as real
# drift ("differs from api/openapi.json"), sending the next operator hunting
# for a content change in a file that was never parseable to begin with.
#
# The stderr write on the exit-2 path is INTENTIONAL and NOT discarded —
# `2>/dev/null` used to swallow bun's own parse-error trace here, which is
# exactly what buried this distinction. Callers that want the reason
# (both real gates below do) capture stderr themselves; callers that only
# care about the boolean (the self-test's "identical"/"differs" rows) are
# unaffected, because this path only ever writes when it is about to exit 2.
# ---------------------------------------------------------------------------
CI_JSON_CANONICAL_SCRIPT='
  const canonical = (v) => {
    if (Array.isArray(v)) return v.map(canonical);
    if (v === null || typeof v !== "object") return v;
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canonical(v[k])]));
  };
  const load = async (p) => {
    try {
      return JSON.stringify(canonical(JSON.parse(await Bun.file(p).text())));
    } catch (e) {
      process.stderr.write("CI_JSON_UNREADABLE: " + p + " is missing or is not valid JSON (" + e.message + ")\n");
      process.exit(2);
    }
  };
  const a = await load(process.env.CI_JSON_A);
  const b = await load(process.env.CI_JSON_B);
  process.exit(a === b ? 0 : 1);
'

json_canonical_equal() {
  CI_JSON_A="$1"
  CI_JSON_B="$2"
  export CI_JSON_A CI_JSON_B

  # The exit status is a CONTRACT (0 identical / 1 differs / 2 unreadable),
  # so it cannot be bun's raw status. The embedded script only ever exits
  # 0, 1 or 2 — but bun itself exits 127 when it is not on PATH, and can
  # exit on a signal or fail to start the script at all. Passing that
  # straight through put 127 into the callers' `else` branch, which reads
  # "differs from api/openapi.json" — the exact reporting bug the exit-2
  # split was added to end, reintroduced through a different door.
  # Anything that is not a clean 0 or 1 is "could not run".
  # The status MUST be captured in the `else` branch. After a bare
  # `if cmd; then ...; fi` the `if` itself resets `$?` to 0 when no branch
  # runs, so reading it on the next line reports success for a command that
  # just failed — the same trap the call sites in wrapper-ci.yml already
  # document, arrived at from the other direction.
  if bun --eval "$CI_JSON_CANONICAL_SCRIPT"; then
    return 0
  else
    CI_JSON_STATUS=$?
  fi
  if [ "$CI_JSON_STATUS" -eq 1 ]; then
    return 1
  fi
  if [ "$CI_JSON_STATUS" -ne 2 ]; then
    printf 'CI_JSON_UNREADABLE: comparison could not run (bun exited %s)\n' \
      "$CI_JSON_STATUS" >&2
  fi
  return 2
}

# ---------------------------------------------------------------------------
# The role keys a framework catalog declares, one per line.
#
# Used by the catalog COMPLETENESS assertion, which is a different question
# from the parity assertion beside it: parity proves the two copies agree,
# completeness proves what they agree on is whole. Both copies can be equally
# wrong, and both were.
#
# FAILS LOUDLY, and that is the whole point of this comment. The first version
# ran `bun --eval` and let the exit status evaporate: an unparseable roles.json
# — or no bun on PATH at all — printed nothing to stdout, so the caller saw an
# empty role list and step (d) reported the catalog COMPLETE. A one-character
# corruption in a binding artifact silently disabled the half of the gate that
# exists because SRX.json was missing.
#
# It was also inconsistent with the file it lives in, twice over.
# `json_canonical_equal`, twenty lines up, returns DIFFER when bun is broken —
# so two mechanisms guarding the same artifact failed in OPPOSITE directions.
# And `df_guard` above states the rule this one broke: a guard that cannot read
# its subject must never pass it.
#
# The SHAPE is asserted, not assumed. roles.json is an object keyed by role
# code; if it ever became an array, `Object.keys` would happily emit 0, 1, 2 and
# send the completeness check hunting for bars/0.json — an obviously wrong
# question, asked confidently. Everything the callers rely on is checked here:
# it is an object, it is not empty, and every key looks like a role code.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
# The single quotes are the point: `${path}` and friends below are JavaScript
# template-literal interpolations that must reach bun untouched. Letting the
# shell expand them would substitute empty strings into the error messages,
# which is precisely the diagnostic this function exists to print.
CI_ROLE_KEYS_SCRIPT='
  const path = process.env.CI_ROLES_FILE;
  let roles;
  try {
    roles = JSON.parse(await Bun.file(path).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${path}: ${e.message}`);
    process.exit(1);
  }
  if (roles === null || typeof roles !== "object" || Array.isArray(roles)) {
    const got = Array.isArray(roles) ? "an array" : roles === null ? "null" : typeof roles;
    console.error(`ci-guards: ${path} must be a JSON OBJECT keyed by role code, got ${got}.`);
    process.exit(1);
  }
  const keys = Object.keys(roles);
  if (keys.length === 0) {
    console.error(`ci-guards: ${path} declares no roles at all.`);
    process.exit(1);
  }
  const bad = keys.filter((k) => !/^[A-Z][A-Z0-9_]{1,15}$/.test(k));
  if (bad.length > 0) {
    console.error(`ci-guards: ${path} has keys that are not role codes: ${bad.join(", ")}`);
    process.exit(1);
  }
  console.log(keys.join("\n"));
'

role_keys() {
  CI_ROLES_FILE="$1"
  export CI_ROLES_FILE
  if [ ! -f "$CI_ROLES_FILE" ]; then
    echo "ci-guards: $CI_ROLES_FILE does not exist." >&2
    return 1
  fi
  # Exit status deliberately NOT swallowed, and stderr deliberately NOT
  # redirected to /dev/null: when this fails, whoever is reading the log needs
  # to know it failed to RUN rather than found nothing.
  bun --eval "$CI_ROLE_KEYS_SCRIPT"
}

# Prints every role declared in <tree>/roles.json that has no matching
# <tree>/bars/<ROLE>.json. Empty output means the catalog is complete.
#
# `$1` is a framework tree root — either the authored source or the vendored
# copy. Asked of both, because parity between two incomplete trees is still
# green and that is precisely what was happening.
#
# Returns non-zero when the role list could not be obtained, which is NOT the
# same as an empty list and must never be collapsed into one. The role list is
# captured to a variable BEFORE the loop for exactly this reason: piping
# `role_keys | while` discarded the failure, because a pipeline reports the
# status of its LAST command and the loop was happily succeeding over nothing.
#
# This is the raw fact. What CI does with it is decided by the two functions
# below, which weigh it against the committed known-gaps list.
catalog_missing_bars() {
  CI_ROLE_LIST=$(role_keys "$1/roles.json") || return 1
  printf '%s\n' "$CI_ROLE_LIST" | while IFS= read -r CI_ROLE; do
    [ -n "$CI_ROLE" ] || continue
    [ -f "$1/bars/$CI_ROLE.json" ] || printf '%s\n' "$CI_ROLE"
  done
}

# ---------------------------------------------------------------------------
# Known gaps — the committed list of roles allowed to ship without BARS.
#
# The completeness assertion needs a middle setting, and the two extremes are
# both wrong. Fail unconditionally and CI would stay permanently red over
# content nobody can produce on demand — SRX.json was exactly that, 54
# indicators of expert assessment content, until bars-catalogue-completion
# Phase 6 authored it; a gate that cannot go green gets deleted within a week
# and then protects nothing. Warn only, and it is silently green over an
# incomplete binding catalog, which is how the SRX gap survived undetected
# in the first place.
#
# So: fail for anything NOT on an explicit, committed list, and — the half that
# keeps the list honest — fail for anything ON the list that no longer needs to
# be. See scripts/framework-known-gaps.txt for the entries and the reasoning.
#
# The vocabulary is deliberately the runtime's own. FrameworkCatalogSeeder
# already records a missing BARS file as FrameworkGap kind=role_no_bars,
# status=pending_authoring rather than throwing; this is the same gap, asserted
# at review time instead of seed time, and inventing a second name for it would
# have given one fact two vocabularies to drift between.
#
# CI_KNOWN_GAPS_FILE is overridable so the self-test can point the SAME code at
# a fixture list. A path resolved relative to the repository root, because
# every CI step that sources this file runs there.
# ---------------------------------------------------------------------------
CI_KNOWN_GAPS_FILE="${CI_KNOWN_GAPS_FILE:-scripts/framework-known-gaps.txt}"

# The role codes on the list, one per line. Comments and blank lines dropped;
# only the first whitespace-delimited field of a line is read, so an entry can
# carry a trailing comment without being parsed as one.
known_gap_roles() {
  # ABSENT is a legitimate empty list; UNREADABLE is not. Both used to
  # return 0, which made every caller's "could not read the control file"
  # branch dead code: delete the file and the interleaving check reported
  # clean, exactly as before the guard that was added to stop it.
  if [ ! -f "$CI_KNOWN_GAPS_FILE" ]; then
    return 0
  fi
  if [ ! -r "$CI_KNOWN_GAPS_FILE" ]; then
    echo "ci-guards: $CI_KNOWN_GAPS_FILE exists but cannot be read." >&2
    return 1
  fi
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//' "$CI_KNOWN_GAPS_FILE" \
    | grep -v '^$' || true
}

# Roles missing their BARS file with NO committed exemption. Any output is a
# build failure: somebody declared a role and stopped there.
#
# Returns non-zero when the underlying role list could not be read at all —
# propagated from catalog_missing_bars rather than absorbed, so the caller can
# tell "nothing missing" from "could not look".
catalog_unexpected_missing_bars() {
  # Status kept. An UNREADABLE control file used to arrive here as an
  # empty list, and an empty list reads as "nothing exempt" — silently
  # green over a file nobody could open.
  if ! CI_KNOWN=$(known_gap_roles); then
    echo "ci-guards: known_gap_roles: could not read the control file." >&2
    return 1
  fi
  CI_MISSING=$(catalog_missing_bars "$1") || return 1
  printf '%s\n' "$CI_MISSING" | while IFS= read -r CI_ROLE; do
    [ -n "$CI_ROLE" ] || continue
    printf '%s\n' "$CI_KNOWN" | grep -qxF "$CI_ROLE" && continue
    printf '%s\n' "$CI_ROLE"
  done
}

# Roles on the known-gaps list whose BARS file now EXISTS. Any output is a
# build failure too, and this is the direction that stops the list rotting: the
# gap is closed, so the exemption is a lie about the catalog, and it has to be
# deleted in the commit that closes it. Without this the file would accumulate
# permanent entries excusing gaps that no longer exist — a note outliving its
# fact, which is the failure this workflow exists to prevent.
catalog_stale_gap_exemptions() {
  # Read to a variable FIRST. A pipeline reports its LAST command, so
  # `known_gap_roles | while ...` returned the loop's status and the reader's
  # "could not read" was discarded — the loop simply ran zero times over
  # nothing and the caller read that as "no entries".
  if ! CI_SGE_LIST=$(known_gap_roles); then
    echo "ci-guards: known_gap_roles: could not read the control file." >&2
    return 1
  fi
  printf '%s\n' "$CI_SGE_LIST" | while IFS= read -r CI_ROLE; do
    [ -n "$CI_ROLE" ] || continue
    if [ -f "$1/bars/$CI_ROLE.json" ]; then
      printf '%s\n' "$CI_ROLE"
    fi
  done
}

# ---------------------------------------------------------------------------
# The per-pair coverage gate (bars-coverage-visibility).
#
# One level finer than everything above. `catalog_missing_bars` and its two
# callers ask "does bars/<ROLE>.json EXIST" — a question with only two
# answers, yes or no. A file can exist and still be PARTIAL, and the
# role-level gate is structurally blind to that — the file is there, so it
# passes. Until bars-catalogue-completion this was the live state, not a
# hypothetical: FLL and MLL anchored 8 of their 18 assigned competencies and
# BUL 8 of its 14. All 83 pairs are anchored now; this gate is what would
# catch a regression back.
#
# Deliberately asks its question ONLY of roles whose bars file EXISTS. A role
# with no file at all is the role-level gate's business
# (scripts/framework-known-gaps.txt); this gate would otherwise declare the
# same absence twice, in two different vocabularies, and disagree with itself
# about which file is authoritative for it.
#
# CI_COMPETENCY_GAPS_FILE mirrors CI_KNOWN_GAPS_FILE's override seam so the
# self-test can point these functions at a fixture list without touching the
# committed one.
# ---------------------------------------------------------------------------
CI_COMPETENCY_GAPS_FILE="${CI_COMPETENCY_GAPS_FILE:-scripts/framework-competency-gaps.txt}"

# The ROLE:COMP pairs on the list, one per line. Same parsing discipline as
# known_gap_roles: '#' to end of line is a comment, blank lines dropped, only
# the first whitespace field is read so a trailing comment cannot corrupt it.
known_gap_pairs() {
  # ABSENT is a legitimate empty list; UNREADABLE is not. Both used to
  # return 0, which made every caller's "could not read the control file"
  # branch dead code: delete the file and the interleaving check reported
  # clean, exactly as before the guard that was added to stop it.
  if [ ! -f "$CI_COMPETENCY_GAPS_FILE" ]; then
    return 0
  fi
  if [ ! -r "$CI_COMPETENCY_GAPS_FILE" ]; then
    echo "ci-guards: $CI_COMPETENCY_GAPS_FILE exists but cannot be read." >&2
    return 1
  fi
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//' "$CI_COMPETENCY_GAPS_FILE" \
    | grep -v '^$' || true
}

# Every ROLE:COMP pair `<tree>/roles.json` declares, one per line, in the
# file's own role and competency order.
#
# FAILS LOUDLY on exactly the shapes catalog_missing_bars's role_keys already
# guards against (not an object, empty, keys that are not role codes), plus
# the shape this function additionally depends on: each role's `competencies`
# must be an ARRAY of role-code-shaped strings. A role whose competencies
# field is a bare string (or missing) would otherwise iterate that string's
# CHARACTERS in JavaScript — a wrong question asked silently confident.
#
# Returns non-zero, printing nothing to stdout, when the file could not be
# read or does not have this shape — the caller must treat that as "the guard
# failed to run", never as "nothing to report".
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
# Same reason as CI_ROLE_KEYS_SCRIPT above: this is a JavaScript template
# literal that must reach bun untouched.
CI_ROLE_COMPETENCY_PAIRS_SCRIPT='
  const path = process.env.CI_ROLES_FILE;
  let roles;
  try {
    roles = JSON.parse(await Bun.file(path).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${path}: ${e.message}`);
    process.exit(1);
  }
  if (roles === null || typeof roles !== "object" || Array.isArray(roles)) {
    const got = Array.isArray(roles) ? "an array" : roles === null ? "null" : typeof roles;
    console.error(`ci-guards: ${path} must be a JSON OBJECT keyed by role code, got ${got}.`);
    process.exit(1);
  }
  const roleKeys = Object.keys(roles);
  if (roleKeys.length === 0) {
    console.error(`ci-guards: ${path} declares no roles at all.`);
    process.exit(1);
  }
  const codeRe = /^[A-Z][A-Z0-9_]{1,15}$/;
  const badRoles = roleKeys.filter((k) => !codeRe.test(k));
  if (badRoles.length > 0) {
    console.error(`ci-guards: ${path} has keys that are not role codes: ${badRoles.join(", ")}`);
    process.exit(1);
  }
  const lines = [];
  for (const role of roleKeys) {
    const entry = roles[role];
    const comps = entry ? entry.competencies : undefined;
    if (!Array.isArray(comps)) {
      console.error(`ci-guards: ${path} role "${role}" has no competencies ARRAY.`);
      process.exit(1);
    }
    for (const comp of comps) {
      if (typeof comp !== "string" || !codeRe.test(comp)) {
        console.error(`ci-guards: ${path} role "${role}" has a competency that is not a role-code-shaped string: ${JSON.stringify(comp)}`);
        process.exit(1);
      }
      lines.push(role + ":" + comp);
    }
  }
  console.log(lines.join("\n"));
'

role_competency_pairs() {
  CI_ROLES_FILE="$1/roles.json"
  export CI_ROLES_FILE
  if [ ! -f "$CI_ROLES_FILE" ]; then
    echo "ci-guards: $CI_ROLES_FILE does not exist." >&2
    return 1
  fi
  bun --eval "$CI_ROLE_COMPETENCY_PAIRS_SCRIPT"
}

# The competency codes actually ANCHORED in `<tree>/bars/<ROLE>.json>`, one
# per line — a key whose value is a non-empty array. An empty array
# (`"PRS": []`) is a stub, not an anchor set, and is deliberately EXCLUDED
# from this output: the cheapest way to green this gate must not be stubbing
# the key.
#
# FAILS LOUDLY when the file is missing, unparseable, not a JSON object, or
# has a non-array value for any key — the same "a guard that cannot read its
# subject must never pass it" rule as everything else in this file.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
CI_BARS_COMPETENCY_KEYS_SCRIPT='
  const path = process.env.CI_BARS_FILE;
  let bars;
  try {
    bars = JSON.parse(await Bun.file(path).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${path}: ${e.message}`);
    process.exit(1);
  }
  if (bars === null || typeof bars !== "object" || Array.isArray(bars)) {
    const got = Array.isArray(bars) ? "an array" : bars === null ? "null" : typeof bars;
    console.error(`ci-guards: ${path} must be a JSON OBJECT keyed by competency code, got ${got}.`);
    process.exit(1);
  }
  const keys = Object.keys(bars);
  const badKeys = keys.filter((k) => !Array.isArray(bars[k]));
  if (badKeys.length > 0) {
    console.error(`ci-guards: ${path} has a non-ARRAY value for: ${badKeys.join(", ")}`);
    process.exit(1);
  }
  const covered = keys.filter((k) => bars[k].length > 0);
  console.log(covered.join("\n"));
'

bars_competency_keys() {
  CI_BARS_FILE="$1/bars/$2.json"
  export CI_BARS_FILE
  if [ ! -f "$CI_BARS_FILE" ]; then
    echo "ci-guards: $CI_BARS_FILE does not exist." >&2
    return 1
  fi
  bun --eval "$CI_BARS_COMPETENCY_KEYS_SCRIPT"
}

# Role×competency pairs with NO anchors, for every role whose bars file
# EXISTS — printed as ROLE:COMP, one per line. Empty output means every role
# that HAS a file is fully anchored (a role with no file at all is silently
# skipped here on purpose, see the section header above).
#
# The role list is captured to a FILE before the loop that reads it, not
# piped into `while` — the exact fix `catalog_missing_bars` needed,
# generalised: the right-hand side of a pipe is a subshell, and a
# failure flag assigned inside one is discarded the moment the pipe closes.
# A per-role bars-file read failure (malformed JSON, wrong shape) sets
# CI_CMBP_FAIL in the loop that reads `< "$CI_CMBP_ROLES"` — a redirected
# file, run in the CURRENT shell — so it survives to the `return` below.
#
# Returns non-zero, on ANY read failure anywhere in the tree — role list or
# any individual bars file — printing whatever pairs it could still determine
# to stdout regardless. The caller decides what to do with a partial list
# under a non-zero exit; today's only caller propagates the failure outright.
catalog_missing_bars_pairs() {
  CI_CMBP_TREE="$1"
  CI_CMBP_PAIRS=$(mktemp)
  CI_CMBP_ROLES_RAW=$(mktemp)
  CI_CMBP_ROLES=$(mktemp)

  if ! role_competency_pairs "$CI_CMBP_TREE" > "$CI_CMBP_PAIRS"; then
    rm -f "$CI_CMBP_PAIRS" "$CI_CMBP_ROLES_RAW" "$CI_CMBP_ROLES"
    return 1
  fi

  sed 's/:.*//' "$CI_CMBP_PAIRS" > "$CI_CMBP_ROLES_RAW"

  # Distinct roles, first-seen order preserved (no `sort -u`, which would
  # alphabetise and lose roles.json's own declaration order — the order the
  # generated gaps file is meant to inherit).
  CI_CMBP_SEEN=""
  while IFS= read -r CI_CMBP_ROLE; do
    [ -n "$CI_CMBP_ROLE" ] || continue
    case " $CI_CMBP_SEEN " in
      *" $CI_CMBP_ROLE "*) continue ;;
    esac
    CI_CMBP_SEEN="$CI_CMBP_SEEN $CI_CMBP_ROLE"
    printf '%s\n' "$CI_CMBP_ROLE"
  done < "$CI_CMBP_ROLES_RAW" > "$CI_CMBP_ROLES"

  CI_CMBP_FAIL=0
  while IFS= read -r CI_CMBP_ROLE; do
    [ -n "$CI_CMBP_ROLE" ] || continue
    [ -f "$CI_CMBP_TREE/bars/$CI_CMBP_ROLE.json" ] || continue

    if ! CI_CMBP_COVERED=$(bars_competency_keys "$CI_CMBP_TREE" "$CI_CMBP_ROLE"); then
      CI_CMBP_FAIL=1
      continue
    fi

    grep "^$CI_CMBP_ROLE:" "$CI_CMBP_PAIRS" | while IFS= read -r CI_CMBP_PAIR; do
      CI_CMBP_COMP=${CI_CMBP_PAIR#*:}
      printf '%s\n' "$CI_CMBP_COVERED" | grep -qxF "$CI_CMBP_COMP" && continue
      printf '%s\n' "$CI_CMBP_PAIR"
    done
  done < "$CI_CMBP_ROLES"

  rm -f "$CI_CMBP_PAIRS" "$CI_CMBP_ROLES_RAW" "$CI_CMBP_ROLES"
  [ "$CI_CMBP_FAIL" -eq 0 ]
}

# Pairs missing anchors with NO committed exemption. Any output is a build
# failure — mirrors catalog_unexpected_missing_bars exactly, one level down.
#
# Propagates catalog_missing_bars_pairs's failure rather than absorbing it —
# the same rule role_no_bars's caller obeys, checked directly by the
# pair-malformed self-test row: a bars file that is the wrong shape must
# reach THIS function's exit status, not be swallowed one layer up.
catalog_unexpected_missing_bars_pairs() {
  # Status kept. An UNREADABLE control file used to arrive here as an
  # empty list, and an empty list reads as "nothing exempt" — silently
  # green over a file nobody could open.
  if ! CI_CUMBP_KNOWN=$(known_gap_pairs); then
    echo "ci-guards: known_gap_pairs: could not read the control file." >&2
    return 1
  fi
  CI_CUMBP_MISSING=$(catalog_missing_bars_pairs "$1") || return 1
  printf '%s\n' "$CI_CUMBP_MISSING" | while IFS= read -r CI_CUMBP_PAIR; do
    [ -n "$CI_CUMBP_PAIR" ] || continue
    printf '%s\n' "$CI_CUMBP_KNOWN" | grep -qxF "$CI_CUMBP_PAIR" && continue
    printf '%s\n' "$CI_CUMBP_PAIR"
  done
}

# Pairs on the known-gaps list that no longer describe a real gap. Two
# directions, both build failures — the half that keeps the list honest:
#
#   * the anchors have SINCE been authored (bars/<ROLE>.json now covers it)
#   * the pair no longer exists at all (roles.json dropped the competency
#     from the role, or dropped the role) — an exemption excusing a pair that
#     is not there is the same note-outliving-its-fact defect as the first
#     direction, just reached from the other side
#
# Direction 2 needs role_competency_pairs to succeed; when it does not, this
# function still reports every direction-1 hit it found (those do not depend
# on roles.json parsing at all) and returns non-zero at the end rather than
# silently skipping the second direction.
# A THIRD shape, caught by neither direction until this fix — verified
# independently and stated precisely so it cannot regress unnoticed: a pair
# naming a role that IS declared in roles.json but has NO bars/<ROLE>.json
# file at ALL (this was SRX's shape before bars-catalogue-completion Phase 6
# authored bars/SRX.json — kept as the reference example below, not a claim
# about SRX today). `catalog_missing_bars_pairs` skips such a role BY DESIGN
# (`[ -f ... ] || continue` — the pair-level gate is not this role's
# business, the role-level gate is); Direction 1 below requires the file to
# exist and so never runs; Direction 2 finds the pair legitimately declared
# in roles.json and so never fires either. Net effect before this fix: a
# line shaped like "SRX:PRS" would be accepted onto the per-pair list,
# produce NO error in either existing direction, and stay mute FOREVER —
# until the day the role's bars file was authored, at which point it would
# fire in a commit that has nothing to do with it. The file's own header
# already states the POLICY ("SRX's pairs stay under the role-level list,
# not here"); Direction 3 below is what enforces it mechanically instead of
# by hoping nobody adds one.
catalog_stale_competency_gap_exemptions() {
  CI_CSCGE_TREE="$1"
  CI_CSCGE_DECLARED=$(mktemp)
  # if/else, not `cmd` then `STATUS=$?` on the next line: under `set -e` the
  # shell aborts on the failing command and the status is never read, so the
  # entire could-not-read path becomes dead code. This function is called from
  # step (f) outside an `if` condition, where that abort is real. Same rule
  # json_canonical_equal follows and wrapper-ci.yml documents at its call sites.
  if role_competency_pairs "$CI_CSCGE_TREE" > "$CI_CSCGE_DECLARED" 2>/dev/null; then
    CI_CSCGE_STATUS=0
  else
    CI_CSCGE_STATUS=$?
  fi

  # Read to a variable FIRST. A pipeline reports its LAST command, so
  # `known_gap_pairs | while ...` returned the loop's status and the reader's
  # "could not read" was discarded — the loop simply ran zero times over
  # nothing and the caller read that as "no entries".
  if ! CI_CSCGE_LIST=$(known_gap_pairs); then
    echo "ci-guards: known_gap_pairs: could not read the control file." >&2
    return 1
  fi
  printf '%s\n' "$CI_CSCGE_LIST" | while IFS= read -r CI_CSCGE_PAIR; do
    [ -n "$CI_CSCGE_PAIR" ] || continue
    CI_CSCGE_ROLE=${CI_CSCGE_PAIR%%:*}
    CI_CSCGE_COMP=${CI_CSCGE_PAIR#*:}

    CI_CSCGE_PAIR_DECLARED=0
    if [ "$CI_CSCGE_STATUS" -eq 0 ] && grep -qxF "$CI_CSCGE_PAIR" "$CI_CSCGE_DECLARED"; then
      CI_CSCGE_PAIR_DECLARED=1
    fi

    if [ -f "$CI_CSCGE_TREE/bars/$CI_CSCGE_ROLE.json" ]; then
      # Direction 1 — anchored since the exemption was written.
      CI_CSCGE_COVERED=$(bars_competency_keys "$CI_CSCGE_TREE" "$CI_CSCGE_ROLE" 2>/dev/null)
      if printf '%s\n' "$CI_CSCGE_COVERED" | grep -qxF "$CI_CSCGE_COMP"; then
        printf '%s\n' "$CI_CSCGE_PAIR"
        continue
      fi
    elif [ "$CI_CSCGE_PAIR_DECLARED" -eq 1 ]; then
      # Direction 3 (the SRX shape) — declared in roles.json, but the role
      # has no bars file at all. Belongs on the role-level list instead.
      printf '%s\n' "$CI_CSCGE_PAIR"
      continue
    fi

    # Direction 2 — the pair itself no longer exists (wrong role entirely,
    # or the role exists but no longer assigns this competency).
    if [ "$CI_CSCGE_STATUS" -eq 0 ] && [ "$CI_CSCGE_PAIR_DECLARED" -eq 0 ]; then
      printf '%s\n' "$CI_CSCGE_PAIR"
    fi
  done

  rm -f "$CI_CSCGE_DECLARED"
  [ "$CI_CSCGE_STATUS" -eq 0 ]
}

# Distinguishes the THREE stale-exemption shapes for a single PAIR — same
# tree, same known-gaps entry — so a caller can print a diagnostic naming the
# SPECIFIC shape instead of one message trying to describe all three at
# once. Prints exactly one of:
#   "anchored"   — Direction 1: the anchors now exist
#   "role-level" — Direction 3: the role has no bars file at all; this
#                  exemption belongs on scripts/framework-known-gaps.txt
#   "orphaned"   — Direction 2: the pair no longer exists in roles.json,
#                  either because the role does not or because the role no
#                  longer assigns this competency
# Prints nothing when the pair is not actually stale — the caller should not
# have asked.
stale_competency_gap_exemption_reason() {
  CI_SCGER_TREE="$1"
  CI_SCGER_PAIR="$2"
  CI_SCGER_ROLE=${CI_SCGER_PAIR%%:*}
  CI_SCGER_COMP=${CI_SCGER_PAIR#*:}

  # Read roles.json ONCE, up front, and refuse to answer if it cannot be read.
  #
  # Both branches below used to run `role_competency_pairs ... 2>/dev/null |
  # grep -qxF`, where an unparseable roles.json is indistinguishable from "the
  # pair is not declared". The function then printed `orphaned` with total
  # confidence and step (d) told the operator to delete an exemption because
  # "roles.json no longer assigns that competency" — about a file that was
  # never parsed. An instruction to delete a CORRECT exemption, generated from
  # nothing. Its own sibling catalog_stale_competency_gap_exemptions already
  # captures the status explicitly; the two disagreed about the same fact.
  if ! CI_SCGER_PAIRS=$(role_competency_pairs "$CI_SCGER_TREE"); then
    echo "ci-guards: stale_competency_gap_exemption_reason: could not read role/competency pairs from $CI_SCGER_TREE." >&2
    return 2
  fi

  if [ -f "$CI_SCGER_TREE/bars/$CI_SCGER_ROLE.json" ]; then
    # Status kept, stderr kept: a malformed-but-present bars file used to yield
    # an empty coverage list, which reads as "not anchored" — silently.
    if ! CI_SCGER_COVERED=$(bars_competency_keys "$CI_SCGER_TREE" "$CI_SCGER_ROLE"); then
      echo "ci-guards: stale_competency_gap_exemption_reason: could not read $CI_SCGER_TREE/bars/$CI_SCGER_ROLE.json." >&2
      return 2
    fi
    if printf '%s\n' "$CI_SCGER_COVERED" | grep -qxF "$CI_SCGER_COMP"; then
      echo "anchored"
      return 0
    fi
    # The bars file exists and this competency is NOT anchored in it. That is
    # a LIVE gap, not a stale exemption — unless roles.json no longer declares
    # the pair at all, which is the orphaned shape. Printing "orphaned"
    # unconditionally here broke the contract three lines up ("prints nothing
    # when the pair is not actually stale") and would have told an operator to
    # delete an exemption that is doing its job.
    if printf '%s\n' "$CI_SCGER_PAIRS" | grep -qxF "$CI_SCGER_PAIR"; then
      return 1
    fi
    echo "orphaned"
    return 0
  fi

  if printf '%s\n' "$CI_SCGER_PAIRS" | grep -qxF "$CI_SCGER_PAIR"; then
    echo "role-level"
    return 0
  fi

  echo "orphaned"
}

# ---------------------------------------------------------------------------
# "Entries are grouped by role" — ci-pipeline spec's own reviewability
# requirement for the per-pair known-gaps file, previously true only by
# INSPECTION (no automated check anywhere). Makes it mechanical.
#
# Prints every role code that reappears NON-contiguously in
# CI_COMPETENCY_GAPS_FILE — i.e. a role's lines are interrupted by a
# DIFFERENT role's lines and then resume. Empty output means every role's
# entries are one unbroken block, which is what "roles are not interleaved"
# (the spec's own scenario) means. A role appearing only once is trivially
# grouped and never printed.
#
# Reads via known_gap_pairs, not the raw file — same parsing discipline
# (comments/blank lines dropped) as every other consumer of this file, so a
# comment line between two blocks of the SAME role does not itself count as
# "a different role interrupting it".
# ---------------------------------------------------------------------------
competency_gaps_role_order_violations() {
  CI_CGRO_FILE=$(mktemp)
  if ! known_gap_pairs > "$CI_CGRO_FILE"; then
    echo "ci-guards: competency_gaps_role_order_violations: could not read the competency-gaps control file." >&2
    rm -f "$CI_CGRO_FILE"
    return 1
  fi

  CI_CGRO_SEEN=""
  CI_CGRO_LAST=""
  while IFS= read -r CI_CGRO_PAIR; do
    [ -n "$CI_CGRO_PAIR" ] || continue
    CI_CGRO_ROLE=${CI_CGRO_PAIR%%:*}

    if [ "$CI_CGRO_ROLE" = "$CI_CGRO_LAST" ]; then
      continue
    fi

    case " $CI_CGRO_SEEN " in
      *" $CI_CGRO_ROLE "*) printf '%s\n' "$CI_CGRO_ROLE" ;;
    esac
    CI_CGRO_SEEN="$CI_CGRO_SEEN $CI_CGRO_ROLE"
    CI_CGRO_LAST="$CI_CGRO_ROLE"
  done < "$CI_CGRO_FILE"

  rm -f "$CI_CGRO_FILE"
}

# ---------------------------------------------------------------------------
# Partial IT-coverage control file (framework-catalog-it-translations,
# design D6). NEW, both-direction doctrine — same shape as
# scripts/framework-known-gaps.txt and scripts/framework-competency-gaps.txt,
# distinct from both (they answer "does a BARS file/pair exist at all",
# never "is a pair's translation complete") — see that file's own header.
#
# `catalog_locale_coverage` is the RAW FACT: for tree $1 and locale $2,
# prints `LOCALE:ROLE:COMP`, one per line, for every ANCHORED pair (declared
# in roles.json AND non-empty in its bars file — an unanchored pair is
# `competency_no_bars`'s business, not this guard's, mirroring
# `catalog_missing_bars_pairs`'s own scoping) whose 12 required strings (3
# indicators × {text/indicator, anchor_5, anchor_3, anchor_1}) do NOT all
# carry a non-empty value for that locale. 11 of 12 counts as 0 — same unit
# the scoring-engine's own per-competency hard-fail uses, and the same rule
# the seeder's `resolveOrRecordTranslationGap` applies to the DB-side gap.
#
# NOTE: this paragraph described the OLD behaviour and is corrected below.
# The function now HARD-FAILS on a bars file that exists but does not parse
# (see the inline comment in the script), because "no bars file" and "bars file
# corrupt" are different answers and the stale check downstream turned the
# second one into an instruction to delete correct exemptions. It still skips
# (silently) any role with no bars file at all — role-level absence is
# `catalog_missing_bars`'s business — and any role that fails to parse,
# per the "a guard that cannot read its subject must never pass it" rule;
# such a role's pairs are simply absent from the output, which the CALLER
# must not misread as "fully covered" (the same caution
# `catalog_missing_bars_pairs`'s own header states for its analogous case).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
CI_LOCALE_COVERAGE_SCRIPT='
  const tree = process.env.CI_TREE;
  const locale = process.env.CI_LOCALE;
  let roles;
  try {
    roles = JSON.parse(await Bun.file(`${tree}/roles.json`).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${tree}/roles.json: ${e.message}`);
    process.exit(1);
  }
  if (roles === null || typeof roles !== "object" || Array.isArray(roles)) {
    console.error(`ci-guards: ${tree}/roles.json must be a JSON OBJECT keyed by role code.`);
    process.exit(1);
  }

  const out = [];

  for (const role of Object.keys(roles)) {
    const comps = Array.isArray(roles[role]?.competencies) ? roles[role].competencies : [];
    // "No bars file" and "bars file present but unreadable" are DIFFERENT
    // answers and used to share one branch. The consequence was not
    // theoretical: catalog_stale_locale_gap_exemptions reports every listed
    // entry this function does not re-emit, so a corrupt bars/FLL.json made CI
    // print, for every tracked pair of that role, "is now fully translated,
    // delete the entry". An instruction to delete CORRECT exemptions,
    // generated from a file that was never parsed. A wrong diagnosis costs
    // more than a missing one.
    //
    // No apostrophes in this block on purpose: the whole script is a
    // single-quoted shell string, and one contraction here terminated it.
    const barsPath = `${tree}/bars/${role}.json`;
    const barsFile = Bun.file(barsPath);
    if (!(await barsFile.exists())) continue; // the role-level gate owns this case
    let bars;
    try {
      bars = JSON.parse(await barsFile.text());
    } catch (e) {
      console.error(`ci-guards: catalog_locale_coverage: ${barsPath} exists but could not be parsed: ${e.message}`);
      process.exit(1);
    }
    if (bars === null || typeof bars !== "object" || Array.isArray(bars)) {
      console.error(`ci-guards: catalog_locale_coverage: ${barsPath} is not a JSON object.`);
      process.exit(1);
    }

    for (const comp of comps) {
      const entries = bars[comp];
      if (!Array.isArray(entries) || entries.length === 0) continue; // unanchored — competency_no_bars business

      let complete = true;
      for (const entry of entries) {
        if (entry === null || typeof entry !== "object") { complete = false; break; }
        const values = [entry.indicator, entry.scale?.["5"], entry.scale?.["3"], entry.scale?.["1"]];
        for (const v of values) {
          const text = v && typeof v === "object" ? v[locale] : undefined;
          if (typeof text !== "string" || text.length === 0) { complete = false; break; }
        }
        if (!complete) break;
      }

      if (!complete) {
        out.push(`${locale}:${role}:${comp}`);
      }
    }
  }

  console.log(out.join("\n"));
'

catalog_locale_coverage() {
  CI_TREE="$1"
  CI_LOCALE="$2"
  export CI_TREE CI_LOCALE
  if [ ! -f "$CI_TREE/roles.json" ]; then
    echo "ci-guards: $CI_TREE/roles.json does not exist." >&2
    return 1
  fi
  bun --eval "$CI_LOCALE_COVERAGE_SCRIPT"
}

# CI_LOCALE_GAPS_FILE mirrors the override seam of CI_KNOWN_GAPS_FILE /
# CI_COMPETENCY_GAPS_FILE / CI_CROSSROLE_BASELINE_FILE, so the self-test can
# point these functions at a fixture list without touching the committed one.
CI_LOCALE_GAPS_FILE="${CI_LOCALE_GAPS_FILE:-scripts/framework-locale-gaps.txt}"

# The LOCALE:ROLE:COMP entries on the list, one per line. Same parsing
# discipline as every sibling control file: '#' to end of line is a
# comment, blank lines dropped, only the first whitespace field read.
known_locale_gap_pairs() {
  # ABSENT is a legitimate empty list; UNREADABLE is not. Both used to
  # return 0, which made every caller's "could not read the control file"
  # branch dead code: delete the file and the interleaving check reported
  # clean, exactly as before the guard that was added to stop it.
  if [ ! -f "$CI_LOCALE_GAPS_FILE" ]; then
    return 0
  fi
  if [ ! -r "$CI_LOCALE_GAPS_FILE" ]; then
    echo "ci-guards: $CI_LOCALE_GAPS_FILE exists but cannot be read." >&2
    return 1
  fi
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//' "$CI_LOCALE_GAPS_FILE" \
    | grep -v '^$' || true
}

# Direction 1: an incomplete, undeclared pair is a build failure — someone's
# translation is missing and nobody recorded it as a known, tracked gap.
# Propagates catalog_locale_coverage's read failure rather than absorbing it.
catalog_unexpected_locale_gaps() {
  CI_CULG_TREE="$1"
  CI_CULG_LOCALE="$2"
  # Status kept. An UNREADABLE control file used to arrive here as an
  # empty list, and an empty list reads as "nothing exempt" — silently
  # green over a file nobody could open.
  if ! CI_CULG_KNOWN=$(known_locale_gap_pairs); then
    echo "ci-guards: known_locale_gap_pairs: could not read the control file." >&2
    return 1
  fi
  CI_CULG_FOUND=$(catalog_locale_coverage "$CI_CULG_TREE" "$CI_CULG_LOCALE") || return 1
  printf '%s\n' "$CI_CULG_FOUND" | while IFS= read -r CI_CULG_PAIR; do
    [ -n "$CI_CULG_PAIR" ] || continue
    printf '%s\n' "$CI_CULG_KNOWN" | grep -qxF "$CI_CULG_PAIR" && continue
    printf '%s\n' "$CI_CULG_PAIR"
  done
}

# Direction 2: a listed exemption that is now fully translated, OR whose pair
# no longer exists at all (roles.json dropped it), is a stale note — the
# same "note outliving its fact" defect every sibling control file guards
# against. Both sub-cases collapse into ONE check here: `catalog_locale_
# coverage` only ever emits a currently-declared, currently-incomplete pair,
# so ANY listed entry it does NOT re-emit is stale, for either reason.
catalog_stale_locale_gap_exemptions() {
  CI_CSLG_TREE="$1"
  CI_CSLG_LOCALE="$2"
  CI_CSLG_FOUND=$(catalog_locale_coverage "$CI_CSLG_TREE" "$CI_CSLG_LOCALE") || return 1
  # Read to a variable FIRST. A pipeline reports its LAST command, so
  # `known_locale_gap_pairs | while ...` returned the loop's status and the reader's
  # "could not read" was discarded — the loop simply ran zero times over
  # nothing and the caller read that as "no entries".
  if ! CI_CSLG_LIST=$(known_locale_gap_pairs); then
    echo "ci-guards: known_locale_gap_pairs: could not read the control file." >&2
    return 1
  fi
  printf '%s\n' "$CI_CSLG_LIST" | while IFS= read -r CI_CSLG_PAIR; do
    [ -n "$CI_CSLG_PAIR" ] || continue
    CI_CSLG_PAIR_LOCALE=${CI_CSLG_PAIR%%:*}
    [ "$CI_CSLG_PAIR_LOCALE" = "$CI_CSLG_LOCALE" ] || continue
    printf '%s\n' "$CI_CSLG_FOUND" | grep -qxF "$CI_CSLG_PAIR" && continue
    printf '%s\n' "$CI_CSLG_PAIR"
  done
}

# Direction 3, the property unique to THIS control file (design D6): no role
# may ship half-translated. Per (locale, role), the number of that role's
# pairs LISTED in the gaps file must be exactly 0 (role fully translated) or
# the role's FULL declared pair count (role not yet started) — any count in
# between means some of the role's pairs are translated and some are not,
# which is exactly the "competency A composes, competency B 422s" partial
# state the whole-role rule exists to make impossible to ship silently.
# Prints `LOCALE:ROLE:LISTED/FULL` for every violating (locale, role).
locale_gaps_whole_role_violations() {
  CI_LGWR_TREE="$1"

  # Read the tree ONCE, up front, and refuse to continue if it cannot be read.
  #
  # This used to call `role_competency_pairs ... | grep -c` inside the loop with
  # `|| true`. On a malformed roles.json the pipeline printed 0, `|| true`
  # swallowed the status, FULL became 0 with LISTED non-zero, and the guard
  # reported `it:ICO:15/0` — so CI announced "no role may ship half-translated"
  # about a file it had never parsed. A wrong diagnosis is worse than a missing
  # one: it sends someone to fix the control file instead of the broken JSON.
  #
  # Reading before the loop also matters mechanically: the loop body runs in a
  # subshell behind a pipe, so a `return` inside it could never reach the
  # caller — which is why the workflow's `else` branch for this function was
  # unreachable, as its own comment admitted. Documenting a hole does not close
  # it.
  if ! CI_LGWR_PAIRS=$(role_competency_pairs "$CI_LGWR_TREE"); then
    echo "ci-guards: locale_gaps_whole_role_violations: could not read role/competency pairs from $CI_LGWR_TREE." >&2
    return 1
  fi
  CI_LGWR_FILE=$(mktemp)
  if ! known_locale_gap_pairs > "$CI_LGWR_FILE"; then
    echo "ci-guards: locale_gaps_whole_role_violations: could not read the locale-gaps control file." >&2
    rm -f "$CI_LGWR_FILE"
    return 1
  fi

  CI_LGWR_COMBOS=$(cut -d: -f1,2 "$CI_LGWR_FILE" | sort -u)
  printf '%s\n' "$CI_LGWR_COMBOS" | while IFS= read -r CI_LGWR_COMBO; do
    [ -n "$CI_LGWR_COMBO" ] || continue
    CI_LGWR_LOCALE=${CI_LGWR_COMBO%%:*}
    CI_LGWR_ROLE=${CI_LGWR_COMBO#*:}
    # grep -c ALWAYS prints a count (0 on no match) but EXITS 1 on zero
    # matches — `|| true` keeps that from aborting a caller running under
    # `set -e`, the exact trap this repo's own guards keep tripping on.
    CI_LGWR_LISTED=$(grep -c "^${CI_LGWR_LOCALE}:${CI_LGWR_ROLE}:" "$CI_LGWR_FILE" || true)
    CI_LGWR_FULL=$(printf '%s\n' "$CI_LGWR_PAIRS" | grep -c "^${CI_LGWR_ROLE}:" || true)
    if [ "$CI_LGWR_LISTED" -ne 0 ] && [ "$CI_LGWR_LISTED" -ne "$CI_LGWR_FULL" ]; then
      printf '%s:%s:%s/%s\n' "$CI_LGWR_LOCALE" "$CI_LGWR_ROLE" "$CI_LGWR_LISTED" "$CI_LGWR_FULL"
    fi
  done

  rm -f "$CI_LGWR_FILE"
}

# Role-order grouping check for framework-locale-gaps.txt — sibling of
# competency_gaps_role_order_violations above, same reviewability property
# ("a role's entries are not interleaved with another role's"), read via
# known_locale_gap_pairs's SAME parsing discipline. The role is field 2
# (LOCALE:ROLE:COMP), not field 1 — the only structural difference from its
# sibling.
locale_gaps_role_order_violations() {
  CI_LGRO_FILE=$(mktemp)
  # Guarded for the same reason as its sibling above: an unreadable control
  # file produced an empty list, and an empty list reads as "no interleaving"
  # — a pass generated from nothing.
  if ! known_locale_gap_pairs > "$CI_LGRO_FILE"; then
    echo "ci-guards: locale_gaps_role_order_violations: could not read the locale-gaps control file." >&2
    rm -f "$CI_LGRO_FILE"
    return 1
  fi

  CI_LGRO_SEEN=""
  CI_LGRO_LAST=""
  while IFS= read -r CI_LGRO_ENTRY; do
    [ -n "$CI_LGRO_ENTRY" ] || continue
    CI_LGRO_ROLE=$(printf '%s' "$CI_LGRO_ENTRY" | cut -d: -f2)

    if [ "$CI_LGRO_ROLE" = "$CI_LGRO_LAST" ]; then
      continue
    fi

    case " $CI_LGRO_SEEN " in
      *" $CI_LGRO_ROLE "*) printf '%s\n' "$CI_LGRO_ROLE" ;;
    esac
    CI_LGRO_SEEN="$CI_LGRO_SEEN $CI_LGRO_ROLE"
    CI_LGRO_LAST="$CI_LGRO_ROLE"
  done < "$CI_LGRO_FILE"

  rm -f "$CI_LGRO_FILE"
}

# ---------------------------------------------------------------------------
# roles.json / competencies.json locale-map shape (framework-catalog-it-
# translations design D2, row 8). NEW. 50 strings (5 roles × {name,
# responsibilities} + 20 competencies × {name, definition}) that NOTHING
# ELSE reads: `role_keys`/`role_competency_pairs` read only `code` and
# `competencies`, never `name`/`responsibilities` (see D2 row 2's own "never
# read" note); `catalog_malformed_bars_entries` reads bars files only.
# Without this guard, these 50 strings would carry the new locale dimension
# under ZERO content guards — Decision 1's failure mode.
#
# Prints `COMPETENCIES:<code>:<field>:<reason>` or `ROLES:<code>:<field>:
# <reason>`, one per line — reasons drawn from the SAME vocabulary
# `catalog_malformed_bars_entries` uses (not-a-locale-map, missing-en,
# unknown-locale-<x>, blank-<locale>), so an operator reading either guard's
# output already knows what the reason means.
#
# roles.json's `responsibilities` is the ONE field allowed a blank `en`
# (mirrors the seeder's own `allowBlankEn` — a role not yet authored is a
# real, pre-existing, non-malformed state, tracked by the SEPARATE
# `missing_role_meta` gap, not this guard's business). Every other field
# (role `name`, competency `name`/`definition`) requires a non-blank `en`.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
CI_META_LOCALE_SHAPE_SCRIPT='
  const tree = process.env.CI_TREE;
  const knownLocales = (process.env.CI_LOCALES || "en").split(" ").filter(Boolean);
  const isBlank = (s) => typeof s !== "string" || s.length === 0;
  const hasEdgeWhitespace = (s) => typeof s === "string" && s !== s.trim();

  const localeMapReason = (value, allowBlankEn) => {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      return "not-a-locale-map";
    }
    if (!allowBlankEn && (isBlank(value.en) || hasEdgeWhitespace(value.en))) {
      return "missing-en";
    }
    if (allowBlankEn && (typeof value.en !== "string")) {
      return "missing-en";
    }
    for (const key of Object.keys(value)) {
      if (!knownLocales.includes(key)) return `unknown-locale-${key}`;
    }
    for (const key of Object.keys(value)) {
      if (key === "en" && allowBlankEn && value[key] === "") continue;
      if (isBlank(value[key]) || hasEdgeWhitespace(value[key])) return `blank-${key}`;
    }
    return null;
  };

  const out = [];

  let competencies;
  try {
    competencies = JSON.parse(await Bun.file(`${tree}/competencies.json`).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${tree}/competencies.json: ${e.message}`);
    process.exit(1);
  }
  if (competencies === null || typeof competencies !== "object" || Array.isArray(competencies)) {
    console.error(`ci-guards: ${tree}/competencies.json must be a JSON OBJECT keyed by competency code.`);
    process.exit(1);
  }
  for (const code of Object.keys(competencies)) {
    const entry = competencies[code];
    const nameReason = localeMapReason(entry?.name, false);
    if (nameReason) out.push(`COMPETENCIES:${code}:name:${nameReason}`);
    const defReason = localeMapReason(entry?.definition, false);
    if (defReason) out.push(`COMPETENCIES:${code}:definition:${defReason}`);
  }

  let roles;
  try {
    roles = JSON.parse(await Bun.file(`${tree}/roles.json`).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${tree}/roles.json: ${e.message}`);
    process.exit(1);
  }
  if (roles === null || typeof roles !== "object" || Array.isArray(roles)) {
    console.error(`ci-guards: ${tree}/roles.json must be a JSON OBJECT keyed by role code.`);
    process.exit(1);
  }
  for (const code of Object.keys(roles)) {
    const entry = roles[code];
    const nameReason = localeMapReason(entry?.name, false);
    if (nameReason) out.push(`ROLES:${code}:name:${nameReason}`);
    const respReason = localeMapReason(entry?.responsibilities, true);
    if (respReason) out.push(`ROLES:${code}:responsibilities:${respReason}`);
  }

  console.log(out.join("\n"));
'

catalog_meta_locale_shape() {
  CI_TREE="$1"
  export CI_TREE
  if [ ! -f "$CI_TREE/competencies.json" ] || [ ! -f "$CI_TREE/roles.json" ]; then
    echo "ci-guards: $CI_TREE/competencies.json or roles.json does not exist." >&2
    return 1
  fi
  bun --eval "$CI_META_LOCALE_SHAPE_SCRIPT"
}

# ---------------------------------------------------------------------------
# roles.json / competencies.json locale COMPLETENESS — the gap the shape
# guard above deliberately does not close.
#
# `catalog_meta_locale_shape` asks "is every locale value THAT IS PRESENT
# well-formed" — `en` is mandatory there, every OTHER key is optional, so
# `{"en": "..."}` alone passes it. That is exactly the shape 50 strings (20
# competencies x {name, definition}, 5 roles x {name, responsibilities})
# shipped in for an unmeasured period: authored in `en` only, never
# translated, and invisible to every gate that existed. This function asks
# the other question — "is every locale the catalogue CLAIMS to support
# actually here" — which is a different assertion (mandatory-vs-optional
# key), not a stricter reading of the same one.
#
# It closes the gap `scripts/framework-locale-gaps.txt` structurally cannot:
# that file, and the four guards built on `known_locale_gap_pairs`, track
# role x competency BARS PAIRS only (`role_competency_pairs`'s own
# ROLE:COMP vocabulary) and have nothing to say about a `roles.json` or
# `competencies.json` FIELD. Nor is it the same fact as the runtime's global
# `missing_translation` FrameworkGap, which is scored over the same BARS
# pairs and reported "it locale: all 83 of 83 role x competency pairs
# translated" while these 50 strings sat untranslated in production — true
# about its own domain, silent about this one.
#
# WHICH LOCALES ARE EXPECTED: read from `CI_LOCALES`, the SAME env var step
# (d) already exports once ("en it") for `catalog_meta_locale_shape` and the
# cross-locale/partial-coverage guards beside it — not re-derived here.
# Deriving "expected" from "present" is circular and would have passed
# exactly the bug this guard exists to catch: every one of the 50 strings
# HAD an en key, so a completeness check that inferred its locale set from
# whatever keys happened to exist would infer {"en"} for every one of them
# and report the catalogue complete. `CI_LOCALES` is a fact asserted by a
# human once, in one place, ahead of content landing (see that export's own
# comment in step (d)) precisely so no guard downstream of it can fall into
# that trap.
#
# NO EXEMPTION SEAM, unlike the three sibling control files this guard's own
# comment block up top cites (framework-known-gaps.txt, framework-
# competency-gaps.txt, framework-crossrole-baseline.txt) and unlike
# framework-locale-gaps.txt beside it. Those all exist because their subject
# is authored INCREMENTALLY across many files and many PRs — 83 role x
# competency pairs, 996 BARS anchors, cross-role duplicates accumulated over
# several completion phases — so a legitimate "not there yet, tracked
# on purpose" state exists and needs a place to live without turning CI
# permanently red. `competencies.json`/`roles.json` metadata is the opposite
# shape: 50 leaf strings living in exactly TWO files, added only when a
# competency or role is added at all (a rare event), and cheap enough for
# one author to translate in the SAME PR that introduces the English. There
# is no legitimate half-landed state here to give a name to — either the
# 50 strings ship translated or the PR that adds them is not done — so an
# exemption file would not relieve real authoring pressure the way its
# siblings do; it would just be a second, quieter way to reintroduce this
# exact incident, opt-in, without even a build failure to notice it by.
#
# The ONE recognized incomplete state is `roles.json`'s `responsibilities`
# with a deliberately blank `en` — and it already has a home. That is the
# seeder's own `allowBlankEn` sentinel for "this role has not been authored
# at all yet" (FrameworkGap kind=`n`, `api/database/seeders/
# FrameworkCatalogSeeder.php`), which `catalog_meta_locale_shape` already
# encodes and this guard MUST agree with rather than re-litigate: a role
# with no responsibilities in ANY locale is not a translation gap, it is a
# role that does not exist yet, and asking "where is its `it`" is the wrong
# question. Skipped entirely, the same as the shape guard skips it.
#
# Prints `COMPETENCIES:<code>:<field>:missing-<locale>` or
# `ROLES:<code>:<field>:missing-<locale>`, one per line, for every
# translatable field lacking a non-empty value for a locale `CI_LOCALES`
# expects. Empty output means the catalogue is fully translated.
#
# FAILS CLOSED (nonzero exit, nothing useful on stdout — "the guard failed
# to run", never "nothing to report", the same contract every reader in
# this file obeys) on: a missing file, unparseable JSON, either top-level
# document not a JSON object keyed by code, a translatable field that is
# present but not itself a locale-map object, or an `en` that is absent (not
# a string at all) on a field that requires one. This is independent of
# `catalog_meta_locale_shape` — it is NOT assumed to have already run — so a
# malformed field is never read as "complete" by a caller that invokes this
# guard on its own. The one field allowed a blank (not absent) `en` is
# `responsibilities`, per the sentinel above; every other field requires a
# non-blank `en` before completeness is even asked.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
# Single-quoted for the same reason as CI_META_LOCALE_SHAPE_SCRIPT above:
# this is a JavaScript template literal that must reach bun untouched.
CI_META_LOCALE_COMPLETENESS_SCRIPT='
  const tree = process.env.CI_TREE;
  const knownLocales = (process.env.CI_LOCALES || "en").split(" ").filter(Boolean);
  const isBlank = (s) => typeof s !== "string" || s.length === 0;

  // Independent of catalog_meta_locale_shape by design (see the comment
  // above this script): fails closed on the same two shapes that guard names
  // ("not-a-locale-map", "missing-en"), so a caller that runs this guard
  // alone never reads a malformed field as complete.
  const shapeOk = (value, allowBlankEn) => {
    if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
    if (allowBlankEn) return typeof value.en === "string";
    return !isBlank(value.en);
  };

  const out = [];

  const checkField = (entry, code, field, allowBlankEn, prefix) => {
    const value = entry ? entry[field] : undefined;
    if (!shapeOk(value, allowBlankEn)) {
      console.error(`ci-guards: ${tree} ${prefix}:${code}:${field} is not a well-formed locale map (not an object, or its en is absent) -- see catalog_meta_locale_shape.`);
      process.exit(1);
    }
    // The documented sentinel: a role whose responsibilities.en is itself
    // blank has not been authored at all yet (FrameworkGap kind=n). No
    // locale is expected for it, Italian or otherwise, until en exists.
    if (allowBlankEn && value.en === "") return;
    for (const locale of knownLocales) {
      if (isBlank(value[locale])) {
        out.push(`${prefix}:${code}:${field}:missing-${locale}`);
      }
    }
  };

  let competencies;
  try {
    competencies = JSON.parse(await Bun.file(`${tree}/competencies.json`).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${tree}/competencies.json: ${e.message}`);
    process.exit(1);
  }
  if (competencies === null || typeof competencies !== "object" || Array.isArray(competencies)) {
    console.error(`ci-guards: ${tree}/competencies.json must be a JSON OBJECT keyed by competency code.`);
    process.exit(1);
  }
  for (const code of Object.keys(competencies)) {
    checkField(competencies[code], code, "name", false, "COMPETENCIES");
    checkField(competencies[code], code, "definition", false, "COMPETENCIES");
  }

  let roles;
  try {
    roles = JSON.parse(await Bun.file(`${tree}/roles.json`).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${tree}/roles.json: ${e.message}`);
    process.exit(1);
  }
  if (roles === null || typeof roles !== "object" || Array.isArray(roles)) {
    console.error(`ci-guards: ${tree}/roles.json must be a JSON OBJECT keyed by role code.`);
    process.exit(1);
  }
  for (const code of Object.keys(roles)) {
    checkField(roles[code], code, "name", false, "ROLES");
    checkField(roles[code], code, "responsibilities", true, "ROLES");
  }

  console.log(out.join("\n"));
'

catalog_meta_locale_completeness() {
  CI_TREE="$1"
  export CI_TREE
  if [ ! -f "$CI_TREE/competencies.json" ] || [ ! -f "$CI_TREE/roles.json" ]; then
    echo "ci-guards: $CI_TREE/competencies.json or roles.json does not exist." >&2
    return 1
  fi
  bun --eval "$CI_META_LOCALE_COMPLETENESS_SCRIPT"
}

# ---------------------------------------------------------------------------
# Shape and completeness of an ANCHORED pair (bars-catalogue-completion).
#
# `bars_competency_keys` answers "is this competency COVERED at all" with a
# single test — `length > 0` — which a one-indicator stub with empty anchor
# text satisfies. It is the right question for the role/pair coverage gates
# above, and the wrong one for whether what covers a pair is actually a
# complete, non-degenerate anchor set. This is the question those gates never
# asked.
#
# Prints ROLE:COMP:REASON, one per line, for every competency key in
# `<tree>/bars/<ROLE>.json` whose entries do not have EXACTLY:
#   * 3 indicator objects (an EMPTY array is a stub, not malformed — that is
#     `bars_competency_keys`'s uncovered case, not this guard's business, so
#     `[]` is skipped rather than flagged)
#   * each with an `indicator` that is a valid LOCALE-MAP (see below)
#   * a `scale` object with EXACTLY the keys "5", "3", "1" — no more, no
#     fewer (a missing level, or an extra stray key, both fail)
#   * every one of those three scale values a valid LOCALE-MAP
#
# Locale-map shape (framework-catalog-it-translations, design D1): every
# translatable leaf is `{"en": "...", "it": "..."}`, never a bare string.
# REASON for a locale-map violation is one of:
#   not-a-locale-map    — the value is not an object (e.g. still a bare
#                         string — the pre-migration shape; a guard that
#                         has not been updated for the new shape MUST stop
#                         reading here, not silently pass it)
#   missing-en           — no `en` key, or `en` is blank/whitespace-only
#   unknown-locale-<x>   — a key outside the known-locale set (CI_LOCALES)
#   blank-<locale>       — a present locale's value is blank or has
#                          leading/trailing whitespace (folds in the
#                          pre-locale `hasEdgeWhitespace` check)
# The FIRST violation found for an entry is reported — same "stop at the
# first defect" discipline the pre-locale version used for `ok=false; break`.
#
# Empty output means the file's anchored competencies are all shape-complete.
# Fails closed (non-zero, nothing useful on stdout) when the file is missing,
# unparseable, or not a JSON object — the same rule every other reader in
# this file obeys.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
CI_MALFORMED_BARS_SCRIPT='
  const path = process.env.CI_BARS_FILE;
  const role = process.env.CI_MALFORMED_ROLE;
  const knownLocales = (process.env.CI_LOCALES || "en").split(" ").filter(Boolean);
  let bars;
  try {
    bars = JSON.parse(await Bun.file(path).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${path}: ${e.message}`);
    process.exit(1);
  }
  if (bars === null || typeof bars !== "object" || Array.isArray(bars)) {
    const got = Array.isArray(bars) ? "an array" : bars === null ? "null" : typeof bars;
    console.error(`ci-guards: ${path} must be a JSON OBJECT keyed by competency code, got ${got}.`);
    process.exit(1);
  }
  const isBlank = (s) => typeof s !== "string" || s.length === 0;
  const hasEdgeWhitespace = (s) => typeof s === "string" && s !== s.trim();
  // Returns a reason string ("not-a-locale-map", "missing-en",
  // "unknown-locale-<x>", "blank-<locale>") or null when the value is a
  // well-formed locale map.
  const localeMapReason = (value) => {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      return "not-a-locale-map";
    }
    if (isBlank(value.en) || hasEdgeWhitespace(value.en)) {
      return "missing-en";
    }
    for (const key of Object.keys(value)) {
      if (!knownLocales.includes(key)) {
        return `unknown-locale-${key}`;
      }
    }
    for (const key of Object.keys(value)) {
      if (isBlank(value[key]) || hasEdgeWhitespace(value[key])) {
        return `blank-${key}`;
      }
    }
    return null;
  };
  const out = [];
  for (const comp of Object.keys(bars)) {
    const entries = bars[comp];
    if (!Array.isArray(entries)) {
      out.push(`${role}:${comp}:not-an-array`);
      continue;
    }
    if (entries.length === 0) {
      continue;
    }
    // 3 is RATIFIED, not assumed: openspec/specs/framework-catalog/spec.md
    // "Every role\u00d7competency pair declared in roles.json MUST have exactly 3
    // indicators". That is why this guard has no exemption seam while its
    // siblings do — an exemption seam here would let a pair ship with two
    // indicators, which the scoring engine has no defined behaviour for.
    // Changing the count is an SDD question, not a CI-config one.
    if (entries.length !== 3) {
      out.push(`${role}:${comp}:count-${entries.length}`);
      continue;
    }
    let reason = null;
    for (const entry of entries) {
      if (entry === null || typeof entry !== "object") { reason = "malformed-entry"; break; }
      reason = localeMapReason(entry.indicator);
      if (reason) break;
      const scale = entry.scale;
      if (scale === null || typeof scale !== "object" || Array.isArray(scale)) { reason = "malformed-entry"; break; }
      if (Object.keys(scale).sort().join(",") !== "1,3,5") { reason = "malformed-entry"; break; }
      reason = localeMapReason(scale["5"]);
      if (reason) break;
      reason = localeMapReason(scale["3"]);
      if (reason) break;
      reason = localeMapReason(scale["1"]);
      if (reason) break;
    }
    if (reason) {
      out.push(`${role}:${comp}:${reason}`);
    }
  }
  console.log(out.join("\n"));
'

catalog_malformed_bars_entries() {
  CI_BARS_FILE="$1/bars/$2.json"
  CI_MALFORMED_ROLE="$2"
  export CI_BARS_FILE CI_MALFORMED_ROLE
  if [ ! -f "$CI_BARS_FILE" ]; then
    echo "ci-guards: $CI_BARS_FILE does not exist." >&2
    return 1
  fi
  bun --eval "$CI_MALFORMED_BARS_SCRIPT"
}

# ---------------------------------------------------------------------------
# Cross-role anchor identity (bars-catalogue-completion).
#
# "FLL's PRS is MLL's PRS with different words" is a comparison between roles
# FOR THE SAME COMPETENCY — invisible to every guard above, which each read
# one role's file in isolation. This one reads every `bars/*.json` file in a
# tree together and asks, per competency, whether any `indicator` or anchor
# (`scale.5`/`scale.3`/`scale.1`) STRING is byte-identical across two or more
# roles.
#
# Prints `ROLE_A:ROLE_B:COMP:LOCALE:FIELD`, one per line, for every such
# duplicate — `ROLE_A`/`ROLE_B` alphabetically ordered so the same real-world
# duplicate always prints the same line regardless of directory read order,
# `LOCALE` is one of CI_LOCALES (e.g. `en`, `it`), and `FIELD` is one of
# `indicator`, `anchor_5`, `anchor_3`, `anchor_1`. Deliberately NOT a
# `<file>:<line>` reference: line numbers shift every time an earlier
# competency block grows, which every future content PR does, and a baseline
# keyed on them would drift out from under itself. The role/competency/
# locale/field tuple is what stays stable while indicators pile up around it.
#
# Locale-map shape (framework-catalog-it-translations design D1): each of
# `indicator`/`anchor_5`/`anchor_3`/`anchor_1` is `{"en": "...", "it": "..."}`.
# This is the SECOND guard design D1 names as "the identical `continue`" the
# word-count guard had — the pre-locale version did
# `if (typeof val !== "string" || val.length === 0) continue`, which under
# the new shape examines the locale-map OBJECT and silently skips every
# value, forever. A non-locale-map value here is now a hard `process.exit(1)`
# (the SAME "guard that would go silently blind" defect, fixed the SAME way
# as the word-count guard); a locale key simply ABSENT from the map is
# skipped (not yet authored — legitimate); a PRESENT value that is not a
# string is also a hard failure.
#
# Compared ACROSS roles only — never within one role's own file — matching
# the spec's own wording ("identical across roles"). A duplicate only within
# a single role's array is a different defect this guard does not claim.
#
# Fails closed (non-zero, nothing useful on stdout) when the bars/ directory
# cannot be listed, any file in it is missing, unparseable, or not a JSON
# object keyed by competency code, or any translatable value is not a valid
# locale-map object.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
CI_CROSSROLE_SCRIPT='
  import { readdirSync } from "node:fs";

  const tree = process.env.CI_TREE;
  const barsDir = `${tree}/bars`;
  const locales = (process.env.CI_LOCALES || "en").split(" ").filter(Boolean);

  let files;
  try {
    files = readdirSync(barsDir).filter((f) => f.endsWith(".json")).sort();
  } catch (e) {
    console.error(`ci-guards: cannot read ${barsDir}: ${e.message}`);
    process.exit(1);
  }

  const roles = files.map((f) => f.replace(/\.json$/, ""));
  const perRole = {};

  for (const role of roles) {
    let bars;
    try {
      bars = JSON.parse(await Bun.file(`${barsDir}/${role}.json`).text());
    } catch (e) {
      console.error(`ci-guards: cannot read or parse ${barsDir}/${role}.json: ${e.message}`);
      process.exit(1);
    }
    if (bars === null || typeof bars !== "object" || Array.isArray(bars)) {
      const got = Array.isArray(bars) ? "an array" : bars === null ? "null" : typeof bars;
      console.error(`ci-guards: ${barsDir}/${role}.json must be a JSON OBJECT keyed by competency code, got ${got}.`);
      process.exit(1);
    }
    perRole[role] = bars;
  }

  const FIELDS = ["indicator", "anchor_5", "anchor_3", "anchor_1"];
  // competency -> field -> locale -> string -> Set(roles that use it)
  const index = {};

  for (const role of roles) {
    const bars = perRole[role];
    for (const comp of Object.keys(bars)) {
      const entries = bars[comp];
      if (!Array.isArray(entries)) continue;
      for (const entry of entries) {
        if (entry === null || typeof entry !== "object") continue;
        const localeMaps = {
          indicator: entry.indicator,
          anchor_5: entry.scale && entry.scale["5"],
          anchor_3: entry.scale && entry.scale["3"],
          anchor_1: entry.scale && entry.scale["1"],
        };
        for (const field of FIELDS) {
          const map = localeMaps[field];
          if (map === undefined) continue;
          if (map === null || typeof map !== "object" || Array.isArray(map)) {
            console.error(`ci-guards: ${barsDir}/${role}.json ${comp} ${field} is not a locale-map object (got ${typeof map}); expected {"en":...,"it":...}.`);
            process.exit(1);
          }
          for (const locale of locales) {
            if (!(locale in map)) continue; // not yet authored for this locale
            const val = map[locale];
            if (typeof val !== "string") {
              console.error(`ci-guards: ${barsDir}/${role}.json ${comp} ${field}.${locale} is not a string (got ${typeof val}).`);
              process.exit(1);
            }
            if (val.length === 0) continue;
            index[comp] ??= {};
            index[comp][field] ??= {};
            index[comp][field][locale] ??= {};
            index[comp][field][locale][val] ??= new Set();
            index[comp][field][locale][val].add(role);
          }
        }
      }
    }
  }

  const dupPairs = new Set();
  for (const comp of Object.keys(index)) {
    for (const field of Object.keys(index[comp])) {
      for (const locale of Object.keys(index[comp][field])) {
        for (const val of Object.keys(index[comp][field][locale])) {
          const roleSet = [...index[comp][field][locale][val]].sort();
          if (roleSet.length < 2) continue;
          for (let i = 0; i < roleSet.length; i++) {
            for (let j = i + 1; j < roleSet.length; j++) {
              dupPairs.add(`${roleSet[i]}:${roleSet[j]}:${comp}:${locale}:${field}`);
            }
          }
        }
      }
    }
  }

  console.log([...dupPairs].sort().join("\n"));
'

catalog_crossrole_duplicates() {
  CI_TREE="$1"
  export CI_TREE
  if [ ! -d "$CI_TREE/bars" ]; then
    echo "ci-guards: $CI_TREE/bars does not exist." >&2
    return 1
  fi
  bun --eval "$CI_CROSSROLE_SCRIPT"
}

# The committed baseline of cross-role duplicates that predate this guard —
# scripts/framework-crossrole-baseline.txt, generated (never hand-typed) by
# running catalog_crossrole_duplicates against the catalogue BEFORE any of
# the 44 new pairs landed. Retro-review of the 39 pre-existing pairs is out
# of scope for bars-catalogue-completion, so these two are recorded rather
# than fixed, with the SAME both-direction doctrine as
# scripts/framework-known-gaps.txt and scripts/framework-competency-gaps.txt:
# an entry whose duplicate is gone is as much a build failure as a duplicate
# that is not on the list. New pairs may add ZERO entries to this file.
#
# CI_CROSSROLE_BASELINE_FILE mirrors the override seam of
# CI_KNOWN_GAPS_FILE/CI_COMPETENCY_GAPS_FILE so the self-test can point these
# functions at a fixture list without touching the committed one.
CI_CROSSROLE_BASELINE_FILE="${CI_CROSSROLE_BASELINE_FILE:-scripts/framework-crossrole-baseline.txt}"

# The baseline entries, one per line. Same parsing discipline as
# known_gap_roles/known_gap_pairs: '#' to end of line is a comment, blank
# lines dropped, only the first whitespace-delimited field is read.
known_crossrole_baseline_entries() {
  # ABSENT is a legitimate empty list; UNREADABLE is not. Both used to
  # return 0, which made every caller's "could not read the control file"
  # branch dead code: delete the file and the interleaving check reported
  # clean, exactly as before the guard that was added to stop it.
  if [ ! -f "$CI_CROSSROLE_BASELINE_FILE" ]; then
    return 0
  fi
  if [ ! -r "$CI_CROSSROLE_BASELINE_FILE" ]; then
    echo "ci-guards: $CI_CROSSROLE_BASELINE_FILE exists but cannot be read." >&2
    return 1
  fi
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//' "$CI_CROSSROLE_BASELINE_FILE" \
    | grep -v '^$' || true
}

# Cross-role duplicates found in <tree> that are NOT on the committed
# baseline. Any output is a build failure: a new pair introduced the same
# reworded-copy defect the scope-shift table and this guard both exist to
# catch, and the baseline is closed to new entries by design.
#
# Propagates catalog_crossrole_duplicates's failure rather than absorbing it
# — the same "a guard that cannot read its subject must never pass it" rule
# every other function in this file obeys.
catalog_unexpected_crossrole_duplicates() {
  # Status kept. An UNREADABLE control file used to arrive here as an
  # empty list, and an empty list reads as "nothing exempt" — silently
  # green over a file nobody could open.
  if ! CI_CUCD_KNOWN=$(known_crossrole_baseline_entries); then
    echo "ci-guards: known_crossrole_baseline_entries: could not read the control file." >&2
    return 1
  fi
  CI_CUCD_FOUND=$(catalog_crossrole_duplicates "$1") || return 1
  printf '%s\n' "$CI_CUCD_FOUND" | while IFS= read -r CI_CUCD_ENTRY; do
    [ -n "$CI_CUCD_ENTRY" ] || continue
    printf '%s\n' "$CI_CUCD_KNOWN" | grep -qxF "$CI_CUCD_ENTRY" && continue
    printf '%s\n' "$CI_CUCD_ENTRY"
  done
}

# Baseline entries that no longer correspond to a real duplicate in <tree> —
# the half that keeps the baseline honest, the same shape as
# catalog_stale_gap_exemptions/catalog_stale_competency_gap_exemptions. Any
# output is a build failure: a baseline entry outliving the duplicate it
# describes is the identical note-outliving-its-fact defect those two files
# exist to prevent, applied to this third control file.
catalog_stale_crossrole_baseline_entries() {
  CI_SCBE_FOUND=$(catalog_crossrole_duplicates "$1") || return 1
  # Read to a variable FIRST. A pipeline reports its LAST command, so
  # `known_crossrole_baseline_entries | while ...` returned the loop's status and the reader's
  # "could not read" was discarded — the loop simply ran zero times over
  # nothing and the caller read that as "no entries".
  if ! CI_SCBE_LIST=$(known_crossrole_baseline_entries); then
    echo "ci-guards: known_crossrole_baseline_entries: could not read the control file." >&2
    return 1
  fi
  printf '%s\n' "$CI_SCBE_LIST" | while IFS= read -r CI_SCBE_ENTRY; do
    [ -n "$CI_SCBE_ENTRY" ] || continue
    printf '%s\n' "$CI_SCBE_FOUND" | grep -qxF "$CI_SCBE_ENTRY" && continue
    printf '%s\n' "$CI_SCBE_ENTRY"
  done
}

# ---------------------------------------------------------------------------
# Cross-locale duplicate divergence (framework-catalog-it-translations,
# design D2a). NEW, BLOCKING.
#
# The mechanical fidelity check design D2a argues actually exists, for one
# narrow class: whether a translator SILENTLY IMPROVED or FLATTENED the
# English while translating (Constraint 1's most likely violation, and the
# one no other mechanical check catches — see the change proposal's own
# admission that "no mechanical check can distinguish a faithful translation
# from an improved one", true in general, false for exactly this class).
#
# For every (roleA, roleB, competency, field) pair where the ENGLISH value is
# byte-identical across the two roles (a cross-role duplicate, same shape
# `catalog_crossrole_duplicates` already detects for `en`): the ITALIAN
# value at that SAME (role, competency, field) position — once authored for
# BOTH roles — MUST ALSO be identical. If it diverges, the translator
# differentiated Italian where English does not, i.e. improved (or altered)
# the source during "translation".
#
# The MIRROR direction is checked too: for every (roleA, roleB, competency,
# field) where the ITALIAN value is byte-identical across two roles, the
# ENGLISH value at that position MUST ALSO be identical. If English differs
# there, the translator FLATTENED a real English distinction into the same
# Italian wording — the opposite failure, equally a Constraint-1 violation.
#
# Both directions are SKIPPED (not reported) for any (role, comp, field)
# position where Italian is not yet authored for BOTH roles being compared —
# a real translation gap is `catalog_locale_coverage`'s question, not this
# guard's; this guard only fires once there is something to compare.
#
# Prints `ROLE_A:ROLE_B:COMP:FIELD:diverges-though-en-identical` or
# `ROLE_A:ROLE_B:COMP:FIELD:converges-though-en-differs`, one per line.
# Empty output means every IT value that exists agrees with its EN
# counterpart's cross-role identity/distinctness. Fails closed (non-zero,
# nothing useful on stdout) on the same read/shape failures
# `catalog_crossrole_duplicates` fails closed on.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
CI_CROSSLOCALE_DIVERGENCE_SCRIPT='
  import { readdirSync } from "node:fs";

  const tree = process.env.CI_TREE;
  const barsDir = `${tree}/bars`;

  let files;
  try {
    files = readdirSync(barsDir).filter((f) => f.endsWith(".json")).sort();
  } catch (e) {
    console.error(`ci-guards: cannot read ${barsDir}: ${e.message}`);
    process.exit(1);
  }

  const roles = files.map((f) => f.replace(/\.json$/, ""));
  const FIELDS = ["indicator", "anchor_5", "anchor_3", "anchor_1"];
  // comp -> field -> role -> { en: string, it: string|undefined }[] (one per entry/position)
  const perPosition = {};

  for (const role of roles) {
    let bars;
    try {
      bars = JSON.parse(await Bun.file(`${barsDir}/${role}.json`).text());
    } catch (e) {
      console.error(`ci-guards: cannot read or parse ${barsDir}/${role}.json: ${e.message}`);
      process.exit(1);
    }
    if (bars === null || typeof bars !== "object" || Array.isArray(bars)) {
      const got = Array.isArray(bars) ? "an array" : bars === null ? "null" : typeof bars;
      console.error(`ci-guards: ${barsDir}/${role}.json must be a JSON OBJECT keyed by competency code, got ${got}.`);
      process.exit(1);
    }
    for (const comp of Object.keys(bars)) {
      const entries = bars[comp];
      if (!Array.isArray(entries)) continue;
      entries.forEach((entry, position) => {
        if (entry === null || typeof entry !== "object") return;
        const localeMaps = {
          indicator: entry.indicator,
          anchor_5: entry.scale && entry.scale["5"],
          anchor_3: entry.scale && entry.scale["3"],
          anchor_1: entry.scale && entry.scale["1"],
        };
        for (const field of FIELDS) {
          const map = localeMaps[field];
          // HARD FAIL, matching catalog_crossrole_duplicates on the identical
          // shape. This used to `continue`, so reverting one bars file to the
          // pre-migration bare-string shape made the cross-role guard go red
          // while this one reported zero divergences over a tree it had never
          // examined — the docblock above promised it failed closed on exactly
          // this, and it failed open instead.
          if (map === null || typeof map !== "object" || Array.isArray(map)) {
            console.error(`ci-guards: ${barsDir}/${role}.json ${comp} ${field} is not a locale-map object (got ${typeof map}); expected {"en":...,"it":...}.`);
            process.exit(1);
          }
          const en = typeof map.en === "string" ? map.en : undefined;
          const it = typeof map.it === "string" && map.it.length > 0 ? map.it : undefined;
          perPosition[comp] ??= {};
          perPosition[comp][field] ??= {};
          perPosition[comp][field][role] ??= [];
          perPosition[comp][field][role][position] = { en, it };
        }
      });
    }
  }

  const out = new Set();

  for (const comp of Object.keys(perPosition)) {
    for (const field of Object.keys(perPosition[comp])) {
      const byRole = perPosition[comp][field];
      const roleList = Object.keys(byRole).sort();

      for (let i = 0; i < roleList.length; i++) {
        for (let j = i + 1; j < roleList.length; j++) {
          const roleA = roleList[i];
          const roleB = roleList[j];
          const entriesA = byRole[roleA];
          const entriesB = byRole[roleB];

          // Compare every (posA, posB) combination — the same "any position,
          // not just matching index" discipline catalog_crossrole_duplicates
          // itself uses (it dedups by VALUE across the whole competency
          // block, not by array index).
          for (const a of entriesA) {
            if (!a || a.en === undefined) continue;
            for (const b of entriesB) {
              if (!b || b.en === undefined) continue;

              if (a.en === b.en) {
                // EN identical — IT, once authored on BOTH sides, must agree too.
                if (a.it !== undefined && b.it !== undefined && a.it !== b.it) {
                  out.add(`${roleA}:${roleB}:${comp}:${field}:diverges-though-en-identical`);
                }
              } else if (a.it !== undefined && b.it !== undefined && a.it === b.it) {
                // EN differs, but IT converged — the mirror-direction defect.
                out.add(`${roleA}:${roleB}:${comp}:${field}:converges-though-en-differs`);
              }
            }
          }
        }
      }
    }
  }

  console.log([...out].sort().join("\n"));
'

# Prints the cross-locale divergences for tree $1. Fails closed on the same
# "cannot read its subject" conditions catalog_crossrole_duplicates obeys.
catalog_crosslocale_duplicate_divergence() {
  CI_TREE="$1"
  export CI_TREE
  if [ ! -d "$CI_TREE/bars" ]; then
    echo "ci-guards: $CI_TREE/bars does not exist." >&2
    return 1
  fi
  bun --eval "$CI_CROSSLOCALE_DIVERGENCE_SCRIPT"
}

# ---------------------------------------------------------------------------
# Anchor word-count drift (bars-catalogue-completion, Phase 5).
#
# Phase 4's own apply-progress records the defect this guard exists to close:
# a first draft where roughly half of ~90 new anchors ran 19-26 words against
# the house-voice standard's own rule — leader anchors are "one sentence,
# 10-18 words" (framework-authoring/house-voice-and-anti-hedge-standard.md
# §1.2) — caught only by a throwaway word-count script run BY HAND against
# Phase 3's already-measured anchors, because no CI guard checked anchor
# length at all. That exact regression would have shipped clean through
# every gate that existed at the time — "a check that cannot fail on the
# thing it claims to cover", the defect class this file's own header names.
#
# Word count, not character count: the standard's own unit is words, and a
# character-length proxy drifts from it the moment vocabulary shifts (short
# common words vs. longer domain terms expressing the same idea). Counted the
# way a human reading the rule would: trim, then split on whitespace,
# filtering empty tokens so doubled or edge whitespace cannot inflate the
# count — the SAME whitespace discipline `catalog_malformed_bars_entries`
# already enforces on these exact strings, so a string that guard accepts is
# measured here without surprises.
#
# Prints ROLE:COMP:LEVEL:LOCALE:WORDCOUNT for every scale anchor (5, 3 and 1 —
# an INDICATOR's own word count is a different rule, §1.1's 6-16 words, and
# not this guard's business), for EVERY locale present in that anchor's
# locale map, in <tree>/bars/<role>.json, regardless of length — the raw
# fact, the same shape as every other raw-fact reader in this file
# (`role_competency_pairs`, `bars_competency_keys`). Policy — what counts as
# too long or too short, PER LOCALE — is layered on by the two functions
# below it, not decided here. WORDCOUNT stays the LAST field on purpose, so
# `${LINE##*:}` (used by both policy functions) is untouched by adding the
# LOCALE field ahead of it.
#
# Locale-map shape (framework-catalog-it-translations design D1): each scale
# value is `{"en": "...", "it": "..."}`. This is the ONE line design D1 calls
# out as "the guard that would go silently blind" — the pre-locale version
# did `if (typeof text !== "string") continue`, which under the new shape
# examines the LOCALE-MAP object, is never a string, and silently emits
# nothing, so `catalog_overlong_bars_anchors` would pass VACUOUSLY over an
# entire tree of un-migrated or malformed content. That line is now a hard
# `process.exit(1)`: a scale value that is not a locale-map object at all is
# a shape defect this guard refuses to silently skip past. Once inside a
# genuine locale map: a MISSING locale key is skipped (that locale is simply
# not yet authored — legitimate during a partial rollout); a PRESENT value
# that is not a string is the same "silently blind" defect one level down
# and is also a hard failure; a present EMPTY string is skipped (blankness
# is `catalog_malformed_bars_entries`'s question, not this guard's).
#
# Fails closed (nothing on stdout, non-zero exit) on a missing, unparseable,
# or wrongly-shaped bars file, OR a scale value that is not a locale-map
# object — the same rule every reader in this file obeys.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
CI_ANCHOR_WORDCOUNT_SCRIPT='
  const path = process.env.CI_BARS_FILE;
  const role = process.env.CI_WC_ROLE;
  const locales = (process.env.CI_LOCALES || "en").split(" ").filter(Boolean);
  let bars;
  try {
    bars = JSON.parse(await Bun.file(path).text());
  } catch (e) {
    console.error(`ci-guards: cannot read or parse ${path}: ${e.message}`);
    process.exit(1);
  }
  if (bars === null || typeof bars !== "object" || Array.isArray(bars)) {
    const got = Array.isArray(bars) ? "an array" : bars === null ? "null" : typeof bars;
    console.error(`ci-guards: ${path} must be a JSON OBJECT keyed by competency code, got ${got}.`);
    process.exit(1);
  }
  const wc = (s) => (typeof s === "string" ? s.trim().split(/\s+/).filter(Boolean).length : 0);
  const out = [];
  for (const comp of Object.keys(bars)) {
    const entries = bars[comp];
    if (!Array.isArray(entries)) continue;
    for (const entry of entries) {
      if (entry === null || typeof entry !== "object") continue;
      const scale = entry.scale;
      if (scale === null || typeof scale !== "object") continue;
      for (const level of ["5", "3", "1"]) {
        const localeMap = scale[level];
        if (localeMap === undefined) continue;
        // THE line design D1 names: a non-locale-map value here used to be
        // silently `continue`d past. It is now a hard failure — see the
        // comment block above.
        if (localeMap === null || typeof localeMap !== "object" || Array.isArray(localeMap)) {
          console.error(`ci-guards: ${path} ${comp} scale.${level} is not a locale-map object (got ${typeof localeMap}); expected {"en":...,"it":...}.`);
          process.exit(1);
        }
        for (const locale of locales) {
          if (!(locale in localeMap)) continue; // not yet authored for this locale
          const text = localeMap[locale];
          if (typeof text !== "string") {
            console.error(`ci-guards: ${path} ${comp} scale.${level}.${locale} is not a string (got ${typeof text}).`);
            process.exit(1);
          }
          if (text.length === 0) continue;
          out.push(`${role}:${comp}:${level}:${locale}:${wc(text)}`);
        }
      }
    }
  }
  console.log(out.join("\n"));
'

bars_anchor_word_counts() {
  CI_BARS_FILE="$1/bars/$2.json"
  CI_WC_ROLE="$2"
  export CI_BARS_FILE CI_WC_ROLE
  if [ ! -f "$CI_BARS_FILE" ]; then
    echo "ci-guards: $CI_BARS_FILE does not exist." >&2
    return 1
  fi
  bun --eval "$CI_ANCHOR_WORDCOUNT_SCRIPT"
}

# The role this blocking maximum does NOT apply to — a role name, not a
# magic number, exactly so this comment can say what it means: ICO's anchors
# follow a DIFFERENT, documented register — two sentences, 20-30 words
# (house-voice-and-anti-hedge-standard.md §1.2) — not the leader-file
# one-sentence, 10-18-word shape this ceiling exists to hold every NEW pair
# to. ICO's anchors are not new content under this change and are not being
# retro-reviewed against a rule written for a different role's voice. The
# exemption is role-level and LOCALE-BLIND (framework-catalog-it-translations
# design D2, row 5): ICO's register is inherited by its Italian translation
# too, so an ICO `it` anchor is not examined either, for the same reason.
#
# Lives INSIDE the policy function below, not in the workflow step that calls
# it, so a self-test can prove the exemption against the SAME function the
# real gate calls (per this file's own header thesis) instead of trusting a
# `[ "$ROLE" = "ICO" ] && continue` typed a second time at the call site.
CI_ANCHOR_WORDCOUNT_EXEMPT_ROLE="ICO"

# The blocking EN ceiling. Measured, not guessed: at the time this guard was
# written, FLL, MLL, BUL and the staged SRX content already top out at 18
# words — see this function's self-test row in wrapper-ci.yml step (f) for
# the proof against a genuinely-violating fixture. Needs no committed
# baseline the way the cross-role check above does, because nothing today
# exceeds it.
CI_ANCHOR_WORDCOUNT_MAX=18

# The floor is a DIFFERENT question, deliberately not enforced by the
# function below this one — see catalog_short_bars_anchors's own comment.
CI_ANCHOR_WORDCOUNT_MIN=10

# The Italian ceiling/floor (framework-catalog-it-translations design D3).
#
# The CEILING is now MEASURED at 26 (see below). The FLOOR is still unset, and
# that asymmetry is the whole state of this pair: `catalog_overlong_bars_anchors`
# checks `it` for real, `catalog_short_bars_anchors` returns 2 for it and its
# caller reports that as a note rather than a failure.
#
# This paragraph used to open "Deliberately UNSET here", written when neither
# had a number, and it stayed after the measurement landed — in the file whose
# thesis is that a note outliving its fact is how defects survive. It is kept,
# corrected, rather than deleted, because the reasoning below is still why the
# floor has no number: Phase 5 of that change measures a 36-anchor pilot
# (PRS x {FLL,MLL,BUL,SRX}) and derives these from the measured EN/IT length
# RATIO (R = 90th percentile), the SAME "measured, not guessed" discipline
# CI_ANCHOR_WORDCOUNT_MAX's own comment claims for English. Reusing the EN
# number outright, or inventing an IT number without a measurement, is
# EXACTLY the failure mode this file's own header names ("a check that
# cannot fail on the thing it claims to cover") — so both functions FAIL
# CLOSED (non-zero, explained on stderr) when asked about a locale whose
# threshold is unset, rather than silently applying the English number or
# silently passing everything. That branch is now reached by the FLOOR for
# `it`, and by either function for a locale nobody has measured at all; the
# self-test moved its fail-closed row from `it` to `fr` when the ceiling
# measurement landed, for exactly this reason. A self-test may override these via the environment (the same
# seam every other constant in this file already exposes) to prove the
# mechanism without waiting for the real Phase 5 measurement.
#
# MEASURED 2026-08-18, recorded in full at
# docs/app_description/02-domain/framework-authoring/it/anchor-length-ceiling-measurement.md:
# 36 anchors (PRS x {FLL,MLL,BUL,SRX}), authored BLIND to the existence of any
# ceiling. Ratio wc_it/wc_en: median 1.172, p90 1.414, max 1.444.
# ceil(18 * 1.414) = 26, and 0 of 36 exceed it, so the falsification clause did
# not fire. Note that ceil(18 * max) is ALSO 26 — p90 and max agree, so the
# number does not depend on which statistic was picked, which is the strongest
# evidence available at this sample size that 26 is a property of the language
# pair rather than of these 36 sentences.
# Amending it means appending a fresh table to that file, never a silent bump.
CI_ANCHOR_WORDCOUNT_MAX_IT="${CI_ANCHOR_WORDCOUNT_MAX_IT:-26}"
# The floor stays unset and therefore non-blocking, matching English: the EN
# floor is a report because legacy anchors run to six words, and there is no
# Italian legacy to measure a floor against yet.
CI_ANCHOR_WORDCOUNT_MIN_IT="${CI_ANCHOR_WORDCOUNT_MIN_IT:-}"

# BLOCKING: anchors over the LOCALE's ceiling ($3, default "en"), for one
# role in one tree. Prints ROLE:COMP:LEVEL:LOCALE:WORDCOUNT for every anchor
# whose word count exceeds that locale's ceiling. Empty output means every
# anchor in <tree>/bars/<role>.json for that locale is at or under the
# limit, OR the role is the documented ICO exemption above.
#
# Propagates bars_anchor_word_counts's failure rather than absorbing it — the
# same "a guard that cannot read its subject must never pass it" rule every
# other function here obeys. The ICO exemption is checked FIRST and returns
# success without reading the file at all: an exempt role is not examined,
# not examined-and-found-clean. An UNCONFIGURED locale ceiling (`fr`, `de` —
# NOT `it`, whose ceiling was measured at 26 on 2026-08-18) is ALSO a
# fail-closed condition,
# not a silent pass — see CI_ANCHOR_WORDCOUNT_MAX_IT's own comment.
catalog_overlong_bars_anchors() {
  CI_COBA_TREE="$1"
  CI_COBA_ROLE="$2"
  CI_COBA_LOCALE="${3:-en}"
  [ "$CI_COBA_ROLE" = "$CI_ANCHOR_WORDCOUNT_EXEMPT_ROLE" ] && return 0

  case "$CI_COBA_LOCALE" in
    en) CI_COBA_MAX="$CI_ANCHOR_WORDCOUNT_MAX" ;;
    it) CI_COBA_MAX="$CI_ANCHOR_WORDCOUNT_MAX_IT" ;;
    *)
      # 2, not 1 — the same split catalog_short_bars_anchors already makes, and
      # for the same reason. CLAUDE.md calls es/fr/de/pt desirable, and the day
      # one of them joins CI_LOCALES this returned 1 and step (d) printed "the
      # anchor-length check could not read <TREE>/bars/FLL.json for locale
      # [es]" — a red build accusing a file that is perfectly fine. The floor
      # got this right; the ceiling did not.
      echo "ci-guards: catalog_overlong_bars_anchors: no measured ceiling configured for locale [$CI_COBA_LOCALE]." >&2
      return 2
      ;;
  esac

  if [ -z "$CI_COBA_MAX" ]; then
    echo "ci-guards: catalog_overlong_bars_anchors: no measured ceiling configured for locale [$CI_COBA_LOCALE] (CI_ANCHOR_WORDCOUNT_MAX_IT unset — see design D3 pilot)." >&2
    return 2
  fi

  CI_COBA_COUNTS=$(bars_anchor_word_counts "$CI_COBA_TREE" "$CI_COBA_ROLE") || return 1
  printf '%s\n' "$CI_COBA_COUNTS" | while IFS= read -r CI_COBA_LINE; do
    [ -n "$CI_COBA_LINE" ] || continue
    CI_COBA_LINE_LOCALE=$(printf '%s' "$CI_COBA_LINE" | cut -d: -f4)
    [ "$CI_COBA_LINE_LOCALE" = "$CI_COBA_LOCALE" ] || continue
    CI_COBA_WC=${CI_COBA_LINE##*:}
    # `continue` on the FALSE branch, not a bare `[ ] &&` — a `while` pipeline's
    # exit status is that of the LAST command run in its body, and a bare
    # failing `[ ]` test on the final line would leak "false" as the whole
    # function's exit status even though nothing was actually wrong. Verified:
    # without this, `catalog_overlong_bars_anchors` returned 1 on a fully
    # compliant file (BUL, every anchor <=18 words) purely because the LAST
    # anchor checked happened to be under the ceiling.
    [ "$CI_COBA_WC" -gt "$CI_COBA_MAX" ] || continue
    printf '%s\n' "$CI_COBA_LINE"
  done
}

# NON-BLOCKING REPORT: anchors under the LOCALE's floor ($3, default "en"),
# for one role in one tree. Same doctrine as the hedge-marker rate in
# house-voice-and-anti-hedge-standard.md §2.3: printed for a human to read
# during review, never a build failure — the caller in wrapper-ci.yml step
# (d) must NOT set FAIL on this function's output.
#
# The floor is not made blocking for the same reason the hedge ceiling is
# advisory rather than enforced: FLL and MLL each carry legacy anchors as
# short as 6 and 7 words, authored long before this change and explicitly
# out of its retro-review scope (house-voice-and-anti-hedge-standard.md
# §Scope). Blocking a floor of 10 today would fail on content this change is
# not touching, for the sole reason that a later, unrelated PR happened to
# read it. An unconfigured locale floor (`it`, which has a measured ceiling but
# no measured floor, and any locale nobody has measured at all) returns
# non-zero rather than silently reporting nothing, for the same reason the
# blocking ceiling above fails closed.
#
# TWO failure codes, because the caller has to tell them apart:
#   2 — no measured threshold for this locale. A configuration state, not a
#       defect. The `it` floor has never been measured (design D3 pilot), and
#       a floor is measured, never guessed: Italian runs longer than English,
#       so reusing 10 would report half the catalogue as too short.
#   1 — the tree could not be read. That IS a defect and must block.
# Both used to be 1, so a caller looping over CI_LOCALES could only choose
# between failing the build on an unmeasured locale or ignoring a genuinely
# unreadable tree. Neither is acceptable, so the function says which happened.
#
# No role exemption here, unlike the maximum above — a floor is advisory by
# construction, so there is nothing for an exemption to protect against.
catalog_short_bars_anchors() {
  CI_CSBA_TREE="$1"
  CI_CSBA_ROLE="$2"
  CI_CSBA_LOCALE="${3:-en}"

  case "$CI_CSBA_LOCALE" in
    en) CI_CSBA_MIN="$CI_ANCHOR_WORDCOUNT_MIN" ;;
    it) CI_CSBA_MIN="$CI_ANCHOR_WORDCOUNT_MIN_IT" ;;
    *)
      echo "ci-guards: catalog_short_bars_anchors: unknown locale [$CI_CSBA_LOCALE]." >&2
      return 2
      ;;
  esac

  if [ -z "$CI_CSBA_MIN" ]; then
    echo "ci-guards: catalog_short_bars_anchors: no measured floor configured for locale [$CI_CSBA_LOCALE] (CI_ANCHOR_WORDCOUNT_MIN_IT unset — see design D3 pilot)." >&2
    return 2
  fi

  CI_CSBA_COUNTS=$(bars_anchor_word_counts "$CI_CSBA_TREE" "$CI_CSBA_ROLE") || return 1
  printf '%s\n' "$CI_CSBA_COUNTS" | while IFS= read -r CI_CSBA_LINE; do
    [ -n "$CI_CSBA_LINE" ] || continue
    CI_CSBA_LINE_LOCALE=$(printf '%s' "$CI_CSBA_LINE" | cut -d: -f4)
    [ "$CI_CSBA_LINE_LOCALE" = "$CI_CSBA_LOCALE" ] || continue
    CI_CSBA_WC=${CI_CSBA_LINE##*:}
    # Same `continue`-on-false discipline as catalog_overlong_bars_anchors
    # above, for the same reason — see its comment.
    [ "$CI_CSBA_WC" -lt "$CI_CSBA_MIN" ] || continue
    printf '%s\n' "$CI_CSBA_LINE"
  done
}
