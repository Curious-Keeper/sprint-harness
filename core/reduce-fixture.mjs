#!/usr/bin/env node
//
// Exercise the REDUCE step of core/sprint-batch.mjs against known-bad results.
//
//     node core/reduce-fixture.mjs [path/to/sprint-batch.mjs]
//
// WHY THIS FILE EXISTS. The reduce is the only part of the diamond that decides
// what a batch MEANS: accepted vs rejected vs unverified, whether a partial run
// gets reported as complete, and whether the builder's claimed exit codes match
// what an independent agent observed. It is also the part that had no test,
// because a Workflow script cannot be imported — no module loader, no
// filesystem — so selftest.sh could only check that the file parsed.
//
// So this slices the text between the REDUCE markers out of the real file and
// evaluates it. The test runs the SHIPPED code, not a copy, and it costs zero
// agents and zero tokens.
//
// WHAT THIS DOES NOT PROVE. It shows the reduce classifies bad input correctly.
// It does NOT show the lenses detect anything — a verifier that rubber-stamps
// everything produces `pass` verdicts that this file would happily classify as
// accepted. Proving detection needs a live batch with a deliberately broken node
// in it, and that is still owed. See docs/SCARS.md #20.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = process.argv[2] ?? resolve(HERE, "sprint-batch.mjs");

const BEGIN = "// ──REDUCE-BEGIN──";
const END = "// ──REDUCE-END──";

const src = readFileSync(SRC, "utf8");
const i = src.indexOf(BEGIN);
const j = src.indexOf(END);
if (i < 0 || j < 0 || j < i) {
    console.error(
        `reduce-fixture: could not find the REDUCE markers in ${SRC}.\n` +
        `  Expected ${BEGIN} ... ${END}.\n` +
        `  If you moved the reduce, move the markers with it — this test is the only\n` +
        `  thing standing between the outcome classifier and a silent regression.`,
    );
    process.exit(2);
}
const reduceWave = new Function(`${src.slice(src.indexOf("\n", i) + 1, j)}\nreturn reduceWave;`)();

// ── fixtures ─────────────────────────────────────────────────────────────────

const LENSES = ["intent", "invariants", "anchors"];
const ANCHORS = ["typecheck", "test"];
const node = (id) => ({ nodeId: id, items: [{ id }], files: [`src/${id}.ts`] });
const build = (over = {}) => ({
    status: "done", branch: `sprint/b/${over.id ?? "n"}`, commit: "abc1234",
    filesChanged: ["src/n.ts"], anchors: { typecheck: 0, test: 0 }, scopeGate: 0,
    summary: "did the thing", ...over,
});
const verdict = (lens, over = {}) => ({
    lens, verdict: "pass", evidence: ["checked"], confidence: "sure", ...over,
});
const allPass = () => LENSES.map((l) => verdict(l));

// `typecheck` always runs; `gate` is conditional, so null is a legitimate answer
// for it and never for the other two.
const REQUIRED_ANCHORS = ["typecheck", "test"];

const run = (results, nodes) => reduceWave({
    nodes: nodes ?? results.map((r) => r?.node).filter(Boolean),
    results,
    lenses: LENSES,
    anchorIds: [...ANCHORS, "gate"],
    requiredAnchorIds: REQUIRED_ANCHORS,
    requireAllLenses: true,
});

// ── cases ────────────────────────────────────────────────────────────────────

let pass = 0, fail = 0;
const t = (desc, got, want) => {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log(`ok|${desc}`); pass++; }
    else { console.log(`no|${desc} (got ${g}, want ${w})`); fail++; }
};
const hasWarning = (r, re) => r.warnings.some((w) => new RegExp(re).test(w));

// A clean node is accepted, and says nothing.
{
    const n = node("clean");
    const r = run([{ node: n, build: build(), verdicts: allPass() }]);
    t("a clean node is accepted", r.accepted, ["clean"]);
    t("a clean node produces no warnings", r.warnings, []);
    t("a clean node's outcome is accepted", r.nodes[0].outcome, "accepted");
}

