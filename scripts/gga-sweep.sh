#!/usr/bin/env bash
#
# GGA whole-codebase sweep.
#
# `gga run` reviews the git INDEX and sends every file in ONE prompt with no
# batching, so it cannot review a 195-file repository in a single call. This
# script feeds GGA the codebase in chunks through its real code path: stage a
# chunk, run `gga run --no-cache`, collect the verdict, repeat.
#
# Isolation: every chunk is staged in a throwaway `git worktree`, never in the
# repository's own index. Other agents may be committing on these repos while
# this runs; touching the real index would corrupt their work.
#
# GGA v2.10.1 requires bash >= 4 to read its own config: it loads `.gga` via
# `source <(...)`, and under macOS's bash 3.2 a process substitution does not
# propagate assignments — every setting silently falls back to defaults. We
# invoke it through the homebrew bash explicitly rather than trusting PATH.
#
# Usage: scripts/gga-sweep.sh [api|frontend|backoffice ...]   (default: all)

set -euo pipefail

WRAPPER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GGA_SWEEP_OUT:-$WRAPPER_ROOT/.gga-sweep}"
GGA_BIN="${GGA_BIN:-$(command -v gga)}"
MODERN_BASH="${MODERN_BASH:-/opt/homebrew/bin/bash}"

# Lines per chunk. GGA emits one prompt per chunk containing every file's full
# text plus the rules file, so this is the real cost knob.
CHUNK_LINES="${CHUNK_LINES:-2000}"

log() { printf '\033[0;36m[sweep]\033[0m %s\n' "$*"; }
err() { printf '\033[0;31m[sweep]\033[0m %s\n' "$*" >&2; }

require_modern_bash() {
  if [[ ! -x "$MODERN_BASH" ]]; then
    err "bash >= 4 not found at $MODERN_BASH (brew install bash)."
    err "GGA silently ignores its entire config under bash 3.2 — refusing to run."
    exit 1
  fi
  local v
  # shellcheck disable=SC2016  # must expand in the child bash, not here
  v="$("$MODERN_BASH" -c 'echo "${BASH_VERSINFO[0]}"')"
  if (( v < 4 )); then
    err "$MODERN_BASH is bash $v; GGA needs >= 4 to read .gga."
    exit 1
  fi
}

# Files a given repo's .gga would select, resolved the same way GGA does but
# applied to the whole tree instead of a diff.
list_files() {
  local repo="$1" patterns="$2" excludes="$3"
  local includes=() ex=()
  IFS=',' read -r -a includes <<< "$patterns"
  [[ -n "$excludes" ]] && IFS=',' read -r -a ex <<< "$excludes"

  git -C "$repo" ls-files | while IFS= read -r f; do
    local keep=0 p
    for p in "${includes[@]}"; do
      # shellcheck disable=SC2053  # intentional glob match, not string equality
      [[ "$(basename "$f")" == $p || "$f" == $p ]] && { keep=1; break; }
    done
    (( keep )) || continue
    for p in "${ex[@]}"; do
      # shellcheck disable=SC2053
      [[ "$(basename "$f")" == $p || "$f" == $p ]] && { keep=0; break; }
    done
    (( keep )) && echo "$f"
  done
}

read_cfg() {
  # Read one key out of a .gga without sourcing it (we only need two values,
  # and sourcing an untrusted config to grep it is a bad trade).
  local file="$1" key="$2"
  # shellcheck disable=SC2016  # '$1' is an sd capture group, not a shell variable
  rg -N --no-heading "^${key}=" "$file" 2>/dev/null | head -1 | sd "^${key}=\"?([^\"]*)\"?$" '$1'
}

