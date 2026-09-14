#!/usr/bin/env node
//
// CANARY RIG — does a verifier lens actually detect anything?
//
// sprint-batch.mjs says it plainly: "A run where every node is accepted is
// consistent with three working lenses and equally consistent with three that
// are not looking, and nothing else in this system can tell those apart." The
// reduce fixture proves the reduce CLASSIFIES bad input correctly. It does not
// prove any verifier DETECTS anything. This does.
//
// THE TOOL LIVES IN core/. THE RIG DOES NOT, AND THAT IS THE WHOLE POINT.
// The 2026-09-11 control arm caught a verifier grepping the ground-truth
// manifest out of the working tree it was launched from. It disclosed the grep
// and its finding held up independently, but the rig was readable and that
// makes every later arm comparison worthless. Nothing a verifier can reach may
// carry the answers, the patches, or the branch prefix that distinguishes a
// planted node from a real one. Gitignoring is NOT enough — an ignored file is
// still greppable.
//
// So this file is the one thing in core/ that `install.sh` deliberately does
// NOT copy into a project. Everything project-specific lives in a rig
// directory outside every repo under test:
//
//   <rig>/cases.json     what to plant, and the plan nodes to emit. No answers.
//   <rig>/truth.json     which case is a defect, which lens owns it, how a
//                        detection is recognised. Never leaves your machine.
//   <rig>/patches/*      the diffs. Applied in a throwaway worktree.
//
// `truth.json` is optional to everything except `list` and `score`, so the rig
// that plants and plans can be handed to someone who must not see the answers.
//
// The rig is resolved in this order:
//   --rig <dir> | $CANARY_RIG | ~/.claude/canary/<project>
// where <project> is --project | $CANARY_PROJECT | the basename of the git
// toplevel you invoke this from. The repo under test is $CANARY_REPO, else
// `repo` in cases.json.
//
// Usage. The command comes first; --rig and --project may follow any of them.
//
//   canary.mjs list  [--rig <dir>] [--project <name>]
//   canary.mjs plant [--base <ref>] [--force]
//   canary.mjs plan  [--case k1,k4] [--base-branch <ref>] [--confirm]
//                    [--verifier-model <model>] > plan.json
//   canary.mjs score control=results.json [tier2=results2.json ...]
//   canary.mjs clean

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const ARGV = process.argv.slice(2);

// Resolved by loadRig() at dispatch time rather than on import, so an unknown
// command prints usage instead of an error about a rig it was never going to
// read.
let RIG, CASES, TRUTH, ROOT, PREFIX;

function loadRig() {
    RIG = rigDir();
    CASES = readRig("cases.json");
    TRUTH = readRig("truth.json", { optional: true });
    ROOT = process.env.CANARY_REPO ?? CASES.repo
        ?? die(`no repo under test: set CANARY_REPO or "repo" in ` +
               `${join(RIG, "cases.json")}`);
    PREFIX = CASES.branchPrefix
        ?? die(`no "branchPrefix" in ${join(RIG, "cases.json")}`);
}

function rigDir() {
    const explicit = flag(ARGV, "--rig") ?? process.env.CANARY_RIG;
    if (explicit) return resolve(explicit);
    const project = flag(ARGV, "--project") ?? process.env.CANARY_PROJECT
        ?? basename(toplevel());
    return join(homedir(), ".claude", "canary", project);
}

// Only used to NAME the default rig directory. The repo under test comes from
// cases.json or CANARY_REPO, so being in the wrong checkout cannot silently
// redirect a plant.
function toplevel() {
    try {
        return execFileSync("git", ["rev-parse", "--show-toplevel"], {
            encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
        }).trim();
    } catch {
        die("not inside a git repository — name the rig with --rig or " +
            "the project with --project");
    }
}

function readRig(name, { optional = false } = {}) {
    const path = join(RIG, name);
    if (!existsSync(path)) {
        if (optional) return null;
        die(`no ${name} at ${path}. The rig lives outside every repo under ` +
            `test; point at it with --rig or $CANARY_RIG.`);
    }
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch (e) {
        die(`${path} is not valid JSON — ${e.message}`);
    }
}

const needTruth = (cmd) => TRUTH ?? die(
    `${cmd} needs ground truth, and there is no truth.json at ${RIG}. ` +
    `plant, plan and clean do not need it; this does.`);

const truthOf = (id) => TRUTH.truth.find((t) => t.id === id);

// execFileSync returns null for any stream it is told to ignore, so the result
// is normalised here rather than at every call site.
const git = (args, opts = {}) => {
    const out = execFileSync("git", args, { cwd: ROOT, encoding: "utf8", ...opts });
    return out === null ? "" : out.trim();
};

const branchOf = (c) => `${PREFIX}/${c.id}`;
const caseById = (id) => CASES.cases.find((c) => c.id === id);