// CANARY: one lens rejects. The other two passed, and it still fails — the
// lenses ask different questions, so one reject is a finding, not an outvote.
{
    const n = node("badcopy");
    const verdicts = [
        verdict("intent", { verdict: "reject", evidence: ["copy says Sign Up, item said Log In"] }),
        verdict("invariants"), verdict("anchors"),
    ];
    const r = run([{ node: n, build: build(), verdicts }]);
    t("a single reject fails the node despite 2 passes", r.rejected, ["badcopy"]);
    t("a rejected node is not also accepted", r.accepted, []);
    t("the rejecting lens is named in the report", r.nodes[0].rejects.map((x) => x.lens), ["intent"]);
}

// CANARY: the builder claims green, a fresh agent observed red. Scar #14 — the
// single most valuable line the system can produce.
{
    const n = node("liar");
    const verdicts = [
        verdict("intent"), verdict("invariants"),
        verdict("anchors", { observedAnchors: { typecheck: 0, test: 1 } }),
    ];
    const r = run([{ node: n, build: build({ anchors: { typecheck: 0, test: 0 } }), verdicts }]);
    t("a claimed/observed anchor mismatch warns", hasWarning(r, "ANCHOR DISAGREEMENT on test"), true);
    t("the warning names both numbers", hasWarning(r, "claimed 0, verifier observed 1"), true);
}
{
    const n = node("honest");
    const verdicts = [
        verdict("intent"), verdict("invariants"),
        verdict("anchors", { observedAnchors: { typecheck: 0, test: 0 } }),
    ];
    const r = run([{ node: n, build: build(), verdicts }]);
    t("matching anchors do NOT warn", hasWarning(r, "ANCHOR DISAGREEMENT"), false);
}

// CANARY: a verifier died. This is scar #2 — the outcome must be `unverified`,
// NEVER `rejected`. Collapsing them invents a finding nobody made.
{
    const n = node("lostlens");
    const r = run([{ node: n, build: build(), verdicts: [verdict("intent"), verdict("invariants")] }]);
    t("a missing lens is unverified, not rejected", r.nodes[0].outcome, "unverified");
    t("an unverified node is not in rejected", r.rejected, []);
    t("an unverified node is not in accepted", r.accepted, []);
    t("the missing lens is named", r.nodes[0].missingLenses, ["anchors"]);
    t("an unverified node warns", hasWarning(r, "UNVERIFIED, not rejected"), true);
}

// CANARY: the whole node died in the pipeline. The fan-in guard must refuse to
// present a partial run as a complete one.
{
    const n1 = node("lived"), n2 = node("died");
    const r = run([{ node: n1, build: build(), verdicts: allPass() }, null], [n1, n2]);
    t("a lost node is counted as dispatched", r.dispatched, 2);
    t("a lost node is not counted as returned", r.returned, 1);
    t("a lost node warns loudly", hasWarning(r, "DO NOT treat this batch as complete"), true);
    t("a lost node appears in no outcome bucket",
        [...r.accepted, ...r.rejected, ...r.unverified, ...r.notBuilt].includes("died"), false);
}

// A blocked builder is `not-built`, and must not burn verifiers to prove it.
{
    const n = node("blocked");
    const r = run([{ node: n, build: build({ status: "blocked", commit: "" }), verdicts: [], skipped: "blocked" }]);
    t("a blocked builder is not-built", r.nodes[0].outcome, "not-built");
    t("a blocked builder is not rejected", r.rejected, []);
}

// A `partial` builder is also not accepted, even if every lens passed.
{
    const n = node("partial");
    const r = run([{ node: n, build: build({ status: "partial" }), verdicts: allPass() }]);
    t("a partial build is never accepted", r.accepted, []);
    t("a partial build with clean lenses is not-built", r.nodes[0].outcome, "not-built");
}

// Builder-declared escapes must survive into the report rather than being
// summarised away — they are the operator's only view of what the fix wanted.
{
    const n = node("escape");
    const r = run([{
        node: n,
        build: build({ outOfScope: ["src/other.ts"], staleEvidence: ["MAP said line 40, it is line 62"] }),
        verdicts: allPass(),
    }]);
    t("outOfScope reaches the report", r.nodes[0].outOfScope, ["src/other.ts"]);
    t("staleEvidence reaches the report", r.nodes[0].staleEvidence, ["MAP said line 40, it is line 62"]);
}

