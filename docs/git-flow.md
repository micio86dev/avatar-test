# BEAI — Git Flow & SemVer Release Flow

This document describes the **Git Flow** branching model and **SemVer M.m.p** release
process applied to **all four BEAI repositories**: the wrapper superproject, `api`,
`frontend`, and `backoffice`. Each repo is versioned independently and ships at its
own cadence.

---

## Repositories

| Repo | Role | Version SoT |
|------|------|-------------|
| wrapper (this repo) | Superproject; holds docs, SDD, docker-compose, Taskfile, submodule pointers | `package.json` `version` |
| `api` | Laravel 13 backend | `VERSION` file |
| `frontend` | Nuxt 4 SSR candidate app | `package.json` `version` |
| `backoffice` | Nuxt 4 SPA admin panel | `package.json` `version` |

---

## Branch Model

Each repo maintains the following permanent and transient branches:

```
main          ← production; tagged vM.m.p on each release
develop       ← integration target; all feature/hotfix branches merge here first
feature/*     ← new features and slices (branch from develop; PR → develop)
release/*     ← release preparation (branch from develop; bump version; merge → main + develop)
hotfix/*      ← emergency production fixes (branch from main; merge → main AND develop)
```

### Rules

- `main` is always deployable and never has direct pushes (PR only via `release/*` or `hotfix/*`).
- `develop` is the integration branch; all `feature/*` PRs target `develop`.
- A `feature/*` branch is cut from `develop` and merged back to `develop` (not `main`).
- A `release/*` branch is cut from `develop`, version is bumped, then merged to **both** `main` and `develop`.
- A `hotfix/*` branch is cut from **`main`** (not `develop`). After the fix it merges to **both** `main` (tagged) and `develop` so the fix is not lost.

---

## SemVer M.m.p Release Flow

Each repo uses [Semantic Versioning](https://semver.org):

- **MAJOR** (`M`): breaking API/contract changes (e.g. `/api/v2/` prefix, removed fields).
- **MINOR** (`m`): additive, non-breaking changes (new endpoints, new optional fields, new features).
- **PATCH** (`p`): backward-compatible bug fixes and security patches.

### Release Steps (per repo)

```bash
# 1. Cut a release branch from develop
git checkout develop
git pull
git checkout -b release/0.2.0

# 2. Bump the version SoT in this branch
#    api:          echo "0.2.0" > VERSION
#    Nuxt apps:    edit package.json "version": "0.2.0"
#    wrapper:      edit package.json "version": "0.2.0"
#    Commit the bump: git commit -m "chore: bump version to 0.2.0"

# 3. Merge into main and tag
git checkout main
git merge --no-ff release/0.2.0
git tag -a v0.2.0 -m "release: v0.2.0"
git push origin main --tags

# 4. Merge back into develop (carry the version bump forward)
git checkout develop
git merge --no-ff release/0.2.0
git push origin develop

# 5. Delete the release branch
git branch -d release/0.2.0
git push origin --delete release/0.2.0
```

### Hotfix Steps

```bash
# Cut from main (NOT develop)
git checkout main
git checkout -b hotfix/0.1.1

# Fix, commit, bump version patch
echo "0.1.1" > VERSION   # or edit package.json
git commit -m "fix: patch for X"
git commit -m "chore: bump version to 0.1.1"

# Merge into main and tag
git checkout main
git merge --no-ff hotfix/0.1.1
git tag -a v0.1.1 -m "release: v0.1.1"
git push origin main --tags

# Merge into develop — CRITICAL: never leave develop behind main
git checkout develop
git merge --no-ff hotfix/0.1.1
git push origin develop

git branch -d hotfix/0.1.1
git push origin --delete hotfix/0.1.1
```

> **Rule**: after every merge to `main`, immediately merge to `develop`. `main` must
> NEVER be ahead of `develop` without a corresponding merge back. This is the most
> common Git Flow mistake.

---

## Wrapper Submodule Pointer Pinning

The wrapper repo pins each submodule to a **released `vM.m.p` tag**, never a branch head.
This guarantees reproducible builds across local, CI, and Railway.

```bash
# After submodule repos have released their tags:
cd api
git checkout v0.1.0
cd ..
git add api
git commit -m "chore(api): pin submodule to v0.1.0"

# Repeat for frontend and backoffice.
```

The wrapper's `.gitmodules` declares each submodule path and URL. The `.git/config`
entry (filled by `git submodule init`) stores the resolved URL. The pointer stored in
the wrapper commit is the specific commit hash of the submodule's `v0.1.0` tag.

### Clone with submodules

```bash
git clone --recursive https://github.com/your-org/beai.git
# or for an already-cloned repo:
git submodule update --init --recursive
```

---

## Cross-Repo Merge Order (C1)

When all four repos have C1 features ready, merge in this order to respect the
OpenAPI snapshot dependency:

1. `api` — publishes `openapi.json` (Scramble); `v0.1.0` release tag on `api/main`.
2. `frontend` — codegens typed client from `api`'s committed `openapi.json`; `v0.1.0` on `frontend/main`.
3. `backoffice` — same codegen; `v0.1.0` on `backoffice/main`.
4. wrapper — bump `.gitmodules` pointers to all three `v0.1.0` tags; final wrapper PR targets `develop`.

---

## CI Notes

- Per-repo CI runs on push/PR to `develop` only (never directly on `main` — `main` only
  receives merges from `release/*` or `hotfix/*`).
- The wrapper CI runs on push/PR to wrapper `develop`; it does a `--recursive` checkout
  and verifies submodule pointers resolve.
- No CI step triggers a Railway deploy. Railway is configured per-service and activates
  only on explicit human request (CLAUDE.md).