const branchExists = (name) => {
    try {
        git(["rev-parse", "--verify", "--quiet", `refs/heads/${name}`]);
        return true;
    } catch {
        return false;
    }
};

// ── list ─────────────────────────────────────────────────────────────────────
//
// Prints the TRUTH, because this runs at your terminal and never inside a
// verifier's context. The repo-side artifact is cases.json, which carries none
// of it.

function cmdList() {
    console.log(`rig  ${RIG}`);
    console.log(`repo ${ROOT}\nbase ${CASES.base}   prefix ${PREFIX}/\n`);
    for (const c of CASES.cases) {
        const t = TRUTH ? truthOf(c.id) : null;
        const planted = branchExists(branchOf(c)) ? "planted" : "-";
        const kind = !t ? "?"
            : t.kind === "defect" ? `defect/${t.lens}` : "control";
        console.log(
            `  ${c.id.padEnd(4)} ${kind.padEnd(18)} ${planted.padEnd(8)} ` +
            `${c.item.title}`);
    }
    if (!TRUTH) {
        console.log(`\n${CASES.cases.length} cases, no truth.json in this ` +
                    `rig — kinds unknown here.`);
        return;
    }
    const n = (k) => TRUTH.truth.filter((t) => t.kind === k).length;
    console.log(`\n${n("defect")} defects, ${n("control")} controls`);
}

// ── plant ────────────────────────────────────────────────────────────────────
//
// Every branch is built in a throwaway worktree. The rig must never touch the
// working tree the human is using; a canary run that dirties your checkout is a
// canary run you will stop doing.

function cmdPlant(argv) {
    const base = flag(argv, "--base") ?? CASES.base;
    const force = argv.includes("--force");

    const existing = CASES.cases.filter((c) => branchExists(branchOf(c)));
    if (existing.length && !force) {
        die(`${existing.length} branch(es) already planted ` +
            `(${existing.map(branchOf).join(", ")}). Re-plant with --force, ` +
            `or remove them with \`canary.mjs clean\`.`);
    }

    const baseSha = git(["rev-parse", "--short", base]);
    const tmp = join(ROOT, ".git", "canary-plant");
    git(["worktree", "add", "--detach", tmp, base]);

    const planted = [];
    try {
        for (const c of CASES.cases) {
            const branch = branchOf(c);
            git(["checkout", "-B", branch, base], { cwd: tmp });
            git(["apply", resolve(RIG, c.patch)], { cwd: tmp });
            git(["add", "-A"], { cwd: tmp });
            git(["commit", "-m", commitMessage(c)], { cwd: tmp });
            planted.push({
                branch,
                sha: git(["rev-parse", "--short", "HEAD"], { cwd: tmp }),
            });
        }
    } finally {
        git(["worktree", "remove", "--force", tmp]);
    }

    console.log(`planted ${planted.length} branches from ${base} (${baseSha}):`);
    for (const p of planted) console.log(`  ${p.branch.padEnd(22)} ${p.sha}`);
    console.log(`\nNothing in the working tree was touched.`);
}

// The message must read like a real builder's commit. A canary whose commit
// says "PLANTED DEFECT" is not a test of a verifier, it is a test of whether
// the verifier can read. For the same reason the branch prefix is a plausible
// sprint branch and the ids say nothing about which is which.
const commitMessage = (c) =>
    `fix: ${c.item.title}\n\n${c.item.detail}\n`;

// ── plan ─────────────────────────────────────────────────────────────────────
//
// Emits a plan sprint-batch.mjs accepts, with every node PREBUILT so no builder
// runs. The claimed anchors are all green and are deliberately a claim: the
// whole point is that the anchors lens has nothing to find, so a detection can
// only come from judgment.