// CANARY: the builder edited a file the node does not own. Every lens passed and
// every anchor was green — the branch is a green build of the wrong tree.
{
    const n = node("reached");
    const r = run([{ node: n, build: build({ scopeGate: 1 }), verdicts: allPass() }]);
    t("a scope violation is rejected despite 3 passing lenses", r.rejected, ["reached"]);
    t("a scope violation is not accepted", r.accepted, []);
    t("a scope violation warns", hasWarning(r, "SCOPE VIOLATION"), true);
    t("the warning says not to merge it", hasWarning(r, "Do not merge it"), true);
}

// FAIL CLOSED: nobody reported the gate. That is not a pass — scar #8, a guard
// that fails open is the same as no guard. It is also not a rejection: no one
// made a finding. It is `unverified`.
{
    const n = node("ungated");
    const b = build(); delete b.scopeGate;
    const r = run([{ node: n, build: b, verdicts: allPass() }]);
    t("a missing scope gate is NOT accepted", r.accepted, []);
    t("a missing scope gate is unverified, not rejected", r.nodes[0].outcome, "unverified");
    t("a missing scope gate says so", hasWarning(r, "scope gate was never reported"), true);
    // ...and it must not blame a verifier that ran perfectly well.
    t("a missing scope gate does not fake a missing lens",
        hasWarning(r, "UNVERIFIED, not rejected"), false);
}

// The verifier's observed gate OUTRANKS the builder's claim, same as anchors.
{
    const n = node("gatelie");
    const verdicts = [verdict("intent"), verdict("invariants"),
        verdict("anchors", { observedScopeGate: 1 })];
    const r = run([{ node: n, build: build({ scopeGate: 0 }), verdicts }]);
    t("an observed scope violation beats a claimed pass", r.rejected, ["gatelie"]);
    t("the scope gate disagreement is named", hasWarning(r, "SCOPE GATE DISAGREEMENT"), true);
}

// A CONDITIONAL anchor that did not apply is agreement about a third state, not
// a disagreement. Watched manufacture a false ANCHOR DISAGREEMENT on a live
// batch when the schema had no way to say "not applicable" and each agent
// invented a different sentinel.
{
    const n = node("notapplicable");
    const verdicts = [verdict("intent"), verdict("invariants"),
        verdict("anchors", { observedAnchors: { typecheck: 0, test: 0, gate: null } })];
    const r = run([{ node: n, build: build({ anchors: { typecheck: 0, test: 0, gate: null } }), verdicts }]);
    t("a null conditional anchor does NOT warn", hasWarning(r, "ANCHOR DISAGREEMENT"), false);
    t("a node with a not-applicable anchor is still accepted", r.accepted, ["notapplicable"]);
}
// null on ONE side is still agreement — one agent ran the gate and got
// not-applicable, the other skipped it. Neither observed a failure.
{
    const n = node("halfnull");
    const verdicts = [verdict("intent"), verdict("invariants"),
        verdict("anchors", { observedAnchors: { typecheck: 0, test: 0, gate: 0 } })];
    const r = run([{ node: n, build: build({ anchors: { typecheck: 0, test: 0, gate: null } }), verdicts }]);
    t("null on one side only does not warn", hasWarning(r, "ANCHOR DISAGREEMENT"), false);
}
// A real disagreement must still fire.
{
    const n = node("realdisagree");
    const verdicts = [verdict("intent"), verdict("invariants"),
        verdict("anchors", { observedAnchors: { typecheck: 0, test: 1, gate: null } })];
    const r = run([{ node: n, build: build({ anchors: { typecheck: 0, test: 0, gate: null } }), verdicts }]);
    t("a real anchor disagreement still fires", hasWarning(r, "ANCHOR DISAGREEMENT on test"), true);
}
// FAIL CLOSED: null is only legitimate for a CONDITIONAL anchor. An always-run
// anchor reported as null is a required check nobody ran.
{
    const n = node("skippedrequired");
    const r = run([{ node: n, build: build({ anchors: { typecheck: 0, test: null } }), verdicts: allPass() }]);
    t("a null on an ALWAYS-run anchor warns", hasWarning(r, "anchor test runs on every diff"), true);
    t("...and says absence is not success", hasWarning(r, "not a check that passed"), true);
}

