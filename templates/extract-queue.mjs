#!/usr/bin/env node
//
// TEMPLATE — copy to .claude/work/extract-queue.mjs and adapt the two marked
// sections. This is the ONE file per project you actually write.
//
//     node .claude/work/extract-queue.mjs [--write]
//
// The MAP is read-only: it records what is true about the codebase. The QUEUE is
// sprint state — status, batch assignment, ownership — and is the only one of the
// two that a sprint mutates. Queue entries reference map ids so the two can be
// rejoined.
//
// PLAIN CODE, NO MODEL. The `files` array derived here is what the partitioner
// uses to detect collisions, and a collision missed here becomes two agents
// editing one file in separate worktrees.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve, basename } from "node:path";
import { loadConfig } from "../../core/lib/config.mjs";
import {
    trackedFiles, buildResolver, citedFiles, DEFAULT_EXTENSIONS,
    withCompanions, mergeQueueState, collisionReport, assertScope,
} from "../../core/lib/extract.mjs";

const cfg = loadConfig();
const ROOT = cfg.$root;
const MAP_PATH = resolve(ROOT, cfg.map.path);
const QUEUE_PATH = resolve(ROOT, cfg.queue.path);
const WRITE = process.argv.includes("--write");

// A dry run is safe anywhere. WRITING from the wrong worktree is not: file
// citations resolve against the WORKING TREE, so a bare citation can be unique
// in one worktree and ambiguous in another. That produces a genuinely different
// collision graph — the one property the partitioner exists to guarantee.
if (WRITE && cfg.queue.writeOnlyFrom && basename(ROOT) !== cfg.queue.writeOnlyFrom) {
    console.error(`error: --write only from ${cfg.queue.writeOnlyFrom} (found: ${basename(ROOT)})`);
    console.error("       Drop --write to read the queue here.");
    process.exit(1);
}

const tracked = trackedFiles(ROOT, {
    // Exclude vendored trees and lockfiles: they are never an item's edit target
    // and they pollute basename resolution.
    exclude: ["package-lock.json", "vendor/", "node_modules/"],
});

const resolveCited = buildResolver(tracked, {
    // ── {{ALIASES}} ──────────────────────────────────────────────────────────
    // Your map's citation shorthands, spelled out. These are NOT guesses — each
    // must be a convention your map uses CONSISTENTLY. Getting one wrong silently
    // hides a collision, which is the failure this whole file exists to prevent.
    aliases: {
        // "actions.ts": "web/lib/actions.ts",
        // "globals.css": "web/app/globals.css",
    },
    // For basenames that repeat once per module (index.ts, main.go, mod.rs):
    // if the prose mentions `mention`, prefer the file under `dir`.
    dirHints: [
        // { mention: "ghl-webhook-in", dir: "supabase/functions/ghl-webhook-in/" },
    ],
});

// ── OVERRIDES ────────────────────────────────────────────────────────────────
//
// Declared BY HAND on purpose. The alternative — inferring file sets from names
// mentioned in prose — sweeps in every file an entry merely mentions for
// comparison ("X and Y both have this pattern"), serialising items that do not
// actually collide. A wrong hard edge is cheaper than a missed one, but a wrong
// edge on EVERY item is not.
//
// THE RULE for what belongs here:
//
//   An item gets an OVERRIDES `files` entry if and only if a human can name the
//   exact files it will touch TODAY, without designing anything first.
//
// Anything that cannot answer that gets a `scope` instead — see SCOPES in
// core/lib/extract.mjs. `note` is mandatory for anything you refuse: the note is
// what tells the next person how to un-refuse it.
// ── COMPANIONS ───────────────────────────────────────────────────────────────
//
// A file that another file CANNOT MOVE WITHOUT, applied to whatever the scraper
// already found. NOT an OVERRIDES entry and it does not weaken the ration on
// them: an OVERRIDES entry names an ITEM and asserts a human decision about that
// item's scope. This names a FILE RELATIONSHIP that holds for every item,
// forever, so it cannot smuggle scope onto work the map cannot describe.
//
// Your `pairedArtifacts` counterparts are added AUTOMATICALLY from config — you
// do not list them here. This table is for the relationships no rule can derive.
//
// UNDER-MAPPING IS SAFE AND OVER-MAPPING IS NOT. A file absent from this table
// behaves as it does today: the builder stops and reports `outOfScope`. A WRONG
// entry puts two builders in one file, which is the failure the whole collision
// graph exists to prevent. Map only where the relationship is unambiguous —
// never merely "this test imports that module".
const COMPANIONS = {
    // A manifest cannot move without its lockfile — `npm ci` fails on an
    // out-of-sync one, so an item that claims the manifest must claim the lock.
    // "web/package.json": ["web/package-lock.json"],
    // "api/pyproject.toml": ["api/uv.lock"],

    // A module and the test that covers it, where the suite is grouped by
    // FEATURE rather than by module and no pairPath rule can express it.
    // "api/src/pkg/parser.py":  ["api/tests/test_ingest.py"],
    // "api/src/pkg/loader.py":  ["api/tests/test_ingest.py"],
};