sweep_repo() {
  local name="$1"
  local repo="$WRAPPER_ROOT/$name"
  local cfg="$repo/.gga"

  [[ -d "$repo" ]] || { err "$name: no such directory"; return 1; }
  [[ -f "$cfg" ]] || { err "$name: no .gga config"; return 1; }
  [[ -f "$repo/AGENTS.md" ]] || { err "$name: no AGENTS.md rules file"; return 1; }

  local patterns excludes
  patterns="$(read_cfg "$cfg" FILE_PATTERNS)"
  excludes="$(read_cfg "$cfg" EXCLUDE_PATTERNS)"
  log "$name: patterns=[$patterns] excludes=[$excludes]"

  local files_list="$OUT_DIR/$name.files"
  list_files "$repo" "$patterns" "$excludes" > "$files_list"
  local total
  total="$(wc -l < "$files_list" | tr -d ' ')"
  (( total > 0 )) || { err "$name: no files matched"; return 1; }

  # Group into chunks by cumulative line count, keeping the ls-files order so
  # files from the same directory stay in the same prompt.
  local chunk_dir="$OUT_DIR/$name.chunks"
  rm -rf "$chunk_dir"; mkdir -p "$chunk_dir"
  local acc=0 idx=1
  while IFS= read -r f; do
    local n
    n="$(wc -l < "$repo/$f" 2>/dev/null | tr -d ' ')" || n=0
    if (( acc > 0 && acc + n > CHUNK_LINES )); then
      idx=$(( idx + 1 )); acc=0
    fi
    printf '%s\n' "$f" >> "$(printf '%s/chunk-%02d' "$chunk_dir" "$idx")"
    acc=$(( acc + n ))
  done < "$files_list"

  local nchunks
  nchunks="$(find "$chunk_dir" -name 'chunk-*' | wc -l | tr -d ' ')"
  log "$name: $total files -> $nchunks chunks (~${CHUNK_LINES} lines each)"

  # One worktree reused across chunks. Detached HEAD at the current commit so
  # no branch is checked out and the source repo is never locked to a ref.
  local wt="$OUT_DIR/wt-$name"
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "$wt"
  git -C "$repo" worktree add --detach --quiet "$wt" HEAD
  # GGA reviews `git diff --cached`, i.e. the index against HEAD. In a fresh
  # worktree the index already equals HEAD, so `git add` stages nothing and GGA
  # reviews an empty set. Point HEAD at an unborn branch: the tree stays on
  # disk, but every file we add now registers as a new staged file.
  git -C "$wt" checkout --orphan "gga-sweep-$name" --quiet

  # `.gga` and `AGENTS.md` are untracked-new, so a HEAD checkout lacks them.
  cp "$cfg" "$wt/.gga"
  cp "$repo/AGENTS.md" "$wt/AGENTS.md"

  # while-read, not `for chunk in $(find ...)`: the repository path contains a
  # space, and word-splitting silently staged nothing while GGA still reported
  # PASSED — a green result that reviewed zero files.
  local chunk
  while IFS= read -r chunk; do
    local label
    label="$(basename "$chunk")"
    local out="$OUT_DIR/$name.$label.md"

    git -C "$wt" reset --quiet
    # Stage exactly this chunk. GGA reads staged content via `git show :file`.
    # --pathspec-from-file rather than xargs: macOS xargs has neither -a nor -d,
    # and this handles paths containing spaces without any quoting dance.
    git -C "$wt" add --pathspec-from-file="$chunk"

    local staged expected
    staged="$(git -C "$wt" diff --cached --name-only | wc -l | tr -d ' ')"
    expected="$(wc -l < "$chunk" | tr -d ' ')"
    # A review of zero files passes trivially. Never let that count as a result.
    if [[ "$staged" != "$expected" ]]; then
      err "$name/$label: staged $staged of $expected files — aborting, not reviewing a partial chunk"
      return 1
    fi
    log "$name/$label: $staged files staged -> reviewing"

    if ( cd "$wt" && GGA_PROVIDER=claude "$MODERN_BASH" "$GGA_BIN" run --no-cache ) \
        > "$out" 2>&1; then
      log "$name/$label: PASSED"
    else
      log "$name/$label: findings -> $out"
    fi
  done < <(find "$chunk_dir" -name 'chunk-*' | sort)

  git -C "$repo" worktree remove --force "$wt" || err "$name: worktree cleanup failed at $wt"
}

main() {
  require_modern_bash
  [[ -n "$GGA_BIN" && -x "$GGA_BIN" ]] || { err "gga not found on PATH"; exit 1; }
  mkdir -p "$OUT_DIR"

  local repos=("$@")
  (( ${#repos[@]} )) || repos=(api frontend backoffice)

  local r
  for r in "${repos[@]}"; do
    log "=== $r ==="
    sweep_repo "$r" || err "$r: sweep failed"
  done

  log "done — reports in $OUT_DIR"
}

main "$@"
