#!/usr/bin/env node
//
// Partition queue items into NODES that are safe to run in parallel.
//
//     node core/plan-batch.mjs --auto 8
//     node core/plan-batch.mjs item-a item-b item-c
//     node core/plan-batch.mjs --auto 8 --json     # for the Workflow args parameter
//
// PROJECT-AGNOSTIC. Everything it needs to know about your repo comes from
// harness.config.json and QUEUE.json.
//
// This is the REDUCE step of the whole system, and it is deliberately PLAIN CODE
// WITH NO MODEL IN IT. "False independence" — two agents that look unrelated
// because their prompts never mention each other, but which write the same file
// — is the single most likely way a fan-out corrupts a repo. That call must be
// deterministic and reviewable, not inferred.
//
// Rules, in order:
//   1. Two items sharing ANY file are the same node, run serially inside it.
//      Transitively: A-B share x, B-C share y => A, B and C are one node.
//   1b. A declared cross-reference between two SELECTED items is a collision
//      edge too — they are routinely one job described twice.
//   2. Any item flagged for a configured LANE joins that lane's single node.
//   3. scope:"repo-wide" items get an exclusive node in their own wave.
//   4. scope:"unscoped" items are REFUSED — no files means no guarantee.
//
// Output is consumed by core/sprint-batch.mjs through the Workflow `args`
// parameter. Workflow scripts have no filesystem access, so both the partition
// AND the harness config slice have to be computed out here and handed in.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { loadConfig, workflowSlice } from "./lib/config.mjs";

const cfg = loadConfig();
const queuePath = resolve(cfg.$root, cfg.queue.path);

let queue;
try {
    queue = JSON.parse(readFileSync(queuePath, "utf8"));
} catch (e) {
    console.error(`error: cannot read queue at ${queuePath}\n       ${e.message}`);
    process.exit(1);
}

const argv = process.argv.slice(2);
const JSON_OUT = argv.includes("--json");
const autoIdx = argv.indexOf("--auto");
const AUTO = autoIdx >= 0 ? Number(argv[autoIdx + 1] ?? 8) : null;
const explicitIds = argv.filter((a, i) =>
    !a.startsWith("--") && !(autoIdx >= 0 && i === autoIdx + 1));

const byId = new Map(queue.items.map((i) => [i.id, i]));
const laneFlags = cfg.lanes.map((l) => l.itemFlag);

// ── select ───────────────────────────────────────────────────────────────────
let selected;
if (AUTO != null) {
    // Auto mode proposes the CHEAPEST safe batch: bounded scope, no lane, still
    // open, fewest files first. It is a starting point for a human, not a
    // decision — the whole point of printing the partition is that you read it.
    selected = queue.items
        .filter((i) => i.status === "open" && i.scope === "bounded")
        .filter((i) => !laneFlags.some((f) => i[f]))
        .sort((a, b) => (a.files?.length ?? 0) - (b.files?.length ?? 0) || a.id.localeCompare(b.id))
        .slice(0, AUTO);
} else {
    selected = explicitIds.map((id) => {
        const it = byId.get(id);
        if (!it) {
            console.error(`error: no queue item with id ${JSON.stringify(id)}`);
            process.exit(1);
        }
        return it;
    });
}

if (!selected.length) {
    console.error("error: nothing selected. Pass ids, or --auto N.");
    process.exit(1);
}

// ── refuse what cannot be safely dispatched ──────────────────────────────────
// Refusing is the point, not a limitation. An item with no known file set has no
// collision guarantee; an item whose SURFACE is still an open question would have
// a builder invent one; an item whose truth lives outside this repo would have a
// builder invent facts. Each refusal carries its own reason so the fix is obvious.
const WHY_REFUSED = {
    unscoped: "no files derivable — pin them in the extractor's OVERRIDES table first",
    "needs-design": "WHERE the code goes is still the open question — do it as a planning item, then it becomes bounded",
    external: "the truth lives outside this repo — a builder would produce confident fiction",
    duplicate: "another queue id already tracks this work — dispatch that one instead",
    held: "buildable, but a human decided it must not ship yet — the note says who held it and what releases it",
    done: "already closed by earlier work",
};
const isRefused = (i) => i.dispatchable === false || i.scope === "unscoped";
const refused = selected.filter(isRefused);
selected = selected.filter((i) => !isRefused(i));

if (!selected.length) {
    console.error(`error: every selected item was refused (${refused.length}).`);
    for (const r of refused) {
        console.error(`  [${r.scope}] ${r.id} — ${WHY_REFUSED[r.scope] ?? "not dispatchable"}`);
    }
    process.exit(1);
}

