export const meta = {
    name: 'sprint-batch',
    description: 'Build and adversarially verify one partitioned batch of queue items',
    whenToUse: 'Invoked by the /sprint skill after plan-batch.mjs has produced a partition. Not for ad-hoc use — it expects a plan object in args.',
    phases: [
        { title: 'Build', detail: 'one builder per node, each in its own git worktree' },
        { title: 'Verify', detail: 'fresh skeptics per node, one lens each' },
    ],
};

// The diamond.
//
//   fan out   — one builder per node, isolated worktree, commits to a branch
//   verify    — N FRESH verifiers per node, one lens each, never the builder's
//               context
//   reduce    — plain code below: count what came back, refuse to report a
//               partial run as complete, and compare claimed exit codes against
//               observed ones
//
// PROJECT-AGNOSTIC. Everything specific to a repo arrives inside `plan.harness`,
// which plan-batch.mjs built from harness.config.json. Workflow scripts have no
// filesystem access, so this is the only way config can reach here — and that
// constraint is load-bearing, not a workaround: it forces collision detection to
// happen in plain code in the main loop, where it can be read before anything
// runs.
//
// Waves matter. Every node in wave 0 runs at once; a wave N>0 node runs alone,
// after the previous wave has been merged by the human gate. This script builds
// ONE wave per invocation — the caller passes plan.wave and re-invokes.

// args may arrive as the parsed object OR as a JSON string, depending on how the
// caller serialised it. Accept both rather than failing a whole run on that
// detail; the guard below still catches a genuinely wrong shape.
const plan = typeof args === 'string' ? JSON.parse(args) : args;

if (!plan || !Array.isArray(plan.nodes)) {
    throw new Error(
        'sprint-batch: args must be the plan object from plan-batch.mjs --json, ' +
        `got ${typeof args}${args && typeof args === 'object' ? ' with keys ' + Object.keys(args).join(',') : ''}`,
    );
}
if (!plan.harness || !Array.isArray(plan.harness.anchors)) {
    throw new Error(
        'sprint-batch: plan.harness is missing. Regenerate the plan with a current ' +
        'core/plan-batch.mjs — it embeds the harness config slice, because this ' +
        'script cannot read the filesystem to find harness.config.json itself.',
    );
}

const H = plan.harness;
const WAVE = plan.wave ?? 0;
const BATCH = plan.batchName ?? 'batch';
const LENSES = H.lenses;
const ANCHOR_IDS = H.anchors.map((a) => a.id);

// Branch from the SPRINT BASE, not from the main branch. The anchors frequently
// only exist on the base — a test runner that was only just installed, a type
// generic that was only just wired. A builder branching from main would be
// judged by a weaker set of checks than the batch is being held to, and the
// merge back would be noisy for no reason.
const BASE = plan.baseBranch;
if (!BASE) {
    throw new Error('sprint-batch: args.baseBranch is required — the branch builders start from');
}

const nodes = plan.nodes.filter((n) => (n.wave ?? 0) === WAVE);
if (!nodes.length) {
    return { wave: WAVE, error: `no nodes in wave ${WAVE}`, nodes: [] };
}

log(`wave ${WAVE}: ${nodes.length} node(s), ${nodes.reduce((n, x) => n + x.items.length, 0)} item(s)`);

// ── schemas ──────────────────────────────────────────────────────────────────
// Structured output is what lets the reduce step below be plain code instead of
// another model reading prose.

const anchorProps = Object.fromEntries(ANCHOR_IDS.map((id) => [id, { type: 'integer' }]));

const BUILD_SCHEMA = {
    type: 'object',
    required: ['status', 'branch', 'filesChanged', 'anchors', 'summary'],
    properties: {
        status: { enum: ['done', 'partial', 'blocked'] },
        branch: { type: 'string' },
        commit: { type: 'string', description: 'short sha of the commit, or empty if nothing was committed' },
        filesChanged: { type: 'array', items: { type: 'string' } },
        outOfScope: {
            type: 'array', items: { type: 'string' },
            description: 'files the fix genuinely needed but which were NOT in this node — not edited',
        },
        anchors: { type: 'object', properties: anchorProps },
        preExistingFailures: { type: 'array', items: { type: 'string' } },
        staleEvidence: {
            type: 'array', items: { type: 'string' },
            description: 'cited evidence that no longer matched the code — a finding about the MAP itself',
        },
        summary: { type: 'string' },
    },
};

