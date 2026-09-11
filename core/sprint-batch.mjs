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

// `['integer','null']`, not `'integer'`. NULL IS "THIS ANCHOR DID NOT APPLY".
//
// A conditional anchor (`always: false` + `whenTouches`) has a third state
// besides pass and fail, and typing it as a bare integer gave that state no
// representation — so each agent invented one. Watched happen: a node whose diff
// touched no web file had its builder report the conditional gate as -1 and its
// verifier, who ran the gate and got a not-applicable exit 0, report 0. Both were
// correct about reality. The reduce compared the integers and emitted an ANCHOR
// DISAGREEMENT, which the runbook calls the most important line the system can
// produce. It only works if it is rare, and this manufactured one on a node where
// nothing was wrong.
//
// Deliberately NOT solved by teaching the reduce to tolerate -1: that would
// promote one agent's guess to a convention. `null` is the JSON-native absence,
// both prompts are told to use it, and the reduce skips any comparison where
// either side is null.
const anchorProps = Object.fromEntries(ANCHOR_IDS.map((id) => [id, {
    type: ['integer', 'null'],
    description: 'exit code observed, or null if this anchor did not apply to this diff',
}]));

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
        scopeGate: {
            type: 'integer',
            description: 'exit code of the scope gate you ran before reporting. 0 = every changed file was declared by this node.',
        },
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
        observedScopeGate: {
            type: 'integer',
            description: 'anchors lens only: exit code of the scope gate you re-ran yourself. Omit if you did not run it.',
        },
    },
};

// ── prompts ──────────────────────────────────────────────────────────────────

const slug = (s) => s.replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase().slice(0, 48);

// ── anchor placeholders ──────────────────────────────────────────────────────
//
// An anchor cmd may carry `{base}`, which resolves to THIS NODE'S BASE — the
// branch the builder started from, which is not the main branch.
//
// The paired-artifact gate is why this exists. It diffs three-dot against a base
// ref and defaults to project.mainBranch, but preflight.sh's stacking rule means
// a batch's base is normally the newest UNPUSHED branch, and there can be several
// batches between pushes. Judged against main, every node inherits every earlier
// node's gate failures, and it gets worse the deeper the stack.
//
// Measured on a live project, 2026-08-19: against main the gate exited 1 on two
// components already changed on the base branch, and against the node's real base
// the same tree exited 0. The builder honestly reported 1, its verifier honestly
// observed 0, and the reduce raised an ANCHOR DISAGREEMENT — the loudest signal
// this harness produces — over nothing but the base argument. That signal only
// works if it is rare.
//
// The second consequence is the serious one. Once the gate is red from inherited
// failures, a node that genuinely skipped its own paired artifact is
// INDISTINGUISHABLE: the anchor was already failing and cannot fail louder. The
// gate stops discriminating exactly when the stack is deepest, which is when the
// most work is unreviewed.
//
// This does NOT make the gate lenient and must not be turned into that. The
// inherited failures are real. They are simply not this node's, and an anchor
// that blames a node for its base teaches builders that this anchor's failures
// belong to somebody else — the habit scar #17 describes as the thing that
// destroys a check.
//
// The INTEGRATE step asks a DIFFERENT question and keeps its own base: whether
// the batch AS A WHOLE shipped its paired artifacts. Both callers are right; only
// the per-node one was passing the wrong base.
const ANCHOR_PLACEHOLDERS = { base: () => BASE };

// `(?<!\$)` so a shell variable — `${PYTEST_ARGS}` — is left alone. Brace
// expansion carries a comma and never matches `\w+`.
const resolveAnchorCmd = (a) => a.cmd.replace(/(?<!\$)\{(\w+)\}/g, (whole, key) => {
    const resolve = ANCHOR_PLACEHOLDERS[key];
    if (!resolve) {
        // THROW RATHER THAN PASS IT THROUGH. An unresolved `{basebranch}` reaches
        // the gate as a literal ref name and exits 2 — and a 2 in an anchor column
        // reads as "the check ran and this node is broken", not "the config has a
        // typo". That is the same masquerade the ITEM_KEYS assertion above exists
        // to prevent, and the cost of throwing is identical: a launch that fails
        // in seconds having spent zero tokens, with the offending key named.
        throw new Error(
            `sprint-batch: anchor ${JSON.stringify(a.id)} uses unknown placeholder ` +
            `${whole}. Known: ${Object.keys(ANCHOR_PLACEHOLDERS).map((k) => `{${k}}`).join(', ')}.`,
        );
    }
    return resolve();
});