// ── partition ────────────────────────────────────────────────────────────────
// Union-find over shared files. newFiles counts: two items that both CREATE
// components/Combobox.tsx collide exactly as hard as two that edit actions.ts.
const parent = new Map(selected.map((i) => [i.id, i.id]));
const find = (x) => (parent.get(x) === x ? x : (parent.set(x, find(parent.get(x))), parent.get(x)));
const union = (a, b) => { const ra = find(a), rb = find(b); if (ra !== rb) parent.set(ra, rb); };

const filesOf = (i) => [...(i.files ?? []), ...(i.newFiles ?? [])];

const owners = new Map();
for (const item of selected) {
    for (const f of filesOf(item)) {
        if (owners.has(f)) union(owners.get(f), item.id);
        else owners.set(f, item.id);
    }
}

// Rule 1b: a declared cross-reference is a collision edge too.
//
// An item and the audit section it cites are routinely ONE job described twice.
// Shared files usually catch these, but not always — the two descriptions can
// cite completely different files while meaning the same fix, and the file graph
// then sees them as independent and fans two builders out at the same work.
//
// Deliberately conservative: an edge only forms when the ref matches the id of
// another SELECTED item EXACTLY. Many refs point at document sections rather
// than items, and those must not fabricate edges.
const refEdges = [];
for (const item of selected) {
    if (!item.mapRef) continue;
    for (const raw of String(item.mapRef).split(/[,\s]+/)) {
        const ref = raw.trim();
        if (!ref || ref === item.id) continue;
        if (!parent.has(ref)) continue;
        if (find(ref) !== find(item.id)) refEdges.push([item.id, ref]);
        union(item.id, ref);
    }
}

// Rule 2: configured lanes. Each lane collapses to ONE serial node regardless of
// files, because the resource they contend for is not a file — it is a numbering
// sequence, a lock, a singleton registry. A merge cannot resolve that collision.
const laneOf = new Map();
for (const lane of cfg.lanes) {
    const members = selected.filter((i) => i[lane.itemFlag]);
    if (members.length > 1) for (const m of members.slice(1)) union(members[0].id, m.id);
    for (const m of members) laneOf.set(m.id, lane);
}

// Rule 3: repo-wide items are exclusive and handled below, outside the groups.
const groups = new Map();
for (const item of selected) {
    if (item.scope === "repo-wide") continue;
    const root = find(item.id);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root).push(item);
}

function sharedFiles(members) {
    const count = new Map();
    for (const m of members) for (const f of filesOf(m)) count.set(f, (count.get(f) ?? 0) + 1);
    return [...count.entries()].filter(([, n]) => n > 1).map(([f]) => f);
}

// Why these items ended up in one node. A ref edge or a lane can group items
// that share NO file, so reporting only shared files would print a bare
// "shares " and hide the real reason the planner refused to parallelise them.
function groupReason(members) {
    const ids = new Set(members.map((m) => m.id));
    const lane = members.map((m) => laneOf.get(m.id)).find(Boolean);
    const shared = sharedFiles(members);
    const refs = refEdges
        .filter(([a, b]) => ids.has(a) && ids.has(b))
        .map(([a, b]) => `${a} refs ${b}`);
    return [
        lane ? `${lane.id} lane — ${lane.why}` : null,
        shared.length ? `shares ${shared.join(", ")}` : null,
        refs.length ? `declared same job — ${refs.join("; ")}` : null,
    ].filter(Boolean).join("; ") || "grouped";
}

const nodes = [];
for (const [, members] of groups) {
    nodes.push({
        nodeId: members.map((m) => m.id).join(" + "),
        items: members.map((m) => ({
            id: m.id, title: m.title, source: m.source, severity: m.severity,
            files: m.files ?? [], newFiles: m.newFiles ?? [], detail: m.detail,
        })),
        files: [...new Set(members.flatMap(filesOf))].sort(),
        serial: members.length > 1,
        exclusive: false,
        lane: members.map((m) => laneOf.get(m.id)?.id).find(Boolean) ?? null,
        reason: members.length > 1 ? groupReason(members) : "independent",
    });
}