// Every free-text field here is a SHORT string, and the multi-part ones are
// arrays of short strings rather than one long blob.
//
// THIS IS NOT COSMETIC. On the first real run of the system this was extracted
// from, 7 of 18 verifiers died on `StructuredOutput retry cap (5) exceeded`:
// each was trying to emit ~3.5KB of prose inside a single JSON string field, and
// the embedded newlines and quotes broke the parse on every retry. Every one of
// those lost verdicts was a `pass`, so the serialisation failure manufactured
// five false negatives.
//
// Bounded arrays fix it STRUCTURALLY — a 300-char element cannot hold a
// paragraph, so the model splits instead of escaping.
const SHORT = { type: 'string', maxLength: 300 };

const VERDICT_SCHEMA = {
    type: 'object',
    required: ['lens', 'verdict', 'evidence', 'confidence'],
    properties: {
        lens: { enum: LENSES },
        verdict: { enum: ['pass', 'reject'] },
        evidence: {
            type: 'array', items: SHORT, maxItems: 8,
            description: 'One short bullet per thing you checked. No newlines inside an item.',
        },
        confidence: { ...SHORT, description: 'One sentence: how sure, and what would change your mind.' },
        couldNotVerify: { type: 'array', items: SHORT, maxItems: 6 },
        testGap: { ...SHORT, maxLength: 400 },
        observedAnchors: {
            type: 'object',
            properties: { ...anchorProps, method: { ...SHORT } },
        },
    },
};

// ── prompts ──────────────────────────────────────────────────────────────────

const slug = (s) => s.replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase().slice(0, 48);

const anchorLines = (indent = '    ') => H.anchors.map((a) => {
    const where = a.cwd && a.cwd !== '.' ? `  (from ${a.cwd}/)` : '';
    const cond = a.always === false && a.whenTouches?.length
        ? `  — ONLY if the diff touches: ${a.whenTouches.join(', ')}`
        : '';
    return `${indent}${a.cmd}${where}${cond}`;
}).join('\n');

const setupLines = () => H.setup.length
    ? H.setup.map((s) => {
        const where = s.cwd && s.cwd !== '.' ? ` (from ${s.cwd}/)` : '';
        return `    ${s.cmd}${where}${s.why ? `\n        why: ${s.why}` : ''}`;
    }).join('\n')
    : '    (none configured)';

function buildPrompt(node) {
    const branch = `${H.branchPrefix}/${BATCH}/${slug(node.nodeId)}`;
    return [
        `Implement this node of the sprint batch, then commit it to branch \`${branch}\`.`,
        ``,
        `NODE: ${node.nodeId}`,
        `WHY GROUPED: ${node.reason}`,
        node.serial
            ? `This node holds MORE THAN ONE item because they collide. Do them all, in ` +
              `one context, in the order that makes the smaller diff.`
            : `This node holds one item.`,
        ``,
        `FILES THIS NODE OWNS (do not edit anything else):`,
        ...node.files.map((f) => `  - ${f}`),
        ``,
        `ITEMS:`,
        ...node.items.map((it) => [
            ``,
            `  id       : ${it.id}`,
            `  severity : ${it.severity ?? '(unset)'}`,
            `  source   : ${it.source ?? '(unset)'}`,
            `  title    : ${it.title}`,
            `  evidence : ${it.detail ?? '(see title)'}`,
        ].join('\n')),
        ``,
        `Create the branch from \`${BASE}\` before you start:`,
        `    git checkout -b ${branch} ${BASE}`,
        ``,
        `SETUP — run this in YOUR worktree before the anchors:`,
        setupLines(),
        ``,
        `ANCHORS — run these and report the exit code you ACTUALLY observed:`,
        anchorLines(),
        ``,
        `Then follow your agent instructions: read the evidence, verify it is still`,
        `accurate, make the smallest correct change, run the anchors, commit.`,
        ``,
        `Return the structured object. An independent verifier re-runs these anchors,`,
        `so a false green here will be caught and will invalidate your whole node.`,
    ].join('\n');
}

