#!/usr/bin/env bun
// BEAI — BARS review table generator (bars-catalogue-completion, design §6).
//
// GENERATED, NEVER COMMITTED. Run it locally, paste its output into the PR
// body. It is reproducible from the JSON that is already in the diff, so a
// committed copy would just be a second copy that can drift — the same
// reasoning that keeps scripts/framework-competency-gaps.txt generated-not-
// typed, applied to something with no reason to live in the repository at
// all.
//
// Usage (Bun only — this repository is Bun-only, see scan_bun_only in
// scripts/ci-guards.sh):
//
//   bun scripts/bars-review-table.mjs COMP [COMP2 ...]
//
// For each competency code, prints ONE markdown table per indicator
// position (1, 2, 3) — every role that currently anchors that competency as
// a column, that position's indicator text and its three anchor levels as
// rows — followed by a NON-BLOCKING hedge-marker / similarity report for
// that competency's level-3 anchors.
//
// Reads the AUTHORED source tree (docs/app_description/02-domain/framework)
// by default; override with FRAMEWORK_TREE=<path>. SRX is read from
// bars/SRX.json if it exists (post-materialisation, design §6/Phase 6), and
// from the SRX staging file otherwise (design §6's "SRX staging" —
// openspec/changes/bars-catalogue-completion/staging/SRX.partial.json,
// override with SRX_STAGING_FILE=<path>) — the column a reviewer checks
// SRX's still-staged content against before it ever lands in a tree gate
// reads.
//
// What this tool does NOT do: fail the build, gate a merge, or assert
// anything is correct. It renders what a human needs to read to judge that
// for themselves, and reports two numbers a human should look at, not trust
// blindly — see the ceiling note printed with the hedge report, and
// docs/app_description/02-domain/framework-authoring/house-voice-and-anti-hedge-standard.md
// §2 for why no threshold here is a gate.

import { existsSync, readFileSync } from "node:fs";

const ROLE_ORDER = ["ICO", "FLL", "MLL", "BUL", "SRX"];

const FRAMEWORK_TREE =
  process.env.FRAMEWORK_TREE ?? "docs/app_description/02-domain/framework";
const SRX_STAGING_FILE =
  process.env.SRX_STAGING_FILE ??
  "openspec/changes/bars-catalogue-completion/staging/SRX.partial.json";

// The exact seven markers the spec scenario ("Levels differ by behaviour,
// not by adverb alone") names, and no others — an invented longer list would
// silently change what the ≤30% ceiling (house-voice-and-anti-hedge-
// standard.md §2.3) was measured against.
const HEDGE_MARKERS = [
  "occasional",
  "occasionally",
  "may",
  "generally",
  "most",
  "some",
  "rarely",
  "consistently",
];

// A small, deliberately conservative English stopword list for the
// content-token Dice similarity — function words only, never a word that
// could itself be the object or action distinguishing two levels.
const STOPWORDS = new Set([
  "a",
  "an",
  "and",
  "as",
  "at",
  "be",
  "but",
  "by",
  "for",
  "from",
  "in",
  "into",
  "is",
  "it",
  "of",
  "on",
  "or",
  "own",
  "that",
  "the",
  "their",
  "these",
  "this",
  "those",
  "to",
  "with",
]);

function readJsonIfExists(path) {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    console.error(`bars-review-table: cannot parse ${path}: ${e.message}`);
    process.exit(1);
  }
}

function loadBars(role) {
  const treeFile = `${FRAMEWORK_TREE}/bars/${role}.json`;
  if (existsSync(treeFile)) {
    return readJsonIfExists(treeFile);
  }
  if (role === "SRX" && existsSync(SRX_STAGING_FILE)) {
    return readJsonIfExists(SRX_STAGING_FILE);
  }
  return null;
}

function hedgeStrip(text) {
  const pattern = new RegExp(`\\b(${HEDGE_MARKERS.join("|")})\\b`, "gi");
  return text.replace(pattern, " ").replace(/\s+/g, " ").trim();
}