// ── OVERRIDES ────────────────────────────────────────────────────────────────
//
// (see the block above for what belongs here versus in COMPANIONS)
const OVERRIDES = {
    // "item-id": {
    //     files: ["path/one.ts", "path/two.ts"],
    //     note: "Both tables, one convention — splitting them guarantees two different paginations.",
    // },
    // "other-id": {
    //     scope: "external",
    //     note: "The truth lives on GitHub, not in this tree — never dispatch a builder at it.",
    // },
};

// ── {{EXTRACTION}} ───────────────────────────────────────────────────────────
//
// THE ONLY PART THAT KNOWS YOUR MAP'S SHAPE. Walk your map, call push() per item.
//
// Everything above and below is project-agnostic.

const map = JSON.parse(readFileSync(MAP_PATH, "utf8"));
const items = [];
const problems = [];

const textOf = (o) => (typeof o === "string" ? o : JSON.stringify(o));

// The extensions the scraper can see. THIS IS THE PARTITIONER — an extension
// missing here is a file the collision graph cannot see. Set
// `extract.fileExtensions` in harness.config.json for a repo whose work is not
// application source; a content site needs md/mdx/svg/png or its collisions are
// invisible.
const EXTENSIONS = cfg.extract?.fileExtensions ?? DEFAULT_EXTENSIONS;

function push({ id, source, severity, title, detail, extra = {} }) {
    const text = [title, textOf(detail)].join("\n");
    const { files, problems: p } = citedFiles(text, resolveCited, { extensions: EXTENSIONS });
    problems.push(...p.map((x) => ({ ...x, item: id })));

    const o = OVERRIDES[id] ?? {};

    // UNION the scraped paths with the override, do not replace. An override is
    // usually adding what the regex could not see, not correcting it.
    //
    // ⚠ THE FLIP SIDE, and it bites: any file path mentioned in an item's prose
    // — even in passing, even as a cross-reference — lands in that item's file
    // set and can MANUFACTURE A FALSE COLLISION. When you write map prose, name
    // the files you intend to EDIT; describe everything else without a path.
    const cited = [...new Set([...files, ...(o.files ?? [])])].sort();

    // Grant the companions of whatever was cited. This is what makes a paired
    // artifact REACHABLE: the gate compels `pairPath`, and until this ran, no
    // file list ever contained it, so the builder had to choose between failing
    // its own anchor and leaving scope.
    const merged = withCompanions(cited, {
        pairedArtifacts: cfg.pairedArtifacts,
        companions: COMPANIONS,
    });

    // A companion that does not exist yet is a file to CREATE, and the builder
    // prompt marks the two differently. Telling a builder an absent test file
    // already exists is a small lie that costs it a confused read of the tree.
    const exists = (f) => tracked.includes(f);

    items.push(assertScope({
        id,
        source,
        severity: severity ?? "medium",
        title,
        detail: textOf(detail),
        files: merged.filter(exists),
        newFiles: [...new Set([...(o.newFiles ?? []), ...merged.filter((f) => !exists(f))])].sort(),
        scope: o.scope ?? (merged.length ? "bounded" : "unscoped"),
        scopeNote: o.note ?? null,
        dispatchable: o.dispatchable ?? !["external", "duplicate", "needs-design", "held"].includes(o.scope),
        mapRef: o.mapRef ?? null,
        // Set this from whatever in your map means "this work IS a new migration"
        // — it drives the migration lane in harness.config.json.
        needsNewMigration: o.needsNewMigration ?? false,
        ...extra,
    }));
}