function verifyPrompt(node, build, lens) {
    return [
        `Verify one node of a sprint batch through the \`${lens}\` lens ONLY.`,
        ``,
        `You have not seen the work being judged and you must not assume it is correct.`,
        `Your default is REJECT; pass only what you positively confirm.`,
        ``,
        `BRANCH   : ${build.branch}`,
        `NODE     : ${node.nodeId}`,
        `FILES THIS NODE WAS ALLOWED TO TOUCH:`,
        ...node.files.map((f) => `  - ${f}`),
        ``,
        `THE ITEMS IT CLAIMED TO FIX:`,
        ...node.items.map((it) => `  ${it.id}: ${it.title}\n    evidence: ${it.detail ?? '(see title)'}`),
        ``,
        `WHAT THE BUILDER CLAIMS (treat as an assertion to test, not as fact):`,
        `  status       : ${build.status}`,
        `  filesChanged : ${(build.filesChanged ?? []).join(', ') || '(none reported)'}`,
        `  anchors      : ${JSON.stringify(build.anchors ?? {})}`,
        `  summary      : ${build.summary}`,
        ``,
        `Read the diff yourself: \`git diff ${BASE}...${build.branch}\``,
        ``,
        lens === 'anchors'
            ? [
                `Re-run the anchors in a FRESH worktree. Do NOT trust the exit codes above.`,
                ``,
                `    git worktree add /tmp/verify-${slug(node.nodeId)} ${build.branch}`,
                ``,
                `Then, inside it, the setup:`,
                setupLines(),
                ``,
                `and the anchors:`,
                anchorLines(),
                ``,
                `Clean up: git worktree remove /tmp/verify-${slug(node.nodeId)} --force`,
                ``,
                `Report the exit codes you OBSERVED. "It should pass" is not an answer to`,
                `this lens; only an exit code is.`,
            ].join('\n')
            : `Judge only through the \`${lens}\` lens as described in your instructions.`,
        ``,
        `Return the structured verdict. KEEP EVERY FIELD SHORT: \`evidence\` is a list`,
        `of one-line bullets (max ~300 chars each, no newlines inside a bullet), and`,
        `\`confidence\` is ONE sentence. A long field fails to serialise and your whole`,
        `verdict is lost — a lost pass reads downstream as an unverified node.`,
    ].join('\n');
}

// ── the diamond ──────────────────────────────────────────────────────────────
// pipeline, not parallel: a node's verifiers start the moment THAT node's
// builder lands, rather than waiting for the slowest builder in the wave.

const results = await pipeline(
    nodes,

    // FAN OUT — one builder per node, each in its own worktree so two nodes
    // physically cannot overwrite each other even if the partition were wrong.
    (node) => agent(buildPrompt(node), {
        label: `build:${node.nodeId}`,
        phase: 'Build',
        agentType: H.agents.builder,
        isolation: 'worktree',
        schema: BUILD_SCHEMA,
    }),

    // VERIFY — fresh skeptics asking DIFFERENT questions. N distinct lenses
    // catch what N identical reviewers cannot.
    (build, node) => {
        if (!build) return { node, build: null, verdicts: [] };
        if (build.status === 'blocked' || !build.commit) {
            // Nothing to verify. Do not spend N agents proving that.
            return { node, build, verdicts: [], skipped: 'builder reported blocked / no commit' };
        }
        return parallel(
            LENSES.map((lens) => () => agent(verifyPrompt(node, build, lens), {
                label: `verify:${lens}:${node.nodeId}`,
                phase: 'Verify',
                agentType: H.agents.verifier,
                schema: VERDICT_SCHEMA,
            })),
        ).then((verdicts) => ({ node, build, verdicts: verdicts.filter(Boolean) }));
    },
);

// ── REDUCE — plain code, no model, no tokens ─────────────────────────────────

const dispatched = nodes.length;
const returned = results.filter(Boolean);
const lost = dispatched - returned.length;