for (const item of selected.filter((i) => i.scope === "repo-wide")) {
    nodes.push({
        nodeId: item.id,
        items: [{
            id: item.id, title: item.title, source: item.source, severity: item.severity,
            files: item.files ?? [], newFiles: item.newFiles ?? [], detail: item.detail,
        }],
        // filesOf, NOT item.files. node.files becomes the builder's "files this
        // node owns — do not edit anything else" list, so dropping newFiles here
        // hands a builder an item that says CREATE this file inside a prompt that
        // forbids touching it. The grouped path above has always used filesOf;
        // this branch was written separately and never picked it up, so the bug
        // reached repo-wide items ONLY — the rarest kind, and the ones least
        // likely to expose it, because a repo-wide node already touches files the
        // queue could not enumerate. Found 2026-08-14, brian-chastain batch 1.
        files: [...new Set(filesOf(item))].sort(),
        serial: false,
        exclusive: true,
        lane: null,
        reason: `repo-wide — ${item.scopeNote ?? "rewrites a convention across files the queue cannot enumerate"}`,
    });
}

nodes.sort((a, b) => Number(a.exclusive) - Number(b.exclusive) || a.nodeId.localeCompare(b.nodeId));

// ── waves ────────────────────────────────────────────────────────────────────
// An exclusive node is only safe if something actually SEQUENCES it. Exclusivity
// BYPASSES the union-find above, so a repo-wide item can share a file with a
// parallel node and the grouping will not have caught it.
//
// Encoding the wave here rather than leaving it to the runner means the workflow
// cannot get it wrong: every node in wave N runs concurrently, and wave N+1 does
// not start until N is merged. Wave 0 is the fan-out; each exclusive node then
// takes a wave of its own.
let wave = 0;
for (const n of nodes) {
    if (!n.exclusive) { n.wave = 0; continue; }
    n.wave = ++wave;
}
const waveCount = wave + 1;

const plan = {
    generatedFrom: cfg.queue.path,
    project: cfg.project.name,
    itemCount: selected.length,
    nodeCount: nodes.length,
    waveCount,
    parallelWidth: nodes.filter((n) => n.wave === 0).length,
    refused: refused.map((r) => ({
        id: r.id, scope: r.scope,
        why: WHY_REFUSED[r.scope] ?? "not dispatchable",
        note: r.scopeNote ?? null,
    })),
    nodes,
    // The workflow has no filesystem. Everything it needs about this project
    // rides along in the plan.
    harness: workflowSlice(cfg),
};

// Cross-wave file overlaps are expected and SAFE (they are sequenced), but the
// human reading this plan should still see them — a shared file across waves
// means the second agent edits a file the first one just changed.
const fileWaves = new Map();
for (const n of nodes) for (const f of n.files) {
    if (!fileWaves.has(f)) fileWaves.set(f, new Set());
    fileWaves.get(f).add(n.wave);
}
plan.crossWaveFiles = [...fileWaves.entries()]
    .filter(([, w]) => w.size > 1)
    .map(([file, w]) => ({ file, waves: [...w].sort() }));

// ── output ───────────────────────────────────────────────────────────────────
if (JSON_OUT) {
    console.log(JSON.stringify(plan, null, 2));
} else {
    console.log(`project        : ${cfg.project.name}`);
    console.log(`items selected : ${plan.itemCount}`);
    console.log(`nodes          : ${plan.nodeCount}  in ${waveCount} wave(s), fan-out width ${plan.parallelWidth}`);
    if (refused.length) {
        console.log(`\nREFUSED (${refused.length}) — not safe to dispatch:`);
        for (const r of plan.refused) console.log(`  [${r.scope}] ${r.id}\n      ${r.why}`);
    }
    for (let w = 0; w < waveCount; w++) {
        const inWave = nodes.filter((n) => n.wave === w);
        console.log(`\n── wave ${w} ${w === 0 ? "(fan out, all at once)" : `(runs alone, after wave ${w - 1} merges)`} ──`);
        for (const n of inWave) {
            const tag = n.exclusive ? "EXCLUSIVE" : n.serial ? "SERIAL  " : "parallel";
            console.log(`\n  [${tag}] ${n.nodeId}`);
            console.log(`     why   : ${n.reason}`);
            for (const it of n.items) console.log(`     item  : ${it.id}  ${String(it.title).slice(0, 90)}`);
            for (const f of n.files) console.log(`     file  : ${f}`);
        }
    }
    if (plan.crossWaveFiles.length) {
        console.log(`\nfiles touched in more than one wave (sequenced, but read the second diff carefully):`);
        for (const c of plan.crossWaveFiles) console.log(`  ${c.file}  waves ${c.waves.join(" -> ")}`);
    }
    console.log(`\n(add --json to emit the plan for the Workflow args parameter)`);
}