function contentTokens(text) {
  return new Set(
    text
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, " ")
      .split(/\s+/)
      .filter((t) => t.length > 0 && !STOPWORDS.has(t))
  );
}

function diceSimilarity(a, b) {
  const setA = contentTokens(hedgeStrip(a));
  const setB = contentTokens(hedgeStrip(b));
  if (setA.size === 0 && setB.size === 0) return 1;
  let intersection = 0;
  for (const token of setA) {
    if (setB.has(token)) intersection++;
  }
  return (2 * intersection) / (setA.size + setB.size);
}

function hasHedgeMarker(text) {
  const pattern = new RegExp(`\\b(${HEDGE_MARKERS.join("|")})\\b`, "i");
  return pattern.test(text);
}

function renderCompetency(comp) {
  const perRole = {};
  for (const role of ROLE_ORDER) {
    const bars = loadBars(role);
    if (bars && Array.isArray(bars[comp]) && bars[comp].length > 0) {
      perRole[role] = bars[comp];
    }
  }

  const anchoredRoles = ROLE_ORDER.filter((r) => perRole[r]);
  if (anchoredRoles.length === 0) {
    console.log(`## ${comp}\n\n_No role currently anchors this competency (neither a tree nor the SRX staging file)._\n`);
    return;
  }

  console.log(`## ${comp}\n`);

  const maxPositions = Math.max(...anchoredRoles.map((r) => perRole[r].length));
  const level3Anchors = [];

  for (let position = 0; position < maxPositions; position++) {
    console.log(`### Indicator ${position + 1}\n`);
    console.log("| Role | Indicator | Level 5 | Level 3 | Level 1 |");
    console.log("|---|---|---|---|---|");
    for (const role of anchoredRoles) {
      const entry = perRole[role][position];
      if (!entry) {
        console.log(`| ${role} | _(not yet at this position)_ | | | |`);
        continue;
      }
      const scale = entry.scale ?? {};
      const l5 = scale["5"] ?? "";
      const l3 = scale["3"] ?? "";
      const l1 = scale["1"] ?? "";
      console.log(`| ${role} | ${entry.indicator ?? ""} | ${l5} | ${l3} | ${l1} |`);
      if (l3) level3Anchors.push({ role, position: position + 1, l3, l5 });
    }
    console.log("");
  }

  // ─── Non-blocking hedge-rate / similarity report (advisory ONLY) ───────
  // See house-voice-and-anti-hedge-standard.md §2 — this NEVER fails a
  // build. It flags anchors worth a second human read; it does not
  // adjudicate them.
  console.log("### Hedge-rate report (non-blocking — see standard doc §2)\n");
  const hedged = level3Anchors.filter((a) => hasHedgeMarker(a.l3));
  const rate = level3Anchors.length > 0 ? (hedged.length / level3Anchors.length) * 100 : 0;
  console.log(
    `${hedged.length} of ${level3Anchors.length} level-3 anchors (${rate.toFixed(1)}%) carry a hedge marker. ` +
      `Ceiling: ≤30% (legacy baseline 76%; ICO alone 89%). Exceeding this does NOT fail the build — it is a signal to re-read the flagged anchors against §2.1, not an automatic rewrite order.\n`
  );
  if (hedged.length > 0) {
    console.log("| Role | Indicator # | Level-3 anchor | Dice(L5,L3) after hedge-strip |");
    console.log("|---|---|---|---|");
    for (const a of hedged) {
      const sim = diceSimilarity(a.l5, a.l3).toFixed(2);
      console.log(`| ${a.role} | ${a.position} | ${a.l3} | ${sim} |`);
    }
    console.log("");
  }
}

const competencies = process.argv.slice(2);
if (competencies.length === 0) {
  console.error("Usage: bun scripts/bars-review-table.mjs COMP [COMP2 ...]");
  console.error("Example: bun scripts/bars-review-table.mjs JDG TMG");
  process.exit(1);
}

for (const comp of competencies) {
  renderCompetency(comp.toUpperCase());
}