// CANARY: one lens saw a defect that another lens OWNS, and that lens passed.
// Scar #37 — every lens returned, every anchor was green, and the signal was
// sitting in the run while the node merged.
{
    const n = node("contested");
    const verdicts = [
        verdict("intent"), verdict("invariants"),
        verdict("anchors", { crossLens: [{ lens: "invariants", concern: "the boundary moved" }] }),
    ];
    const r = run([{ node: n, build: build(), verdicts }]);
    t("a contested lens is NOT accepted", r.accepted, []);
    t("a contested lens is unverified, not rejected", r.nodes[0].outcome, "unverified");
    t("a contested lens is not in rejected", r.rejected, []);
    t("the warning names both lenses", hasWarning(r, "CONTESTED LENS.*anchors.*invariants"), true);
    t("the warning carries the concern", hasWarning(r, "the boundary moved"), true);
    t("...and says which lens to re-run", hasWarning(r, "re-run the invariants lens"), true);
    // It must not also blame a verifier that ran perfectly well. Matched on the
    // missing-lens wording, NOT on "UNVERIFIED, not rejected" — the contested
    // warning says that too, and a regex that both warnings satisfy tests nothing.
    t("a contested lens does not fake a missing lens", hasWarning(r, "verifiers returned"), false);
    t("...and names no missing lens", r.nodes[0].missingLenses, []);
}

// CRY WOLF GUARD (scar #17): the concern only contests a lens that PASSED. If
// the named lens rejected, the finding already landed and saying it twice trains
// the operator to skim.
{
    const n = node("agreed");
    const verdicts = [
        verdict("intent"),
        verdict("invariants", { verdict: "reject", evidence: ["the boundary moved"] }),
        verdict("anchors", { crossLens: [{ lens: "invariants", concern: "the boundary moved" }] }),
    ];
    const r = run([{ node: n, build: build(), verdicts }]);
    t("a concern the named lens already rejected is not contested", r.rejected, ["agreed"]);
    t("...and does not warn twice", hasWarning(r, "CONTESTED LENS"), false);
}

// A contested node that ANOTHER lens rejected is `rejected`, not `unverified`,
// and the warning must not say otherwise. The first live run of the contested
// rule produced exactly this shape — two lenses rejecting, a third passing what
// it owned — and the warning claimed the node was unverified.
{
    const n = node("contestedandrejected");
    const verdicts = [
        verdict("intent", { verdict: "reject", evidence: ["the item asked for a tidy, this removes a guard"] }),
        verdict("invariants", { crossLens: [{ lens: "anchors", concern: "green binds nothing here" }] }),
        verdict("anchors"),
    ];
    const r = run([{ node: n, build: build(), verdicts }]);
    t("a contested node another lens rejected is rejected", r.nodes[0].outcome, "rejected");
    t("the contest is still reported", hasWarning(r, "CONTESTED LENS"), true);
    t("the warning does NOT call a rejected node unverified",
        hasWarning(r, "UNVERIFIED, not rejected"), false);
    t("...it says the merge decision is unchanged",
        hasWarning(r, "changes no merge decision"), true);
}

// A concern naming a lens that never returned adds nothing: the node is already
// unverified for the missing lens, and there is no verdict to contest.
{
    const n = node("namesdead");
    const verdicts = [
        verdict("intent"),
        verdict("anchors", { crossLens: [{ lens: "invariants", concern: "the boundary moved" }] }),
    ];
    const r = run([{ node: n, build: build(), verdicts }]);
    t("a concern naming a lens that never ran is unverified", r.nodes[0].outcome, "unverified");
    t("...and does not manufacture a contest", hasWarning(r, "CONTESTED LENS"), false);
    t("...it reports the missing lens instead", r.nodes[0].missingLenses, ["invariants"]);
}

// A clean crossLens field changes nothing.
{
    const n = node("nocross");
    const r = run([{ node: n, build: build(), verdicts: LENSES.map((l) => verdict(l, { crossLens: [] })) }]);
    t("an empty crossLens is still accepted", r.accepted, ["nocross"]);
    t("an empty crossLens produces no warnings", r.warnings, []);
}

