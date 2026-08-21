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

// The extensions the scraper can see. THIS LIST IS THE PARTITIONER.
//
// Union-find is the easy half and it is correct given its edges. The edges come
// from scraping prose, so an extension missing from this list is a file the
// collision graph cannot see — and the dangerous case is not the item with NO
// visible paths (that scores `unscoped` and gets refused). It is the PARTIAL
// one: an item touching `docs/guide.md` and `src/nav.ts` scrapes the `.ts`,
// scores `bounded`, and ships a confident node with an invisible `.md`
// collision inside it.
//
// The default covers a typical application stack. A content site, a docs repo or
// a design-asset repo needs its OWN list — set `extract.fileExtensions` in
// harness.config.json rather than editing core/.
export const DEFAULT_EXTENSIONS = [
    "tsx", "ts", "jsx", "js", "mjs", "mts", "cjs",
    "go", "py", "rs", "rb", "java", "kt", "swift",
    "c", "cc", "cpp", "h", "hpp",
    "sql", "sh", "yaml", "yml", "json", "css", "scss", "toml", "proto",
];

const PATH_BODY = String.raw`(?:[\w.()\[\]@-]+\/)*[\w.()\[\]@-]+`;

// The left edge of a path. NOT `\b`, and that distinction cost a real project a
// per-repo alias table.
//
// `\b` is a boundary between a word character and a non-word character. A path
// that STARTS with a dot-directory — `.github/workflows/ci.yml` — has no word
// character before the dot, so `\b` cannot match there. The regex instead
// started one character later and captured `github/workflows/ci.yml`, which
// resolves against nothing: suffix matching looks for a tracked path ending in
// `/github/workflows/ci.yml` and the real file ends in `/.github/...`.
//
// So every citation of `.github/`, `.claude/`, `.circleci/` or any other
// dot-directory was silently dropped from the collision graph. Silently, because
// the item usually cites other files too, scores `bounded`, and looks confident
// (scar #25's partial-visibility shape, reached by a different route).
//
// A lookbehind for "not already inside a path" does what `\b` was meant to do
// and admits the leading dot. It also stops the regex matching at offset 1 of a
// path it already matched at offset 0.
const LEFT_EDGE = String.raw`(?<![\w./-])`;

export function fileRe(extensions = DEFAULT_EXTENSIONS) {
    // Longest-first so `ts` cannot win the race against `tsx`.
    const alt = [...extensions].sort((a, b) => b.length - a.length).join("|");
    return new RegExp(String.raw`${LEFT_EDGE}(${PATH_BODY}\.(?:${alt}))\b`, "g");
}

// The default instance, kept as a named export for anything already importing it.
export const FILE_RE = fileRe();

// ANY dotted path-like token, whatever the extension. This is not used to build
// the graph — it is used to find the paths the graph could not see, so a missing
// extension becomes a printed line instead of a silent hole. That is the whole
// point: the regex SUGGESTS, and it reports its own blind spots; it does not get
// to quietly decide what collides.
const ANY_PATH_RE = new RegExp(String.raw`${LEFT_EDGE}(${PATH_BODY}\.([A-Za-z][A-Za-z0-9]{0,7}))\b`, "g");

// Extensions that appear constantly in prose without ever meaning "a file in
// this repo". Without this, every version number and every sentence that ends a
// clause with a domain name becomes an unknown-extension warning, and a linter
// that cries wolf is one people stop reading (scar #17).
const NOT_FILES = new Set([
    "com", "org", "net", "io", "dev", "app", "sh", "co", "ai", "gov", "edu",
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "e", "g", "etc", "eg", "ie", "js", // "e.g", "i.e", "Node.js", "vs.js"
]);

