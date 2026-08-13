//
// Reusable machinery for building a QUEUE from a MAP.
//
// The part that is genuinely project-agnostic is not "reading your map" — it is
// everything around it:
//
//   resolveCited()   turn a loose file citation into a real repo-relative path,
//                    and REPORT what did not resolve instead of guessing
//   citedFiles()     scrape file paths out of prose
//   mergeQueueState() preserve sprint state across a rebuild
//   collisionReport() show which files more than one open item claims
//
// Walking YOUR map's shape is the ~40 lines you write. See
// templates/extract-queue.mjs for the skeleton.
//
// The whole module is deliberately PLAIN CODE with no model in it. The `files`
// array it derives is what the partitioner uses to detect collisions, and a
// collision missed here becomes two agents editing one file in separate
// worktrees. That decision must be deterministic and reviewable, not inferred.

import { execFileSync } from "node:child_process";

// ── file resolution ──────────────────────────────────────────────────────────

export function trackedFiles(root, { exclude = [] } = {}) {
    return execFileSync("git", ["ls-files"], { cwd: root, encoding: "utf8" })
        .split("\n")
        .filter(Boolean)
        .filter((p) => !exclude.some((x) => p.startsWith(x) || p.endsWith(x)));
}

export function buildResolver(tracked, { aliases = {}, dirHints = [] } = {}) {
    const byBasename = new Map();
    for (const p of tracked) {
        const base = p.split("/").pop();
        if (!byBasename.has(base)) byBasename.set(base, []);
        byBasename.get(base).push(p);
    }

    // Resolve a citation like "OrderActions.tsx:277", "web/lib/actions.ts:446",
    // "_shared/opportunity.ts:24" or "app/(app)/calculator/actions.ts:26-29"
    // to a real repo-relative path.
    //
    // Returns { path } or { ambiguous: [...] } or { unresolved: true }.
    // AMBIGUOUS IS NOT AN ERROR TO SWALLOW. A bare basename matching three files
    // means the collision graph has a hole in it exactly where you cannot see it.
    return function resolveCited(cited, context = "") {
        const clean = String(cited).split(":")[0].trim().replace(/^\.?\//, "");
        if (!clean) return { unresolved: true };

        if (tracked.includes(clean)) return { path: clean };
        if (aliases[clean]) return { path: aliases[clean] };

        // A partial path: match on suffix, which handles "_shared/opportunity.ts"
        // and "app/(app)/calculator/actions.ts" without needing an alias each.
        if (clean.includes("/")) {
            const hits = tracked.filter((p) => p === clean || p.endsWith("/" + clean));
            if (hits.length === 1) return { path: hits[0] };
            if (hits.length > 1) return { ambiguous: hits, cited: clean, context };
            return { unresolved: true, cited: clean, context };
        }

        const hits = byBasename.get(clean) ?? [];
        if (hits.length === 1) return { path: hits[0] };
        if (hits.length > 1) {
            // A directory hint from the surrounding prose can disambiguate a
            // basename that appears once per module (index.ts, mod.rs, main.go).
            for (const hint of dirHints) {
                if (!context.includes(hint.mention)) continue;
                const narrowed = hits.filter((p) => p.startsWith(hint.dir));
                if (narrowed.length === 1) return { path: narrowed[0] };
            }
            return { ambiguous: hits, cited: clean, context };
        }
        return { unresolved: true, cited: clean, context };
    };
}

// Matches most source paths in prose. Extend the extension list for your stack —
// a path whose extension is missing here is a file the collision graph cannot
// see.
export const FILE_RE =
    /\b((?:[\w.()\[\]@-]+\/)*[\w.()\[\]@-]+\.(?:tsx?|jsx?|mjs|mts|cjs|go|py|rs|rb|java|kt|swift|c|cc|cpp|h|hpp|sql|sh|ya?ml|json|css|scss|toml|proto))\b/g;

export function citedFiles(text, resolve) {
    const out = new Set();
    const problems = [];
    for (const m of String(text).matchAll(FILE_RE)) {
        const r = resolve(m[1], text);
        if (r.path) out.add(r.path);
        else problems.push(r);
    }
    return { files: [...out].sort(), problems };
}

// ── state preservation ───────────────────────────────────────────────────────
//
// A rebuild must NEVER lose sprint state. `status`, `batch` and `notes` are the
// record of what actually happened; the map is the record of what is true about
// the code. Re-deriving the second must not overwrite the first.
//
// Ids that vanished from the map are REPORTED, never silently dropped — a
// disappearing item is either a renamed id (fix the map) or work that was
// quietly closed without evidence (worth knowing).
const PRESERVED = ["status", "batch", "notes", "closedIn", "closedOn", "owner"];

export function mergeQueueState(freshItems, existingQueue) {
    const prior = new Map((existingQueue?.items ?? []).map((i) => [i.id, i]));
    const seen = new Set();

    const items = freshItems.map((item) => {
        const old = prior.get(item.id);
        seen.add(item.id);
        const merged = { status: "open", batch: null, notes: null, ...item };
        if (old) for (const k of PRESERVED) if (old[k] != null) merged[k] = old[k];
        return merged;
    });

    const vanished = [...prior.values()]
        .filter((i) => !seen.has(i.id))
        .map((i) => ({ id: i.id, status: i.status, why: "present in the previous queue, absent from the map now" }));

    return { items, vanished };
}

// ── collision report ─────────────────────────────────────────────────────────
//
// The reason `files` exists at all. This is what you read BEFORE dispatching:
// every file claimed by more than one OPEN item is a place where a careless
// batch selection would fan two agents at one file.
export function collisionReport(items) {
    const touch = new Map();
    for (const i of items) {
        if (i.status !== "open") continue;
        for (const f of [...(i.files ?? []), ...(i.newFiles ?? [])]) {
            if (!touch.has(f)) touch.set(f, []);
            touch.get(f).push(i.id);
        }
    }
    return [...touch.entries()]
        .filter(([, ids]) => ids.length > 1)
        .map(([file, ids]) => ({ file, items: ids.sort() }))
        .sort((a, b) => b.items.length - a.items.length || a.file.localeCompare(b.file));
}

// ── scope taxonomy ───────────────────────────────────────────────────────────
//
// THE ONLY QUESTION that decides whether an item is dispatchable:
//
//   Can a human name the exact files this item will touch TODAY, without
//   designing anything first?
//
// It is NOT "is this important" or "do we understand it". It is "can the
// partitioner guarantee no two agents collide". Everything that cannot answer it
// gets a scope that keeps it OUT of a fan-out until someone does the missing work.
export const SCOPES = {
    bounded: "files are known — dispatchable",
    "repo-wide": "real but unbounded; runs ALONE in its own wave",
    unscoped: "no files derivable — REFUSED until pinned in OVERRIDES",
    "needs-design": "WHERE the code goes is itself the open question. Scoping IS the work — do it as a planning item, then it becomes bounded",
    external: "the truth lives outside this repo. Never dispatch a builder at it — it would produce confident fiction",
    duplicate: "another id already tracks it; dispatching both is two agents on one fix",
    held: "BUILDABLE — files known, nothing technical blocks it — but a human decided it must not ship yet. The note MUST record who held it and what releases it, or it rots into a permanent block nobody remembers how to lift",
};

export function assertScope(item) {
    if (!SCOPES[item.scope]) {
        throw new Error(
            `queue item ${item.id}: unknown scope ${JSON.stringify(item.scope)}. ` +
            `Valid: ${Object.keys(SCOPES).join(", ")}`,
        );
    }
    if (item.scope === "held" && !item.notes && !item.scopeNote) {
        throw new Error(
            `queue item ${item.id}: scope "held" requires a note saying WHO held it and WHAT releases it. ` +
            `Without that it rots into a permanent block nobody remembers how to lift.`,
        );
    }
    return item;
}