// EXAMPLE — replace with your map's actual sections:
//
// for (const d of map.openDebt.high ?? []) {
//     push({ id: d.id, source: "openDebt.high", severity: "high",
//            title: d.summary, detail: d });
// }
// for (const w of map.plannedWork.backlog ?? []) {
//     push({ id: `pw:${w.n}`, source: "plannedWork.backlog", severity: "medium",
//            title: w.what, detail: w, extra: { mapRef: w.ref ?? null } });
// }

// ── merge, report, write ─────────────────────────────────────────────────────

const existing = existsSync(QUEUE_PATH) ? JSON.parse(readFileSync(QUEUE_PATH, "utf8")) : null;
const { items: mergedItems, vanished } = mergeQueueState(items, existing);
const collisions = collisionReport(mergedItems);

const counts = {};
for (const i of mergedItems) {
    counts[i.status] = (counts[i.status] ?? 0) + 1;
}

const queue = {
    $comment: "SPRINT STATE. Generated from the map; status/batch/notes survive a rebuild. Do not hand-edit the derived fields.",
    generatedFrom: cfg.map.path,
    counts,
    collisions,
    items: mergedItems,
};

if (WRITE) {
    writeFileSync(QUEUE_PATH, JSON.stringify(queue, null, 2) + "\n");
    console.log(`wrote ${cfg.queue.path}`);
} else {
    console.log(`(dry run — pass --write to update ${cfg.queue.path})`);
}

console.log(`items      : ${mergedItems.length}  ${JSON.stringify(counts)}`);
console.log(`collisions : ${collisions.length} file(s) claimed by more than one OPEN item`);
for (const c of collisions.slice(0, 15)) console.log(`  ${c.file}  ${c.items.join(", ")}`);

if (vanished.length) {
    console.log(`\nVANISHED from the map (${vanished.length}) — renamed id, or closed without evidence:`);
    for (const v of vanished) console.log(`  ${v.id}  (was ${v.status})`);
}

// The regex SUGGESTS; it does not get to quietly decide what collides. Anything
// it could not resolve — and anything path-shaped it was not configured to see —
// is printed rather than dropped.
const unknownExt = problems.filter((p) => p.unknownExtension);
const unresolved = problems.filter((p) => !p.unknownExtension);

if (unresolved.length) {
    console.log(`\nUNRESOLVED / AMBIGUOUS citations (${unresolved.length}) — each is a hole in the collision graph:`);
    for (const p of unresolved.slice(0, 20)) {
        console.log(`  [${p.item}] ${p.cited}  ${p.ambiguous ? `AMBIGUOUS -> ${p.ambiguous.join(" | ")}` : "unresolved"}`);
    }
    console.log("  Fix by adding an alias, a dirHint, or an OVERRIDES files entry.");
}

if (unknownExt.length) {
    const exts = [...new Set(unknownExt.map((p) => p.unknownExtension))].sort();
    console.log(`\n⚠ INVISIBLE FILE TYPES (${unknownExt.length} path(s), ${exts.length} extension(s)):`);
    console.log(`  These paths are TRACKED IN GIT and cited by an item, but their extension is`);
    console.log(`  not in extract.fileExtensions — so the collision graph cannot see them, and`);
    console.log(`  two items editing one of them would be fanned out in PARALLEL.`);
    for (const p of unknownExt.slice(0, 20)) {
        console.log(`  [${p.item}] ${p.resolved}  (.${p.unknownExtension})`);
    }
    console.log(`\n  Fix in .claude/harness.config.json, NOT in core/:`);
    console.log(`      "extract": { "fileExtensions": [${exts.map((e) => `"${e}"`).join(", ")}, ...] }`);
    console.log(`  (list the full set you want, including the source extensions you already rely on)`);
}
