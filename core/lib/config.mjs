//
// Config loader for sprint-harness.
//
// One job: turn harness.config.json into a fully-defaulted object, and REFUSE
// to run on a config that would silently weaken a guarantee. Every check below
// exists because the corresponding mistake is invisible at runtime — a harness
// with no anchors still reports green nodes, and a queue path that points at
// nothing still produces a plan.
//
// Resolution order for the config file:
//   1. $SPRINT_HARNESS_CONFIG
//   2. <repo root>/.claude/harness.config.json
//   3. <repo root>/harness.config.json
//
// Repo root is discovered with `git rev-parse --show-toplevel`, so any of these
// work from any subdirectory.

import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve, dirname } from "node:path";

export function repoRoot(from = process.cwd()) {
    try {
        return execFileSync("git", ["rev-parse", "--show-toplevel"], {
            cwd: from, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
        }).trim();
    } catch {
        throw new Error("sprint-harness: not inside a git repository");
    }
}

export function configPath(root = repoRoot()) {
    const candidates = [
        process.env.SPRINT_HARNESS_CONFIG,
        resolve(root, ".claude/harness.config.json"),
        resolve(root, "harness.config.json"),
    ].filter(Boolean);

    for (const c of candidates) if (existsSync(c)) return c;

    throw new Error(
        "sprint-harness: no harness.config.json found. Looked at:\n" +
        candidates.map((c) => `  ${c}`).join("\n") +
        "\nRun the installer, or copy examples/<stack>.harness.config.json into .claude/.",
    );
}

// Defaults live HERE and nowhere else. A default duplicated into a consumer is
// a default that will drift.
const DEFAULTS = {
    project: { worktree: null, mainBranch: "main", remote: "origin" },
    map: null,
    queue: { path: ".claude/work/QUEUE.json", writeOnlyFrom: null },
    // `fileExtensions: null` means "use DEFAULT_EXTENSIONS from core/lib/extract.mjs".
    // Set it for a repo whose work is not application source — a content site
    // needs md/mdx/svg/png, and without them its collisions are invisible.
    extract: { fileExtensions: null },
    setup: [],
    // Commands that REBUILD a generated file from its sources. integrate.sh runs
    // them after merging a wave and before the merged-tree anchors.
    //
    // A generated file is the paired artifact of every file that feeds it, and
    // no file list can name it: most edits to a source do not move it, so a
    // pairedArtifacts rule demanding it on every node would be noise that gets
    // waived by habit. It belongs here, once, at the point where the whole batch
    // exists in one tree.
    regenerate: [],
    lanes: [],
    pairedArtifacts: [],
    verify: { lenses: ["intent", "invariants", "anchors"], requireAllLenses: true },
    git: {
        denyPush: true,
        denyPushReason: null,
        stackBranches: true,
        excludeFromStacking: [],
        prePushGuard: null,
    },
    agents: { builder: "sprint-builder", verifier: "sprint-verifier" },
    branchPrefix: "sprint",
};

const merge = (base, over) => {
    if (over == null) return base;
    if (Array.isArray(base) || typeof base !== "object") return over;
    const out = { ...base };
    for (const [k, v] of Object.entries(over)) {
        out[k] = k in base && base[k] && typeof base[k] === "object" && !Array.isArray(base[k])
            ? merge(base[k], v)
            : v;
    }
    return out;
};

export function loadConfig(opts = {}) {
    const root = opts.root ?? repoRoot();
    const path = opts.path ?? configPath(root);
    let raw;
    try {
        raw = JSON.parse(readFileSync(path, "utf8"));
    } catch (e) {
        throw new Error(`sprint-harness: ${path} is not valid JSON — ${e.message}`);
    }

    const cfg = merge(DEFAULTS, raw);
    cfg.$root = root;
    cfg.$path = path;

    validate(cfg);
    return cfg;
}

