#!/usr/bin/env node
// Generates docs/inventory.md — the reuse-surface index the harness's
// duplication control is built on (see the harness spec §3.12).
//
// Walks the configured reuse-surface directories, extracts every exported
// function / class / const with its one-line doc summary, and writes a
// deterministic markdown index. CI regenerates it and fails on diff, so it
// can never go stale; agents consult it at planning time before writing a
// new helper.
//
//   node scripts/generate-inventory.mjs          # write docs/inventory.md
//   node scripts/generate-inventory.mjs --check  # exit 1 if it would change
//
// Zero dependencies. Line-regex based by design: it indexes the surface, it
// doesn't typecheck it. If a symbol matters and isn't picked up, give it a
// doc comment and a plain `export` — that convention is the point.

import { readdirSync, readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------------------
// EDIT PER REPO: the reuse surface. Directories whose exports are meant to be
// shared. Do NOT list routes/views/tests — those aren't reuse targets.
const SURFACE_DIRS = [
  "backend/src/services",
  "backend/src/constants",
  "frontend/src/composables",
  "frontend/src/utils",
  "frontend/src/api",
];
const FILE_RE = /\.(ts|tsx|js|mjs|vue)$/;
const IGNORE_RE = /\.(test|spec|d)\.(ts|tsx|js|mjs)$|__tests__|\.stories\./;
// ---------------------------------------------------------------------------

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "docs", "inventory.md");

const EXPORT_RE =
  /^export\s+(?:async\s+)?(function|class|const|let|enum|type|interface)\s+([A-Za-z_$][\w$]*)/;

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(p));
    else if (FILE_RE.test(entry.name) && !IGNORE_RE.test(p)) out.push(p);
  }
  return out.sort();
}

// The one-line summary: the FIRST line of the comment run directly above the
// export (// runs and /** blocks); falls back to a same-line trailing
// comment; else empty.
function summaryAbove(lines, i) {
  const run = [];
  for (let j = i - 1; j >= Math.max(0, i - 12); j--) {
    const line = lines[j].trim();
    let m = line.match(/^\/\/\s?(.*)$/);
    if (!m) m = line.match(/^(?:\/\*\*|\*)\s?(.*?)\s*(?:\*\/)?$/);
    if (m) {
      const text = m[1].trim();
      // Skip @tags, separators, and empty comment lines but keep walking.
      if (text && !text.startsWith("@") && !/^[-=*/\s]*$/.test(text)) run.unshift(text);
      continue;
    }
    break;
  }
  if (run.length) return run[0].replace(/^-+\s*/, "");
  const trailing = lines[i].match(/\/\/\s?(.*)$/);
  return trailing ? trailing[1].trim() : "";
}

function extract(file) {
  const lines = readFileSync(file, "utf8").split("\n");
  const symbols = [];
  lines.forEach((line, i) => {
    const m = line.match(EXPORT_RE);
    if (m) symbols.push({ kind: m[1], name: m[2], summary: summaryAbove(lines, i) });
  });
  return symbols;
}

const sections = [];
let total = 0;
for (const dir of SURFACE_DIRS) {
  const abs = join(ROOT, dir);
  if (!existsSync(abs)) continue;
  for (const file of walk(abs)) {
    const symbols = extract(file);
    if (symbols.length === 0) continue;
    total += symbols.length;
    const rel = relative(ROOT, file);
    const rows = symbols
      .map((s) => `| \`${s.name}\` | ${s.kind} | ${s.summary.replace(/\|/g, "\\|")} |`)
      .join("\n");
    sections.push(`### \`${rel}\`\n\n| Symbol | Kind | Summary |\n|---|---|---|\n${rows}`);
  }
}

const doc = `# Reuse inventory

> **GENERATED — do not hand-edit.** Regenerate with
> \`node scripts/generate-inventory.mjs\`; CI fails when this file is stale.
> This is the repo's reuse surface (${total} exported symbols). **Consult it —
> and grep — before writing a new helper, service, or class** (plan template's
> *Reuse audit* field; PR template's *Reuse* section). A symbol without a
> summary is missing its doc comment — add one where it's defined.

${sections.join("\n\n")}
`;

if (process.argv.includes("--check")) {
  const current = existsSync(OUT) ? readFileSync(OUT, "utf8") : "";
  if (current !== doc) {
    console.error(
      "docs/inventory.md is stale. Run: node scripts/generate-inventory.mjs"
    );
    process.exit(1);
  }
  console.log("inventory up to date");
} else {
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, doc);
  console.log(`wrote docs/inventory.md (${total} symbols)`);
}