// ── serialised anchors ───────────────────────────────────────────────────────
//
// An anchor with `serialize: true` is wrapped in a host-wide lock, so only one
// copy of it runs on the box at a time no matter how wide the fan-out is.
//
// This exists because a wave starts a heavyweight suite up to 2N times at once —
// one builder and one `anchors` verifier per node — and most runners size their
// worker pool to the core count, so N concurrent runs oversubscribe the machine
// N-fold. Measured on a 12-core box, 2026-09-02: eight concurrent `npm test` runs
// against a tree that is 972/972 green ALONE came back 8/8 red, and all 200
// failures were `Test timed out in 5000ms`. Not one assertion failed.
//
// The damage is not the wasted time. It is that the anchor answers a question
// about machine load while presenting as a question about the code, so a builder
// and its verifier can honestly disagree at random — manufacturing the ANCHOR
// DISAGREEMENT that is supposed to be this harness's loudest and rarest signal.
// See SCARS.md #35.
//
// The lock is advisory, host-wide and keyed by name, so every worktree queues on
// the same one. That IS the point: they share the CPU, not the checkout.
const cwdHop = (cwd) => {
    const clean = (cwd ?? '.').replace(/^\.\/+/, '').replace(/\/+$/, '');
    if (clean === '' || clean === '.') return './';
    return clean.split('/').map(() => '..').join('/') + '/';
};

const serialised = (a, cmd) => {
    if (a.serialize !== true) return cmd;
    if (!H.serializer) {
        // Throw rather than silently drop the lock. A plan built by an older
        // plan-batch carries `serialize: true` with nowhere to send it, and an
        // anchor that quietly stops being serialised looks exactly like one that
        // never needed to be — until the next wide wave goes red at random.
        throw new Error(
            `sprint-batch: anchor ${JSON.stringify(a.id)} sets serialize:true but the ` +
            `plan carries no harness.serializer path. Re-run plan-batch.mjs --json ` +
            `with a current core/lib/config.mjs.`,
        );
    }
    return `${cwdHop(a.cwd)}${H.serializer} ${a.id} ${cmd}`;
};

// Eager, so a bad placeholder throws before the first agent spawns rather than
// inside the prompt builder of whichever node happens to render first.
const ANCHOR_CMDS = new Map(H.anchors.map((a) => [a.id, serialised(a, resolveAnchorCmd(a))]));

const anchorLines = (indent = '    ') => H.anchors.map((a) => {
    const where = a.cwd && a.cwd !== '.' ? `  (from ${a.cwd}/)` : '';
    const cond = a.always === false && a.whenTouches?.length
        ? `  — ONLY if the diff touches: ${a.whenTouches.join(', ')}. If it does ` +
          `NOT, report ${a.id}: null — do not invent a number.`
        : '';
    return `${indent}${ANCHOR_CMDS.get(a.id)}${where}${cond}`;
}).join('\n');

const setupLines = () => H.setup.length
    ? H.setup.map((s) => {
        const where = s.cwd && s.cwd !== '.' ? ` (from ${s.cwd}/)` : '';
        return `    ${s.cmd}${where}${s.why ? `\n        why: ${s.why}` : ''}`;
    }).join('\n')
    : '    (none configured)';

const newFilesOf = (node) => new Set(node.items.flatMap((it) => it.newFiles ?? []));

// The scope gate, as a command an agent can run. "Do not touch files outside
// this node's list" lived as PROSE in three places — the builder contract, the
// intent lens and the integrate step — and scar #7 is that a rule in a prompt is
// a suggestion. It is also the only question in the intent lens that is not a
// judgement call: it is a set difference, and `comm` is both faster and more
// reliable at that than a language model.
//
// An exclusive node is exempt and the script says so itself — a repo-wide node's
// file list is incomplete by construction, so there is no set to gate against.
const scopeGateCmd = (node) =>
    `${H.scopeGate} ${BASE} --files ${JSON.stringify(node.files.join(' '))}`;

