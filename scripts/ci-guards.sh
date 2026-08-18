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
    # The bars file exists and this competency is NOT anchored in it. That is
    # a LIVE gap, not a stale exemption — unless roles.json no longer declares
    # the pair at all, which is the orphaned shape. Printing "orphaned"
    # unconditionally here broke the contract three lines up ("prints nothing
    # when the pair is not actually stale") and would have told an operator to
    # delete an exemption that is doing its job.
    if role_competency_pairs "$CI_SCGER_TREE" 2>/dev/null | grep -qxF "$CI_SCGER_PAIR"; then
      return 1
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
#   * each with a non-empty `indicator` string
#   * a `scale` object with EXACTLY the keys "5", "3", "1" — no more, no
#     fewer (a missing level, or an extra stray key, both fail)
#   * every one of those four strings non-empty and with no leading or
#     trailing whitespace
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
    let ok = true;
    for (const entry of entries) {
      if (entry === null || typeof entry !== "object") { ok = false; break; }
      if (isBlank(entry.indicator) || hasEdgeWhitespace(entry.indicator)) { ok = false; break; }
      const scale = entry.scale;
      if (scale === null || typeof scale !== "object" || Array.isArray(scale)) { ok = false; break; }
      if (Object.keys(scale).sort().join(",") !== "1,3,5") { ok = false; break; }
      if (isBlank(scale["5"]) || hasEdgeWhitespace(scale["5"])) { ok = false; break; }
      if (isBlank(scale["3"]) || hasEdgeWhitespace(scale["3"])) { ok = false; break; }
      if (isBlank(scale["1"]) || hasEdgeWhitespace(scale["1"])) { ok = false; break; }
    }
    if (!ok) {
      out.push(`${role}:${comp}:malformed-entry`);
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
# Prints `ROLE_A:ROLE_B:COMP:FIELD`, one per line, for every such duplicate —
# `ROLE_A`/`ROLE_B` alphabetically ordered so the same real-world duplicate
# always prints the same line regardless of directory read order, and `FIELD`
# is one of `indicator`, `anchor_5`, `anchor_3`, `anchor_1`. Deliberately
# NOT a `<file>:<line>` reference: line numbers shift every time an earlier
# competency block grows, which every future content PR does, and a baseline
# keyed on them would drift out from under itself. The role/competency/field
# tuple is what stays stable while indicators pile up around it.
#
# Compared ACROSS roles only — never within one role's own file — matching
# the spec's own wording ("identical across roles"). A duplicate only within
# a single role's array is a different defect this guard does not claim.
#
# Fails closed (non-zero, nothing useful on stdout) when the bars/ directory
# cannot be listed, or any file in it is missing, unparseable, or not a JSON
# object keyed by competency code.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
CI_CROSSROLE_SCRIPT='
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
  // competency -> field -> string -> Set(roles that use it)
  const index = {};

  for (const role of roles) {
    const bars = perRole[role];
    for (const comp of Object.keys(bars)) {
      const entries = bars[comp];
      if (!Array.isArray(entries)) continue;
      for (const entry of entries) {
        if (entry === null || typeof entry !== "object") continue;
        const values = {
          indicator: entry.indicator,
          anchor_5: entry.scale && entry.scale["5"],
          anchor_3: entry.scale && entry.scale["3"],
          anchor_1: entry.scale && entry.scale["1"],
        };
        for (const field of FIELDS) {
          const val = values[field];
          if (typeof val !== "string" || val.length === 0) continue;
          index[comp] ??= {};
          index[comp][field] ??= {};
          index[comp][field][val] ??= new Set();
          index[comp][field][val].add(role);
        }
      }
    }
  }

  const dupPairs = new Set();
  for (const comp of Object.keys(index)) {
    for (const field of Object.keys(index[comp])) {
      for (const val of Object.keys(index[comp][field])) {
        const roleSet = [...index[comp][field][val]].sort();
        if (roleSet.length < 2) continue;
        for (let i = 0; i < roleSet.length; i++) {
          for (let j = i + 1; j < roleSet.length; j++) {
            dupPairs.add(`${roleSet[i]}:${roleSet[j]}:${comp}:${field}`);
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
  [ -f "$CI_CROSSROLE_BASELINE_FILE" ] || return 0
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
  CI_CUCD_KNOWN=$(known_crossrole_baseline_entries)
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
  known_crossrole_baseline_entries | while IFS= read -r CI_SCBE_ENTRY; do
    [ -n "$CI_SCBE_ENTRY" ] || continue
    printf '%s\n' "$CI_SCBE_FOUND" | grep -qxF "$CI_SCBE_ENTRY" && continue
    printf '%s\n' "$CI_SCBE_ENTRY"
  done
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
# Prints ROLE:COMP:LEVEL:WORDCOUNT for every scale anchor (5, 3 and 1 — an
# INDICATOR's own word count is a different rule, §1.1's 6-16 words, and not
# this guard's business) in <tree>/bars/<role>.json, regardless of length —
# the raw fact, the same shape as every other raw-fact reader in this file
# (`role_competency_pairs`, `bars_competency_keys`). Policy — what counts as
# too long or too short — is layered on by the two functions below it, not
# decided here.
#
# Fails closed (nothing on stdout, non-zero exit) on a missing, unparseable,
# or wrongly-shaped bars file — the same rule every reader in this file obeys.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
CI_ANCHOR_WORDCOUNT_SCRIPT='
  const path = process.env.CI_BARS_FILE;
  const role = process.env.CI_WC_ROLE;
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
        const text = scale[level];
        if (typeof text !== "string" || text.length === 0) continue;
        out.push(`${role}:${comp}:${level}:${wc(text)}`);
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
# retro-reviewed against a rule written for a different role's voice.
#
# Lives INSIDE the policy function below, not in the workflow step that calls
# it, so a self-test can prove the exemption against the SAME function the
# real gate calls (per this file's own header thesis) instead of trusting a
# `[ "$ROLE" = "ICO" ] && continue` typed a second time at the call site.
CI_ANCHOR_WORDCOUNT_EXEMPT_ROLE="ICO"

# The blocking ceiling. Measured, not guessed: at the time this guard was
# written, FLL, MLL, BUL and the staged SRX content already top out at 18
# words — see this function's self-test row in wrapper-ci.yml step (f) for
# the proof against a genuinely-violating fixture. Needs no committed
# baseline the way the cross-role check above does, because nothing today
# exceeds it.
CI_ANCHOR_WORDCOUNT_MAX=18

# The floor is a DIFFERENT question, deliberately not enforced by the
# function below this one — see catalog_short_bars_anchors's own comment.
CI_ANCHOR_WORDCOUNT_MIN=10

# BLOCKING: anchors over CI_ANCHOR_WORDCOUNT_MAX words, for one role in one
# tree. Prints ROLE:COMP:LEVEL:WORDCOUNT for every anchor whose word count
# exceeds the ceiling. Empty output means every anchor in
# <tree>/bars/<role>.json is at or under the limit, OR the role is the
# documented ICO exemption above.
#
# Propagates bars_anchor_word_counts's failure rather than absorbing it — the
# same "a guard that cannot read its subject must never pass it" rule every
# other function here obeys. The ICO exemption is checked FIRST and returns
# success without reading the file at all: an exempt role is not examined,
# not examined-and-found-clean.
catalog_overlong_bars_anchors() {
  [ "$2" = "$CI_ANCHOR_WORDCOUNT_EXEMPT_ROLE" ] && return 0
  CI_COBA_COUNTS=$(bars_anchor_word_counts "$1" "$2") || return 1
  printf '%s\n' "$CI_COBA_COUNTS" | while IFS= read -r CI_COBA_LINE; do
    [ -n "$CI_COBA_LINE" ] || continue
    CI_COBA_WC=${CI_COBA_LINE##*:}
    # `continue` on the FALSE branch, not a bare `[ ] &&` — a `while` pipeline's
    # exit status is that of the LAST command run in its body, and a bare
    # failing `[ ]` test on the final line would leak "false" as the whole
    # function's exit status even though nothing was actually wrong. Verified:
    # without this, `catalog_overlong_bars_anchors` returned 1 on a fully
    # compliant file (BUL, every anchor <=18 words) purely because the LAST
    # anchor checked happened to be under the ceiling.
    [ "$CI_COBA_WC" -gt "$CI_ANCHOR_WORDCOUNT_MAX" ] || continue
    printf '%s\n' "$CI_COBA_LINE"
  done
}

# NON-BLOCKING REPORT: anchors under CI_ANCHOR_WORDCOUNT_MIN words, for one
# role in one tree. Same doctrine as the hedge-marker rate in
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
# read it.
#
# No role exemption here, unlike the maximum above — a floor is advisory by
# construction, so there is nothing for an exemption to protect against.
catalog_short_bars_anchors() {
  CI_CSBA_COUNTS=$(bars_anchor_word_counts "$1" "$2") || return 1
  printf '%s\n' "$CI_CSBA_COUNTS" | while IFS= read -r CI_CSBA_LINE; do
    [ -n "$CI_CSBA_LINE" ] || continue
    CI_CSBA_WC=${CI_CSBA_LINE##*:}
    # Same `continue`-on-false discipline as catalog_overlong_bars_anchors
    # above, for the same reason — see its comment.
    [ "$CI_CSBA_WC" -lt "$CI_ANCHOR_WORDCOUNT_MIN" ] || continue
    printf '%s\n' "$CI_CSBA_LINE"
  done
}