export function citedFiles(text, resolve, { extensions = DEFAULT_EXTENSIONS } = {}) {
    const out = new Set();
    const problems = [];
    const known = new Set(extensions.map((e) => e.toLowerCase()));
    const src = String(text);

    const seen = new Set();
    for (const m of src.matchAll(fileRe(extensions))) {
        seen.add(m[1]);
        const r = resolve(m[1], src);
        if (r.path) out.add(r.path);
        else problems.push(r);
    }

    // The linter half: a path-shaped token whose extension is not configured.
    for (const m of src.matchAll(ANY_PATH_RE)) {
        const [, cited, ext] = m;
        if (seen.has(cited)) continue;
        const e = ext.toLowerCase();
        if (known.has(e) || NOT_FILES.has(e)) continue;
        // Only complain if it is actually a file in this repo. A prose mention of
        // `something.unknown` that does not exist is noise; one that IS tracked is
        // a hole in the graph.
        const r = resolve(cited, src);
        if (!r.path) continue;
        problems.push({
            unknownExtension: e, cited, resolved: r.path,
            why: `".${e}" is not in extract.fileExtensions, so this path is INVISIBLE to the ` +
                 `collision graph. Two items editing it would be fanned out in parallel.`,
        });
    }

    return { files: [...out].sort(), problems };
}

// ── companions ───────────────────────────────────────────────────────────────
//
// A file that another file CANNOT MOVE WITHOUT. Applied to whatever the scraper
// already found, never to items it did not find.
//
// THE CONTRADICTION THIS FIXES. `pairedArtifacts` COMPELS a counterpart: change
// a component, ship its test, or the gate exits non-zero. But `files` is scraped
// from citations, and a map entry cites the code it is about — not the test that
// does not exist yet. So the harness demanded a file that no file list granted,
// and the builder's only moves were to fail its own anchor or to edit outside
// its node and be rejected for scope. Watched happen on a live project: the
// builder left scope, wrote the test, and the intent lens correctly rejected the
// node. Every party behaved correctly and the node was still lost.
//
// The counterpart is DERIVED FROM THE SAME RULE THE GATE ENFORCES, not restated,
// so the two cannot drift. If pairPath changes, this follows it.
//
// WHY THIS IS NOT AN `OVERRIDES` ENTRY, and why that distinction is load-bearing:
// an OVERRIDES entry names an ITEM and asserts something a human decided about
// that item's scope. A companion names a FILE RELATIONSHIP that holds for every
// item, forever. It cannot be used to smuggle scope onto work the map cannot
// describe, which is the thing OVERRIDES has to be rationed for.
//
// It makes the graph MORE correct rather than more permissive. Two items editing
// one component already collided; now they also collide on the single test file
// they would both have rewritten.
export function pairedArtifactFor(file, rules = []) {
    const under = (p, dir) => p.startsWith(dir.endsWith("/") ? dir : dir + "/");
    for (const r of rules) {
        if (!r?.pairPath || !r.srcDir) continue;
        if (!under(file, r.srcDir)) continue;
        if (r.srcExt && !file.endsWith(r.srcExt)) continue;
        if ((r.excludeDirs ?? []).some((d) => under(file, d))) continue;
        const base = file.slice(
            file.lastIndexOf("/") + 1,
            r.srcExt ? file.length - r.srcExt.length : undefined,
        );
        return r.pairPath.replace("{name}", base);
    }
    return null;
}

// `companions` is the HAND-SEEDED half: relationships no config can derive.
// A manifest and its lockfile move together or the build breaks. A module and
// the feature-grouped test file that covers it move together or the suite lies.
//
// UNDER-MAPPING IS SAFE, OVER-MAPPING IS NOT. A file absent from the table
// behaves exactly as it does today — the builder stops and says so. A WRONG
// entry puts two builders in one file, which is the failure this module exists
// to prevent. Map only where the relationship is unambiguous.
export function withCompanions(files, { pairedArtifacts = [], companions = {} } = {}) {
    return [...new Set(files.flatMap((f) => {
        const pair = pairedArtifactFor(f, pairedArtifacts);
        return [f, ...(companions[f] ?? []), ...(pair ? [pair] : [])];
    }))].sort();
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