// ── the item contract, asserted ──────────────────────────────────────────────
// EVERY key an item may carry. buildPrompt renders id/severity/source/title/
// detail; verifyPrompt renders title/detail; files and newFiles reach the agents
// through node.files. Anything else in an item reaches NOBODY.
//
// WHY THIS THROWS INSTEAD OF WARNING. A dropped field is invisible in exactly
// the way that matters: the batch still runs, every agent still returns, every
// lens still passes, and the report is indistinguishable from one where the
// field was honoured. On brian-chastain batch 1 the operator re-scoped six items
// — settled decisions, hazards, explicit do-not-touch lists — onto a `sharpened`
// key beside `detail`. It would have been discarded silently on all four nodes,
// and the resulting green batch would have been read as "the constraints held"
// when no agent had ever seen one. It was caught by reading the prompt builder,
// which is not a control.
//
// The cost of throwing is a launch that fails in seconds having spent zero
// tokens, with the offending key named. The cost of warning is a plausible batch
// built against constraints nobody read. This is the same trade as scar #2:
// unverified must not be able to masquerade as verified.
const ITEM_KEYS = new Set(['id', 'title', 'source', 'severity', 'files', 'newFiles', 'detail']);
const stray = [...new Set(
    plan.nodes.flatMap((n) => (n.items ?? []).flatMap(
        (it) => Object.keys(it).filter((k) => !ITEM_KEYS.has(k)).map((k) => `${it.id}.${k}`),
    )),
)];
if (stray.length) {
    throw new Error(
        `sprint-batch: ${stray.length} item field(s) would reach no agent and were ` +
        `silently dropped: ${stray.join(', ')}. Only ${[...ITEM_KEYS].join('/')} are ` +
        `rendered into the builder and verifier prompts. Fold the content into ` +
        `\`detail\` (which both prompts render in full), or extend ITEM_KEYS and the ` +
        `prompt builders together. Refusing to launch: a batch that runs without a ` +
        `constraint an operator wrote is greener than one that never had it.`,
    );
}

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
        ...node.files.map((f) => `  - ${f}${newFilesOf(node).has(f) ? '   [TO BE CREATED — does not exist yet]' : ''}`),
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
        node.exclusive
            ? `SCOPE GATE — skipped: this node is exclusive (repo-wide), so its file list is\n` +
              `incomplete by design. Report scopeGate: 0.`
            : [
                `SCOPE GATE — run this AFTER you commit, and report its exit code as \`scopeGate\`:`,
                ``,
                `    ${scopeGateCmd(node)}`,
                ``,
                `It compares the files you actually changed against the list above. A non-zero`,
                `exit means you edited something this node does not own. That is not a style`,
                `problem: the other builders in this wave are running concurrently and are only`,
                `safe because the partitioner proved your file sets are disjoint.`,
                ``,
                `If it fails, REVERT the undeclared files and amend — do not widen the list.`,
                `A file the fix genuinely needed goes in \`outOfScope\`, unedited.`,
            ].join('\n'),
        ``,
        `Then follow your agent instructions: read the evidence, verify it is still`,
        `accurate, make the smallest correct change, run the anchors, commit, run the`,
        `scope gate.`,
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
        // Mark the created ones for the verifier too. Without it, a file that
        // legitimately appears only as an addition in the diff looks like a
        // builder reaching outside its node, and "added a file it did not own"
        // is a reject a verifier will reach for on sight.
        ...node.files.map((f) => `  - ${f}${newFilesOf(node).has(f) ? '   [this node was required to CREATE this file]' : ''}`),
        ``,
        `THE ITEMS IT CLAIMED TO FIX:`,
        ...node.items.map((it) => `  ${it.id}: ${it.title}\n    evidence: ${it.detail ?? '(see title)'}`),
        ``,
        `WHAT THE BUILDER CLAIMS (treat as an assertion to test, not as fact):`,
        `  status       : ${build.status}`,
        `  filesChanged : ${(build.filesChanged ?? []).join(', ') || '(none reported)'}`,
        `  anchors      : ${JSON.stringify(build.anchors ?? {})}`,
        `  scopeGate    : ${build.scopeGate ?? '(not reported)'}`,
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
                ``,
                node.exclusive
                    ? `This node is exclusive, so the scope gate does not apply. Report observedScopeGate: 0.`
                    : `and the scope gate, from inside that worktree — report it as \`observedScopeGate\`:\n\n` +
                      `    ${scopeGateCmd(node)}`,
                ``,
                `Clean up: git worktree remove /tmp/verify-${slug(node.nodeId)} --force`,
                ``,
                `Report the exit codes you OBSERVED. "It should pass" is not an answer to`,
                `this lens; only an exit code is.`,
            ].join('\n')
            : [
                `Judge only through the \`${lens}\` lens as described in your instructions.`,
                ...(lens === 'intent' ? [
                    ``,
                    `DO NOT spend this lens checking which files were touched. "Did the diff`,
                    `change a file outside the list" is a set difference, and a script already`,
                    `answers it as an exit code on both the builder's side and the anchors lens.`,
                    `Re-deriving it here is slower, less reliable, and displaces the question`,
                    `only you can answer: does this change do what the item actually asked for,`,
                    `and would a user of this code agree it is fixed?`,
                ] : []),
            ].join('\n'),
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
    //
    // A node carrying `prebuilt` SKIPS the builder and is verified as-is. The
    // object is used verbatim where the builder's return value would go, so the
    // lenses cannot tell the difference — which is the entire point, and the
    // reason this is not a separate script with copied prompts.
    //
    // Two uses, and the second is why it exists at all:
    //
    //   RE-JUDGE. A node rejected on scope is often the FILE LIST's fault, not
    //   the builder's. Correcting the list and merging on the standing verdicts
    //   is not the same as a fresh lens judging the corrected node, and until
    //   now re-judging meant re-running a builder over work already done.
    //
    //   CANARY. Plant a branch with a KNOWN defect in it and watch whether the
    //   lenses find it. A run where every node is accepted is consistent with
    //   three working lenses and equally consistent with three that are not
    //   looking, and nothing else in this system can tell those apart — the
    //   reduce fixture proves the reduce classifies bad input correctly, not
    //   that any verifier detects anything.
    //
    // The claimed anchors in a prebuilt object are DELIBERATELY not validated
    // against reality: a canary needs to be able to claim a green it did not
    // earn, so that the claimed-vs-observed comparison has something to catch.
    (node) => (node.prebuilt
        ? Promise.resolve(node.prebuilt)
        : agent(buildPrompt(node), {
            label: `build:${node.nodeId}`,
            phase: 'Build',
            agentType: H.agents.builder,
            isolation: 'worktree',
            schema: BUILD_SCHEMA,
        })),

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
                // OPTIONAL, DEFAULT OFF. Absent, the verifier inherits the main
                // loop's model and this line changes nothing — which is the
                // whole point: a second arm has to face the IDENTICAL prompt,
                // or the comparison measures the prompt rather than the model.
                // Spread rather than `model: H.verifierModel`, because passing
                // an explicit null is not the same as not passing the key.
                ...(H.verifierModel ? { model: H.verifierModel } : {}),
            })),
        ).then((verdicts) => ({ node, build, verdicts: verdicts.filter(Boolean) }));
    },
);