// `couldNotVerify` neither blocks NOR warns. The prompt asks every verifier to
// record what it could not reach, and every verifier does: on a live batch the
// warning this once produced fired on 6 of 6 accepted nodes. A line on 100% of
// the success state is scar #17 with numbers attached. The field still reaches
// the report, which is where it is usable.
{
    const n = node("unanswered");
    const verdicts = [
        verdict("intent", { couldNotVerify: ["could not reach the staging config"] }),
        verdict("invariants"), verdict("anchors"),
    ];
    const r = run([{ node: n, build: build(), verdicts }]);
    t("couldNotVerify does NOT block acceptance", r.accepted, ["unanswered"]);
    t("couldNotVerify does not warn either", r.warnings, []);
    t("the entries reach the report", r.nodes[0].couldNotVerify, ["could not reach the staging config"]);
}

// ── confirm pass ─────────────────────────────────────────────────────────────
//
// A second verification wave over nodes the first pass accepted. A reject in
// EITHER pass fails the node; an incomplete confirm pass does not.

// No confirm pass at all: nothing changes, and the node reports null rather
// than 0 — "not run" is not "ran and returned nothing".
{
    const n = node("noconfirm");
    const r = run([{ node: n, build: build(), verdicts: allPass() }]);
    t("a node with no confirm pass is accepted as before", r.accepted, ["noconfirm"]);
    t("confirmRan is null, not 0, when no pass ran", r.nodes[0].confirmRan, null);
    t("a node with no confirm pass warns nothing", r.warnings, []);
}

// A clean confirm pass leaves the node accepted and says nothing.
{
    const n = node("confirmed");
    const r = run([{ node: n, build: build(), verdicts: allPass(), confirm: { verdicts: allPass() } }]);
    t("a clean confirm pass keeps the node accepted", r.accepted, ["confirmed"]);
    t("a clean confirm pass reports its count", r.nodes[0].confirmRan, 3);
    t("a clean confirm pass warns nothing", r.warnings, []);
}

// CANARY: the whole point. The first pass accepted it and the second caught it.
{
    const n = node("missedfirst");
    const confirm = [
        verdict("intent"),
        verdict("invariants", { verdict: "reject", evidence: ["the ceiling moved by one"] }),
        verdict("anchors"),
    ];
    const r = run([{ node: n, build: build(), verdicts: allPass(), confirm: { verdicts: confirm } }]);
    t("a confirm-pass reject fails the node", r.rejected, ["missedfirst"]);
    t("...and it is not also accepted", r.accepted, []);
    t("...and it is rejected, not unverified", r.nodes[0].outcome, "rejected");
    t("the confirm reject is named in the report",
        r.nodes[0].confirmRejects.map((x) => x.lens), ["invariants"]);
    t("the warning says the confirm pass caught it", hasWarning(r, "THE CONFIRM PASS CAUGHT THIS"), true);
    t("...and carries the evidence", hasWarning(r, "the ceiling moved by one"), true);
}

// BEST EFFORT: a verifier died in the confirm pass. The node already cleared a
// COMPLETE first pass, so it stays accepted — otherwise switching confirmation
// on makes good work fail at random, and it gets switched straight back off.
{
    const n = node("flakyconfirm");
    const r = run([{
        node: n, build: build(), verdicts: allPass(),
        confirm: { verdicts: [verdict("intent"), verdict("anchors")] },
    }]);
    t("an incomplete confirm pass does NOT fail the node", r.accepted, ["flakyconfirm"]);
    t("...and the node is still accepted", r.nodes[0].outcome, "accepted");
    t("...but it says so", hasWarning(r, "confirm pass returned 2/3"), true);
    t("...and does not claim the node was unjudged",
        hasWarning(r, "UNVERIFIED, not rejected"), false);
}

// A confirm pass never rescues a node the FIRST pass rejected: it is not run on
// one, and a stray one must not outvote a standing reject.
{
    const n = node("stillrejected");
    const verdicts = [
        verdict("intent", { verdict: "reject", evidence: ["wrong copy"] }),
        verdict("invariants"), verdict("anchors"),
    ];
    const r = run([{ node: n, build: build(), verdicts, confirm: { verdicts: allPass() } }]);
    t("a clean confirm pass cannot rescue a rejected node", r.rejected, ["stillrejected"]);
    t("...and it is not accepted", r.accepted, []);
}

console.error(`reduce-fixture: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