async function cmdPlan(argv) {
    const only = flag(argv, "--case")?.split(",").map((s) => s.trim());
    const baseBranch = flag(argv, "--base-branch") ?? CASES.base;

    // The INSTALLED loader in the repo under test, not the one beside this
    // file. A rig that plans with a different version of the config loader
    // than the repo runs with is measuring the wrong harness.
    const loaderPath = join(ROOT, ".claude/harness-core/lib/config.mjs");
    if (!existsSync(loaderPath)) {
        die(`no harness installed at ${ROOT} (looked for ` +
            `.claude/harness-core/lib/config.mjs). Install it there first.`);
    }
    const lib = await import(pathToFileURL(loaderPath).href);
    const cfg = lib.loadConfig({ root: ROOT });
    const harness = lib.workflowSlice(cfg);
    const greenAnchors = Object.fromEntries(harness.anchors.map((a) => [a.id, 0]));

    const cases = only
        ? only.map((id) => caseById(id) ?? die(`no case ${id}`))
        : CASES.cases;

    const missing = cases.filter((c) => !branchExists(branchOf(c)));
    if (missing.length) {
        die(`not planted: ${missing.map(branchOf).join(", ")}. Run \`plant\`.`);
    }

    const nodes = cases.map((c) => ({
        nodeId: c.id,
        items: [{
            id: c.item.id,
            title: c.item.title,
            source: "queue",
            severity: "medium",
            files: c.files,
            newFiles: [],
            detail: c.item.detail,
        }],
        files: [...c.files].sort(),
        serial: false,
        exclusive: false,
        lane: null,
        reason: "independent",
        wave: 0,
        prebuilt: {
            status: "done",
            branch: branchOf(c),
            commit: git(["rev-parse", "--short", branchOf(c)]),
            filesChanged: c.files,
            anchors: greenAnchors,
            scopeGate: 0,
            summary: c.item.title,
        },
    }));

    // Optional second-arm model. Injected into the harness slice rather than
    // harness.config.json, because that schema is additionalProperties:false
    // and `verify` would reject the key. The arm, not the project, owns this.
    const verifierModel = flag(argv, "--verifier-model");
    if (verifierModel) harness.verifierModel = verifierModel;

    // Optional confirm wave, same reasoning: the ARM owns it, not the project.
    // Setting verify.confirmAccepted in the consumer's harness.config.json would
    // double the verifier spend of every real sprint that repo runs, which is a
    // price a rig has no business charging its host.
    if (argv.includes("--confirm")) harness.confirmAccepted = true;

    console.log(JSON.stringify({
        generatedFrom: cfg.queue.path,
        project: cfg.project.name,
        itemCount: nodes.length,
        nodeCount: nodes.length,
        waveCount: 1,
        parallelWidth: nodes.length,
        refused: [],
        nodes,
        harness,
        baseBranch,
        batchName: "batch-qa",
        wave: 0,
    }, null, 2));
}

// ── score ────────────────────────────────────────────────────────────────────
//
// Plain code. No model, no clock, no network. Takes one results file per arm
// and answers three questions: what did each arm catch, what did exactly ONE
// arm catch, and how often did an arm reject a control.
//
// Question two is the whole case for a second runtime. Two arms that both find
// the same defects bought a second opinion three lenses already provide.

function verdictsOf(entry) {
    // Accept either raw verdicts or the reduce report's report[] shape.
    if (Array.isArray(entry.verdicts)) return entry.verdicts;
    const rejects = (entry.rejects ?? []).map((r) => ({ ...r, verdict: "reject" }));
    const passes = (entry.passes ?? []).map((lens) => ({ lens, verdict: "pass" }));
    return [...rejects, ...passes];
}

function scoreArm(results) {
    const rows = Array.isArray(results)
        ? results
        : results.report ?? results.nodes ?? [];
    const byNode = new Map(rows.map((e) => [e.nodeId, e]));

    return CASES.cases.map((c) => {
        const t = truthOf(c.id) ?? die(`no truth for case ${c.id}`);
        const entry = byNode.get(c.id);
        if (!entry) return { id: c.id, kind: t.kind, outcome: "no-result" };

        const verdicts = verdictsOf(entry);
        const rejects = verdicts.filter((v) => v.verdict === "reject");

        if (t.kind === "control") {
            // "clean" means the node was ACCEPTED, not merely un-rejected.
            // A contested lens leaves a control `unverified` with zero rejects,
            // and scoring on rejects alone printed that as clean — which is how
            // arm 5 reported a control the run had declined to accept. Not a
            // false reject (nobody rejected it) and not a pass either, so it
            // gets its own row rather than being folded into either.
            const contested = (entry.contested ?? []).length > 0;
            return {
                id: c.id, kind: t.kind,
                outcome: rejects.length ? "false-reject"
                    : entry.outcome && entry.outcome !== "accepted"
                        ? (contested ? "contested" : `not-accepted/${entry.outcome}`)
                        : "clean",
                lenses: rejects.length
                    ? rejects.map((v) => v.lens)
                    : (entry.contested ?? []).map((x) => `${x.from}->${x.lens}`),
            };
        }

        const hits = rejects.filter((v) => matches(t, v));
        const outcome = hits.length ? "detected"
            : rejects.length ? "reject-unmatched"
            : verdicts.length ? "missed"
            : "no-verdicts";
        const lenses = (hits.length ? hits : rejects).map((v) => v.lens);
        return {
            id: c.id, kind: t.kind, outcome, lenses,
            expectedLens: t.lens,
            // A node saved by a lens that was not the one covering it is a
            // lens-level miss hiding inside a node-level hit. The 2026-09-11
            // control arm had exactly one, and node-level scoring concealed it.
            offTarget: outcome === "detected" && !lenses.includes(t.lens),
        };
    });
}