// ── REDUCE — plain code, no model, no tokens ─────────────────────────────────
//
// Everything between the two markers below is a PURE FUNCTION of what came back.
// No agents, no clock, no filesystem, no globals — the same inputs always give
// the same report.
//
// It is fenced off like this because it could not be tested. Workflow scripts
// cannot be imported (no module loader, no filesystem), so for as long as the
// reduce lived inline among the agent calls, selftest.sh could only PARSE this
// file. That left the outcome classification, the fan-in guard and the anchor
// disagreement check — the three things the whole system's honesty rests on —
// as the only load-bearing code in the kit with no test behind it.
//
// selftest.sh now slices the text between these markers out of THIS file and
// evaluates it against fixture results, so the test exercises the shipped code
// rather than a copy of it. If you move or rename the markers, update
// `reduce fixtures` in selftest.sh — it fails loudly if it cannot find them.
//
// ──REDUCE-BEGIN── (sliced by selftest.sh — do not delete this marker)
function reduceWave({ nodes, results, lenses, anchorIds, requiredAnchorIds, requireAllLenses }) {

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
    const allLensesRan = !requireAllLenses || verdicts.length === lenses.length;

    // A scope violation is not a lens opinion, it is an exit code, and it means
    // the builder edited a file another node in this wave may own. Accepting it
    // would void the partitioner's disjointness proof for the whole wave, so it
    // fails the node on its own — a green anchor set on a branch that reached
    // outside its node is a green build of the wrong tree.
    //
    // `null`/undefined is NOT treated as 0. A builder that did not report the
    // gate has not passed it, and defaulting a missing number to success is the
    // exact shape of scar #8: a guard that fails open is the same as no guard.
    const observedGate = verdicts.find((v) => v.observedScopeGate != null)?.observedScopeGate;
    const scopeGate = observedGate ?? r.build?.scopeGate ?? null;
    const scopeClean = scopeGate === 0;

    const accepted = r.build?.status === 'done' && allLensesRan
        && rejects.length === 0 && scopeClean;

    // "Rejected" and "unverified" are DIFFERENT outcomes and must never be
    // collapsed. A node whose verifier crashed has not been judged; reporting it
    // as rejected invents a finding nobody made. The first real run of the
    // original system produced exactly that — five nodes listed as rejected when
    // zero verifiers rejected anything and every lost verdict was a pass.
    //
    // A REPORTED non-zero gate is a finding — somebody ran the check and it
    // failed, so the node is rejected. An UNREPORTED gate is not a finding, it
    // is a question nobody answered, and that is `unverified`. Same distinction
    // as a missing lens, for the same reason.
    const outcome = accepted ? 'accepted'
        : rejects.length > 0 ? 'rejected'
        : r.build?.status !== 'done' ? 'not-built'
        : scopeGate != null && scopeGate !== 0 ? 'rejected'
        : 'unverified';

    const missingLenses = lenses.filter((l) => !verdicts.some((v) => v.lens === l));

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
        scopeGate,
        claimedScopeGate: r.build?.scopeGate ?? null,
        observedScopeGate: observedGate ?? null,
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
    // Only when lenses are actually missing. A node can now be `unverified`
    // because nobody reported the scope gate even though all three lenses ran,
    // and printing "missing []" at the operator sends them looking for a dead
    // verifier that never existed. The scope-gate warning below names that case.
    if (r.outcome === 'unverified' && r.missingLenses.length) {
        warnings.push(
            `${r.nodeId}: UNVERIFIED, not rejected — ${r.verdictsRun}/${lenses.length} verifiers returned, ` +
            `missing [${r.missingLenses.join(', ')}]. No verifier rejected this node; it simply was not judged ` +
            `on those lenses. Re-run verification before treating it either way.`);
    }
    if (r.scopeGate != null && r.scopeGate !== 0) {
        warnings.push(
            `${r.nodeId}: SCOPE VIOLATION — the scope gate exited ${r.scopeGate}. This branch ` +
            `changed a file the node does not own, so the partitioner's disjointness proof no ` +
            `longer holds for this wave. Do not merge it: re-read the diff and re-partition.`);
    }
    if (r.scopeGate == null && r.builderStatus === 'done') {
        warnings.push(
            `${r.nodeId}: the scope gate was never reported by the builder OR the anchors lens. ` +
            `Nobody checked whether this branch stayed inside its file list — that is unverified, ` +
            `not clean.`);
    }
    if (r.claimedScopeGate != null && r.observedScopeGate != null
        && r.claimedScopeGate !== r.observedScopeGate) {
        warnings.push(
            `${r.nodeId}: SCOPE GATE DISAGREEMENT — builder claimed ${r.claimedScopeGate}, ` +
            `verifier observed ${r.observedScopeGate}.`);
    }
    // The builder's claimed exit codes vs what a fresh agent actually observed.
    // A disagreement here is the single most important line this system can
    // produce: it means one of the two is reporting a build that does not exist.
    const claimed = r.claimedAnchors, observed = r.observedAnchors;
    if (claimed && observed) {
        for (const k of anchorIds) {
            // `null` on either side means "did not apply to this diff", which is
            // agreement about a third state, not a mismatch. Comparing it would
            // manufacture the loudest warning this system has on a node where
            // nothing is wrong.
            if (observed[k] != null && claimed[k] != null && observed[k] !== claimed[k]) {
                warnings.push(
                    `${r.nodeId}: ANCHOR DISAGREEMENT on ${k} — ` +
                    `builder claimed ${claimed[k]}, verifier observed ${observed[k]}.`);
            }
        }
    }
    // ...but `null` is only a legitimate answer for a CONDITIONAL anchor. An
    // always-run anchor reported as null is a required check nobody ran, and
    // treating absence as success is scar #8 with a different name.
    for (const k of requiredAnchorIds ?? []) {
        if (r.builderStatus !== 'done') continue;
        if (claimed?.[k] === undefined || claimed?.[k] === null) {
            warnings.push(
                `${r.nodeId}: anchor ${k} runs on every diff and the builder reported no exit ` +
                `code for it. null means "did not apply", and this one always applies — so this ` +
                `is a required check nobody ran, not a check that passed.`);
        }
    }
}

return {
    dispatched,
    returned: returned.length,
    accepted: report.filter((r) => r.outcome === 'accepted').map((r) => r.nodeId),
    rejected: report.filter((r) => r.outcome === 'rejected').map((r) => r.nodeId),
    unverified: report.filter((r) => r.outcome === 'unverified').map((r) => r.nodeId),
    notBuilt: report.filter((r) => r.outcome === 'not-built').map((r) => r.nodeId),
    warnings,
    nodes: report,
};

}
// ──REDUCE-END── (sliced by selftest.sh — do not delete this marker)

const reduced = reduceWave({
    nodes,
    results,
    lenses: LENSES,
    anchorIds: ANCHOR_IDS,
    requiredAnchorIds: H.anchors.filter((a) => a.always !== false).map((a) => a.id),
    requireAllLenses: H.requireAllLenses,
});

log(`wave ${WAVE} done: ${reduced.accepted.length}/${reduced.dispatched} accepted, ${reduced.warnings.length} warning(s)`);

return { batch: BATCH, wave: WAVE, ...reduced };
