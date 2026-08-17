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
# What is true now: `shellcheck -s sh` and `dash -n` pass on this file AND on
# every `run:` block that sources it. The steps still EXECUTE under bash,
# because that is the Actions default and nothing here needs changing that.
# What POSIX compatibility buys is that `shell: sh` on a step would not
# silently break a guard, and that `shellcheck -s sh` stays able to check them.
# Verify both before changing this paragraph.
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
# Exit 0 when both files parse to the same document, 1 otherwise — including
# when either file is missing or is not valid JSON.
# ---------------------------------------------------------------------------
CI_JSON_CANONICAL_SCRIPT='
  const canonical = (v) => {
    if (Array.isArray(v)) return v.map(canonical);
    if (v === null || typeof v !== "object") return v;
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canonical(v[k])]));
  };
  const s = async (p) => JSON.stringify(canonical(JSON.parse(await Bun.file(p).text())));
  process.exit((await s(process.env.CI_JSON_A)) === (await s(process.env.CI_JSON_B)) ? 0 : 1);
'

json_canonical_equal() {
  CI_JSON_A="$1"
  CI_JSON_B="$2"
  export CI_JSON_A CI_JSON_B
  bun --eval "$CI_JSON_CANONICAL_SCRIPT" 2>/dev/null
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
# both wrong. Fail unconditionally and CI is permanently red over SRX.json,
# which is 54 indicators of expert assessment content nobody can produce on
# demand; a gate that cannot go green gets deleted within a week and then
# protects nothing. Warn only, and it is silently green over an incomplete
# binding catalog, which is how this survived in the first place.
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
  [ -f "$CI_KNOWN_GAPS_FILE" ] || return 0
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
  CI_KNOWN=$(known_gap_roles)
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
  known_gap_roles | while IFS= read -r CI_ROLE; do
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
# answers, yes or no. A file can exist and still be PARTIAL: FLL, MLL and BUL
# each anchor 8 of their 18 assigned competencies, and the role-level gate is
# structurally blind to that — the file is there, so it passes.
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
  [ -f "$CI_COMPETENCY_GAPS_FILE" ] || return 0
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
  CI_CUMBP_KNOWN=$(known_gap_pairs)
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
# file at ALL (SRX's shape, today). `catalog_missing_bars_pairs` skips such a
# role BY DESIGN (`[ -f ... ] || continue` — the pair-level gate is not this
# role's business, the role-level gate is); Direction 1 below requires the
# file to exist and so never runs; Direction 2 finds the pair legitimately
# declared in roles.json and so never fires either. Net effect before this
# fix: a line shaped like "SRX:PRS" is accepted onto the per-pair list,
# produces NO error in either existing direction, and stays mute FOREVER —
# until the day bars/SRX.json is authored, at which point it fires in a
# commit that has nothing to do with it. The file's own header already
# states the POLICY ("SRX's pairs stay under the role-level list, not here");
# Direction 3 below is what enforces it mechanically instead of by hoping
# nobody adds one.
catalog_stale_competency_gap_exemptions() {
  CI_CSCGE_TREE="$1"
  CI_CSCGE_DECLARED=$(mktemp)
  role_competency_pairs "$CI_CSCGE_TREE" > "$CI_CSCGE_DECLARED" 2>/dev/null
  CI_CSCGE_STATUS=$?

  known_gap_pairs | while IFS= read -r CI_CSCGE_PAIR; do
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

  if [ -f "$CI_SCGER_TREE/bars/$CI_SCGER_ROLE.json" ]; then
    CI_SCGER_COVERED=$(bars_competency_keys "$CI_SCGER_TREE" "$CI_SCGER_ROLE" 2>/dev/null)
    if printf '%s\n' "$CI_SCGER_COVERED" | grep -qxF "$CI_SCGER_COMP"; then
      echo "anchored"
      return 0
    fi
    echo "orphaned"
    return 0
  fi

  if role_competency_pairs "$CI_SCGER_TREE" 2>/dev/null | grep -qxF "$CI_SCGER_PAIR"; then
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
  known_gap_pairs > "$CI_CGRO_FILE"

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