// Substring match, case-insensitive, over everything the verdict said. Brittle
// on purpose: a transparent rule a human can audit beats a clever one that
// quietly counts a lucky reject as a hit. An unmatched reject is reported as
// its own outcome precisely so nobody has to guess.
function matches(t, verdict) {
    const hay = [...(verdict.evidence ?? []), verdict.confidence ?? ""]
        .join(" \n ").toLowerCase();
    return (t.match ?? []).some((m) => hay.includes(m.toLowerCase()));
}

function cmdScore(argv) {
    needTruth("score");
    const arms = argv.filter((a) => a.includes("=")).map((a) => {
        const [name, file] = a.split("=");
        return { name, rows: scoreArm(JSON.parse(readFileSync(file, "utf8"))) };
    });
    if (!arms.length) die("score needs at least one <arm>=<results.json>");

    const defects = TRUTH.truth.filter((t) => t.kind === "defect");
    const controls = TRUTH.truth.filter((t) => t.kind === "control");

    for (const arm of arms) {
        const by = (o) => arm.rows.filter((r) => r.outcome === o).length;
        console.log(`\n── ${arm.name} ${"─".repeat(Math.max(0, 58 - arm.name.length))}`);
        for (const r of arm.rows) {
            const lens = r.lenses?.length ? `  [${r.lenses.join(", ")}]` : "";
            const off = r.offTarget ? `  OFF-TARGET (expected ${r.expectedLens})` : "";
            console.log(`  ${r.id.padEnd(4)} ${r.outcome.padEnd(17)}${lens}${off}`);
        }
        // `clean` is reported as its own count rather than inferred from
        // controls minus false-rejects: a contested control is neither, and
        // subtracting would silently promote it back to a pass.
        console.log(
            `  detection ${by("detected")}/${defects.length}   ` +
            `off-target ${arm.rows.filter((r) => r.offTarget).length}   ` +
            `false-reject ${by("false-reject")}/${controls.length}   ` +
            `clean ${by("clean")}   contested ${by("contested")}   ` +
            `unmatched ${by("reject-unmatched")}   no-result ${by("no-result")}`);
    }

    if (arms.length < 2) {
        console.log(
            `\nOne arm only — no disjoint analysis. The case for a second ` +
            `runtime is made by defects exactly ONE arm finds, so run at least ` +
            `two arms before drawing a conclusion.`);
        return;
    }

    console.log(`\n── disjoint detections ${"─".repeat(39)}`);
    let anyDisjoint = false;
    for (const t of defects) {
        const found = arms
            .filter((a) => a.rows.find((r) => r.id === t.id)?.outcome === "detected")
            .map((a) => a.name);
        if (found.length === 1) {
            anyDisjoint = true;
            console.log(`  ${t.id}  found ONLY by ${found[0]}`);
        } else if (found.length === 0) {
            console.log(`  ${t.id}  found by NOBODY`);
        }
    }
    if (!anyDisjoint) {
        console.log(
            `  none — every detected defect was found by every arm that found ` +
            `anything.\n  On this sample, a second arm added no coverage.`);
    }

    // The sharper question after a 4/4 control arm: not "more defects", but
    // whether another arm closes a lens-level miss the control arm had.
    console.log(`\n── off-target coverage ${"─".repeat(39)}`);
    for (const t of defects) {
        const off = arms.filter((a) =>
            a.rows.find((r) => r.id === t.id)?.offTarget).map((a) => a.name);
        const on = arms.filter((a) => {
            const r = a.rows.find((x) => x.id === t.id);
            return r?.outcome === "detected" && !r.offTarget;
        }).map((a) => a.name);
        if (off.length && on.length) {
            console.log(`  ${t.id}  off-target for ${off.join(", ")} but ON ` +
                `target for ${on.join(", ")} — the ${t.lens} lens decorrelated`);
        }
    }
}

// ── clean ────────────────────────────────────────────────────────────────────

function cmdClean() {
    const planted = CASES.cases.filter((c) => branchExists(branchOf(c)));
    for (const c of planted) git(["branch", "-D", branchOf(c)]);
    console.log(`removed ${planted.length} branch(es)`);
}

// ── plumbing ─────────────────────────────────────────────────────────────────

function flag(argv, name) {
    const i = argv.indexOf(name);
    return i >= 0 ? argv[i + 1] : undefined;
}

function die(msg) {
    console.error(`canary: ${msg}`);
    process.exit(1);
}

const [cmd, ...rest] = process.argv.slice(2);
const handler = {
    list: cmdList,
    plant: cmdPlant,
    plan: cmdPlan,
    score: cmdScore,
    clean: cmdClean,
}[cmd];
if (!handler) {
    die(`unknown command ${JSON.stringify(cmd ?? "")}. ` +
        `Try: list | plant | plan | score | clean`);
}
loadRig();
await handler(rest);