// Refusals, not warnings. A warning on a config error gets scrolled past, and
// the run that follows it produces a report that looks exactly like a good one.
function validate(cfg) {
    const die = (msg) => { throw new Error(`sprint-harness: ${cfg.$path}: ${msg}`); };

    if (!cfg.project?.name) die("project.name is required");
    if (!cfg.project?.mainBranch) die("project.mainBranch is required");
    if (!cfg.queue?.path) die("queue.path is required");

    if (!Array.isArray(cfg.anchors) || cfg.anchors.length === 0) {
        die(
            "at least one anchor is required.\n" +
            "  An anchor is a command whose EXIT CODE the builder reports and an independent\n" +
            "  verifier re-runs. With zero anchors the verify step degrades to models agreeing\n" +
            "  with each other, which is the exact failure this harness exists to prevent.",
        );
    }

    const ids = new Set();
    for (const a of cfg.anchors) {
        if (!a.id || !a.cmd) die(`every anchor needs an id and a cmd (got ${JSON.stringify(a)})`);
        if (!/^[a-zA-Z][a-zA-Z0-9]*$/.test(a.id)) {
            die(`anchor id ${JSON.stringify(a.id)} must be a bare word — it becomes a JSON schema key`);
        }
        if (ids.has(a.id)) die(`duplicate anchor id ${JSON.stringify(a.id)}`);
        ids.add(a.id);
    }

    const ext = cfg.extract?.fileExtensions;
    if (ext != null) {
        if (!Array.isArray(ext) || !ext.length) {
            die("extract.fileExtensions must be a non-empty array, or absent to use the defaults");
        }
        for (const e of ext) {
            if (typeof e !== "string" || !/^[A-Za-z][A-Za-z0-9]*$/.test(e)) {
                die(`extract.fileExtensions: ${JSON.stringify(e)} is not a bare extension — ` +
                    `write "md", not ".md" or "*.md"`);
            }
        }
    }

    for (const r of cfg.regenerate) {
        if (!r?.cmd) die(`every regenerate entry needs a cmd (got ${JSON.stringify(r)})`);
    }

    for (const l of cfg.lanes) {
        if (!l.id || !l.itemFlag || !l.why) die(`lane ${JSON.stringify(l.id ?? l)} needs id, itemFlag and why`);
    }

    for (const p of cfg.pairedArtifacts) {
        if (!p.pairPath?.includes("{name}")) {
            die(`pairedArtifacts[${p.id}].pairPath must contain {name}`);
        }
    }

    if (!cfg.verify.lenses.length) die("verify.lenses cannot be empty");
    if (new Set(cfg.verify.lenses).size !== cfg.verify.lenses.length) {
        die("verify.lenses must be distinct — duplicate lenses are redundant reviewers, not independent questions");
    }
}

// The slice of config the WORKFLOW needs.
//
// Workflow scripts have no filesystem access, so they cannot read the config
// themselves. plan-batch.mjs embeds this into the plan JSON and the workflow
// reads it from `args`. Keep it small and serialisable — it travels through a
// tool-call boundary that has mangled smart quotes and raw angle brackets
// before.
export function workflowSlice(cfg) {
    return {
        anchors: cfg.anchors.map((a) => ({
            id: a.id,
            cmd: a.cmd,
            cwd: a.cwd ?? ".",
            always: a.always !== false,
            whenTouches: a.whenTouches ?? null,
            // Take a host-wide lock around this anchor, so a wide fan-out cannot
            // starve it into a timeout and then report that as a code failure.
            serialize: a.serialize === true,
        })),
        setup: cfg.setup.map((s) => ({ cmd: s.cmd, cwd: s.cwd ?? ".", why: s.why ?? null })),
        lenses: cfg.verify.lenses,
        requireAllLenses: cfg.verify.requireAllLenses !== false,
        // OPTIONAL. Null unless a project pins one, and the graph spreads it
        // only when truthy, so the default path passes no model key at all and
        // every verifier inherits the main loop exactly as before.
        verifierModel: cfg.verify.model ?? null,
        // OPTIONAL, DEFAULT OFF, and it DOUBLES the verifier spend when on.
        // `=== true` rather than `!== false`, because a mechanism that costs a
        // second full verification wave must be switched on deliberately and
        // never arrive through a typo or a missing key.
        confirmAccepted: cfg.verify.confirmAccepted === true,
        agents: cfg.agents,
        branchPrefix: cfg.branchPrefix,
        mainBranch: cfg.project.mainBranch,
        // Where install.sh puts core/. The builder and the anchors lens both shell
        // out to the scope gate, and a Workflow script cannot look it up.
        scopeGate: ".claude/harness-core/scope-gate.sh",
        // Same reason as scopeGate: an anchor with `serialize: true` is rendered
        // into an agent prompt wrapped in this, and a Workflow script cannot look
        // a path up on disk.
        serializer: ".claude/harness-core/serialize.sh",
        pairedArtifacts: cfg.pairedArtifacts.map((p) => ({ id: p.id, srcDir: p.srcDir })),
    };
}