const report = returned.map((r) => {
    const verdicts = r.verdicts ?? [];
    const rejects = verdicts.filter((v) => v.verdict === 'reject');
    const passes = verdicts.filter((v) => v.verdict === 'pass');

    // A node is accepted only when every lens ran AND none rejected.
    // Majority is NOT enough: the lenses ask different questions, so a single
    // reject is a real finding, not an outvoted opinion.
    const allLensesRan = !H.requireAllLenses || verdicts.length === LENSES.length;
    const accepted = r.build?.status === 'done' && allLensesRan && rejects.length === 0;

    // "Rejected" and "unverified" are DIFFERENT outcomes and must never be
    // collapsed. A node whose verifier crashed has not been judged; reporting it
    // as rejected invents a finding nobody made. The first real run of the
    // original system produced exactly that — five nodes listed as rejected when
    // zero verifiers rejected anything and every lost verdict was a pass.
    const outcome = accepted ? 'accepted'
        : rejects.length > 0 ? 'rejected'
        : r.build?.status !== 'done' ? 'not-built'
        : 'unverified';

    const missingLenses = LENSES.filter((l) => !verdicts.some((v) => v.lens === l));

    return {
        nodeId: r.node.nodeId,
        items: r.node.items.map((i) => i.id),
        branch: r.build?.branch ?? null,
        commit: r.build?.commit ?? null,
        builderStatus: r.build?.status ?? 'no-result',
        accepted,
        outcome,
        missingLenses,
        verdictsRun: verdicts.length,
        rejects: rejects.map((v) => ({ lens: v.lens, evidence: v.evidence, confidence: v.confidence })),
        passes: passes.map((v) => v.lens),
        observedAnchors: verdicts.find((v) => v.lens === 'anchors')?.observedAnchors ?? null,
        claimedAnchors: r.build?.anchors ?? null,
        outOfScope: r.build?.outOfScope ?? [],
        preExistingFailures: r.build?.preExistingFailures ?? [],
        staleEvidence: r.build?.staleEvidence ?? [],
        testGaps: verdicts.map((v) => v.testGap).filter(Boolean),
        couldNotVerify: verdicts.flatMap((v) => v.couldNotVerify ?? []),
        skipped: r.skipped ?? null,
        summary: r.build?.summary ?? null,
    };
});

// FAN-IN GUARD — never present a partial run as a complete one.
const warnings = [];
if (lost > 0) {
    warnings.push(
        `${lost} of ${dispatched} nodes returned NOTHING — they died or were skipped. ` +
        `DO NOT treat this batch as complete.`);
}
for (const r of report) {
    if (r.outcome === 'unverified') {
        warnings.push(
            `${r.nodeId}: UNVERIFIED, not rejected — ${r.verdictsRun}/${LENSES.length} verifiers returned, ` +
            `missing [${r.missingLenses.join(', ')}]. No verifier rejected this node; it simply was not judged ` +
            `on those lenses. Re-run verification before treating it either way.`);
    }
    // The builder's claimed exit codes vs what a fresh agent actually observed.
    // A disagreement here is the single most important line this system can
    // produce: it means one of the two is reporting a build that does not exist.
    const claimed = r.claimedAnchors, observed = r.observedAnchors;
    if (claimed && observed) {
        for (const k of ANCHOR_IDS) {
            if (observed[k] != null && claimed[k] != null && observed[k] !== claimed[k]) {
                warnings.push(
                    `${r.nodeId}: ANCHOR DISAGREEMENT on ${k} — ` +
                    `builder claimed ${claimed[k]}, verifier observed ${observed[k]}.`);
            }
        }
    }
}

log(`wave ${WAVE} done: ${report.filter((r) => r.accepted).length}/${dispatched} accepted, ${warnings.length} warning(s)`);

return {
    batch: BATCH,
    wave: WAVE,
    dispatched,
    returned: returned.length,
    accepted: report.filter((r) => r.outcome === 'accepted').map((r) => r.nodeId),
    rejected: report.filter((r) => r.outcome === 'rejected').map((r) => r.nodeId),
    unverified: report.filter((r) => r.outcome === 'unverified').map((r) => r.nodeId),
    notBuilt: report.filter((r) => r.outcome === 'not-built').map((r) => r.nodeId),
    warnings,
    nodes: report,
};
