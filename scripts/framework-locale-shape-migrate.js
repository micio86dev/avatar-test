#!/usr/bin/env bun
// BEAI — framework catalogue locale-shape migration
// (framework-catalog-it-translations, design D1, tasks.md Phase 2.3-2.4).
//
// Mechanically rewrites every translatable leaf in the catalogue JSON from a
// bare string to an explicit locale-map object: `"text"` -> `{"en": "text"}`.
// This is the "sibling files vs nested key" fork design D1 ratifies in favour
// of the nested key — every existing CI content guard must be able to fail
// closed on the new shape rather than silently stop reading it, which a
// hand-edited migration cannot be trusted to guarantee across ~1042 leaves.
//
// MUST be re-run-safe: running this script twice on an already-migrated tree
// MUST produce a byte-for-byte-identical result (`git diff --exit-code` after
// a second run is the actual CI assertion — see tasks.md 2.4). A leaf that is
// ALREADY an object (already migrated) is left untouched; only a bare string
// leaf is wrapped.
//
// Rewrites, per tree root ($1):
//   competencies.json  — every entry's `name`, `definition`
//   roles.json          — every entry's `name`, `responsibilities`
//                          (`competencies` stays a plain array — not a
//                          translatable field, see design D1)
//   bars/*.json          — every entry's `indicator`, and `scale.5`/`scale.3`/`scale.1`
//
// Usage:
//   bun scripts/framework-locale-shape-migrate.js <tree-root> [<tree-root> ...]
//
// e.g.
//   bun scripts/framework-locale-shape-migrate.js \
//     docs/app_description/02-domain/framework \
//     api/database/framework
//
// Exits 1 on any read/parse/write failure — a migration script that cannot
// read its subject must never silently skip it (same "fails closed" doctrine
// as every guard in scripts/ci-guards.sh).

import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

/**
 * Wrap a bare-string leaf into `{"en": value}`. A value that is ALREADY a
 * locale-map object is returned untouched — this is what makes a second run
 * a no-op. Any other shape (number, array, null, etc.) is a pre-existing
 * data defect this migration does not attempt to silently paper over.
 */
function migrateLeaf(value, path) {
  if (typeof value === "string") {
    return { en: value };
  }
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    // Already migrated (or hand-authored with a locale map already) — leave
    // as-is. Re-running this script on a migrated tree must be a no-op.
    return value;
  }
  throw new Error(`framework-locale-shape-migrate: unexpected leaf shape at ${path}: ${JSON.stringify(value)}`);
}

function migrateCompetencies(json) {
  const out = {};
  for (const [code, entry] of Object.entries(json)) {
    out[code] = {
      ...entry,
      name: migrateLeaf(entry.name, `competencies.json:${code}.name`),
      definition: migrateLeaf(entry.definition, `competencies.json:${code}.definition`),
    };
  }
  return out;
}

function migrateRoles(json) {
  const out = {};
  for (const [code, entry] of Object.entries(json)) {
    out[code] = {
      ...entry,
      name: migrateLeaf(entry.name, `roles.json:${code}.name`),
      responsibilities: migrateLeaf(entry.responsibilities, `roles.json:${code}.responsibilities`),
      // `competencies` is a plain array of role codes — not translatable,
      // left untouched by construction (the spread above already copies it).
    };
  }
  return out;
}

function migrateBars(json, roleFile) {
  const out = {};
  for (const [comp, entries] of Object.entries(json)) {
    if (!Array.isArray(entries)) {
      throw new Error(`framework-locale-shape-migrate: ${roleFile} ${comp} is not an array of entries.`);
    }
    out[comp] = entries.map((entry, i) => {
      const scale = entry.scale ?? {};
      return {
        ...entry,
        indicator: migrateLeaf(entry.indicator, `${roleFile}:${comp}[${i}].indicator`),
        scale: {
          ...scale,
          5: migrateLeaf(scale["5"], `${roleFile}:${comp}[${i}].scale.5`),
          3: migrateLeaf(scale["3"], `${roleFile}:${comp}[${i}].scale.3`),
          1: migrateLeaf(scale["1"], `${roleFile}:${comp}[${i}].scale.1`),
        },
      };
    });
  }
  return out;
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    throw new Error(`framework-locale-shape-migrate: cannot read or parse ${path}: ${e.message}`);
  }
}

function writeJson(path, data) {
  // Stable 2-space indentation, trailing newline — matches the repository's
  // existing committed JSON formatting so the migration's own diff is
  // reviewable content, not a whitespace churn on top of it.
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
}

function migrateTree(treeRoot) {
  const competenciesPath = join(treeRoot, "competencies.json");
  const rolesPath = join(treeRoot, "roles.json");
  const barsDir = join(treeRoot, "bars");

  writeJson(competenciesPath, migrateCompetencies(readJson(competenciesPath)));
  writeJson(rolesPath, migrateRoles(readJson(rolesPath)));

  const barsFiles = readdirSync(barsDir).filter((f) => f.endsWith(".json")).sort();
  for (const file of barsFiles) {
    const barsPath = join(barsDir, file);
    writeJson(barsPath, migrateBars(readJson(barsPath), barsPath));
  }

  console.log(`framework-locale-shape-migrate: migrated ${treeRoot} (competencies.json, roles.json, ${barsFiles.length} bars files)`);
}

const roots = process.argv.slice(2);
if (roots.length === 0) {
  console.error("Usage: bun scripts/framework-locale-shape-migrate.js <tree-root> [<tree-root> ...]");
  process.exit(1);
}

try {
  for (const root of roots) {
    migrateTree(root);
  }
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
