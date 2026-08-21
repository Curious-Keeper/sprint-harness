---
name: sprint
description: Run a batch of queue work through the build/verify graph. Use when the user hands over a list of changes, fixes or features to work through, says "run a sprint", "work the queue", "next batch", or asks what is left to do. Also use to add newly-requested work to the queue.
---

<!--
TEMPLATE. Copy to .claude/skills/sprint/SKILL.md and adapt the marked sections.
Project-specific: the {{HUMAN GATE}} step, which encodes YOUR verification path.
Everything else is portable.
-->

# Sprint

Turns a list of work into merged, verified commits with **one** human gate at the
end instead of one per item.

## The shape

```
  your list ─→ [intake] ─→ QUEUE.json
                              │
                     [plan-batch.mjs]      plain code — collision detection
                              │            NEVER a model
        ┌──────────┬──────────┼──────────┐   wave 0: fan out, worktree each
      build      build      build      build
        │          │          │          │
     verify×N   verify×N   verify×N   verify×N  fresh context, N lenses
        └──────────┴────┬─────┴──────────┘
                   [reduce]                 returned vs dispatched, anchor
                        │                   claimed vs anchor observed
                  [integrate]               integrate.sh: wave order, merged anchors
                        │
                  ┌ HUMAN GATE ┐            you read ONE report, ONE diff
                        │
                       PR
```

## Files

| Path | What it is |
|---|---|
| `.claude/harness.config.json` | the only project-specific config `core/` reads |
| `.claude/work/QUEUE.json` | sprint state — status, batch, files, evidence |
| `.claude/work/extract-queue.mjs` | rebuilds the queue from the map, preserving sprint state |
| `core/plan-batch.mjs` | partitions items into collision-free nodes and waves |
| `core/sprint-batch.mjs` | the build+verify graph, one wave per invocation |
| `core/preflight.sh` | read-only readiness check |
| `core/paired-artifact-gate.sh` | "changed X must ship changed Y", as an exit code |
| `core/scope-gate.sh` | "this node may only touch the files it owns", as an exit code |
| `core/integrate.sh` | wave-order merge + anchors on the merged tree, no model |
| `core/reduce-fixture.mjs` | tests the reduce against known-bad results, zero agents |
| `.claude/agents/sprint-builder.md` | implements one node in an isolated worktree |
| `.claude/agents/sprint-verifier.md` | one lens, fresh context, default REJECT |

The MAP stays read-only — it records what is true about the code. `QUEUE.json` is
sprint state and is the only one a sprint mutates.

## Step 0 — pre-flight, every batch

```bash
core/preflight.sh
```

Checks the worktree, a clean tree, the base branch, the push guard, the queue and
the map. Read-only; exits non-zero if anything is off. **Do not start a batch on
a red pre-flight** — a sprint from a stale base rebuilds work that already landed.

## 1. Refresh and pick

If the map changed since the last run:

```bash
node .claude/work/extract-queue.mjs --write     # preserves status/batch/notes
```

Then pick items. Either propose the cheapest safe set:

```bash
node core/plan-batch.mjs --auto 8
```

or name them:

```bash
node core/plan-batch.mjs item-a item-b item-c
```

## 2. READ THE PARTITION before running anything

This is the step that earns the whole system. It tells you:

- which items got **merged into one serial node** because they collide
- which went into a **lane** (forward-only numbering — two agents cannot both
  mint the next migration number)
- which are **repo-wide** and must run alone in a later wave
- which were **REFUSED** as `unscoped` — no files derivable, so no collision
  guarantee. Add an `OVERRIDES` entry in `extract-queue.mjs` before dispatching.
- which files are touched **across waves**
- **`NOT A GRAPH`** advisories — a fan-out width below 2 means nothing here runs
  in parallel with anything, so the batch costs one builder plus N verifiers to
  do what the main loop does with one agent. `--auto` refuses to propose such a
  batch outright; naming ids explicitly only warns, because re-verifying a single
  rejected node is a legitimate thing to want.

If the partition looks wrong, the fix belongs in `extract-queue.mjs`, **not in
the prompt**. Collision detection must stay deterministic.

Also read what the **extractor** printed. `INVISIBLE FILE TYPES` means a tracked
file was cited by an item but its extension is not in `extract.fileExtensions` —
the collision graph cannot see it, and two items editing it would be fanned out
in parallel. Fix it in `harness.config.json`, not in `core/`.

`UNRESOLVED / AMBIGUOUS citations` is the other half of the same warning. An
ambiguous basename means the graph has a hole exactly where you cannot see it;
fix it with an alias or a `dirHint` in the extractor, never by ignoring it.

## 3. Run the wave

```bash
node core/plan-batch.mjs <ids...> --json > /tmp/plan.json
```

Then invoke the workflow with that plan as `args`, adding `batchName`, `wave` and
`baseBranch`:

```
Workflow({
  scriptPath: "core/sprint-batch.mjs",
  args: { ...plan, batchName: "batch-3", wave: 0, baseBranch: "<the sprint base>" }
})
```

`baseBranch` is required and is the branch builders start from — **NOT the main
branch**. The anchors frequently only exist on the sprint base (a test runner
that was only just installed, a type generic that was only just wired). A builder
branching from main would be judged by a weaker set of checks than the batch is
being held to.

Two things that will bite:

- **`args` may arrive as a JSON string rather than an object**, depending on how
  the tool serialises it. The script parses either. If you see `args must be the
  plan object`, that is what happened.
- **Keep the plan JSON free of characters that get mangled in transit** — smart
  quotes and raw `<`/`>` inside evidence strings have caused a launch to fail
  before any agent ran. The failure is cheap (zero agents, zero tokens) but it is
  confusing if you do not know to look for it.

## 4. Read the reduce output

Three things matter more than the pass count:

- **`warnings`** — a node that returned nothing, a lens that did not run, a
  **SCOPE VIOLATION** (the branch changed a file the node does not own), or an
  **ANCHOR DISAGREEMENT** (builder claimed exit 0, verifier observed non-zero).
  That last one is the most important line the system can produce. `integrate.sh`
  refuses to merge a report that carries any of them.
- **`rejects`** — each carries the lens and the evidence. A single reject fails
  the node; the lenses ask different questions, so one reject is a finding, not
  an outvoted opinion.
- **`staleEvidence`** — map citations that no longer matched the code. These are
  findings about the MAP and should be fed back into it.

`unverified` is **not** `rejected`. A node whose verifier crashed has not been
judged. Re-run verification before treating it either way.

### A scope reject is not automatically a builder error

When a lens rejects a node for touching a file outside its list, **read which of
the three is wrong before re-dispatching**:

| Wrong thing | What it looks like | What to do |
|---|---|---|
| the builder | it wandered; the extra file has nothing to do with the item | re-dispatch as-is |
| the lens | it misread the diff | re-verify |
| **the FILE LIST** | the fix genuinely could not be made inside it | **fix the list, then re-dispatch** |

On a live project the list was the wrong one twice in one week, and re-running a
builder against the same wrong list just reproduces the reject. Two shapes cause
it, and both are now handled automatically — a `pairedArtifacts` counterpart and
a `COMPANIONS` entry both land in the file set without a citation — so a scope
reject today more often means the item cited where a thing is *declared* and not
where it is *constructed*. Check that first.

The other tell is `not-built` with a populated `staleEvidence` or `outOfScope`.
That is usually a builder that correctly **cut the feature** rather than touch an
undeclared file. It reads like a failure in the report and it is not one; it is
the file list asking to be corrected.

## 5. Integrate

Save the workflow's return value to a file, then:

```bash
core/integrate.sh <sprint-base> /tmp/plan.json /tmp/report.json --dry-run
core/integrate.sh <sprint-base> /tmp/plan.json /tmp/report.json
```

This is a script and not a checklist because every way of getting it wrong by
hand is silent. It merges **only** `accepted` nodes, **in wave order**, then
re-runs the scope gate and the anchors **on the merged tree** — per-node green
does not imply merged green, since each branch was verified alone by an agent
that never saw the others in its wave.

It refuses to start if the report carries any warning, aborts on a conflict
rather than letting you hand-resolve one (a conflict between two accepted nodes
means the *partition* was wrong — those items should have been one serial node),
and never merges an `unverified` node.

If `regenerate` is configured, it rebuilds those artifacts after the scope gate
and before the anchors, and commits the diff with the merge. A generated file is
the paired artifact of every file that feeds it and no node's file list can name
it — so without this, every anchor is green while the committed artifact silently
stops matching the source, and CI notices after the merge.

Before you leave this step, check the map: **an item you closed must be MOVED to
`shipped`, not marked done in place.** An id sitting in both places comes back as
`open` next batch, and a builder handed an item whose fix is already present
reports it done without changing anything — indistinguishable from a node that
did nothing.

Anchors come from `harness.config.json`, so there is nothing project-specific to
fill in here.

## 6. The human gate

<!-- {{HUMAN GATE}} ─────────────────────────────────────────────────────────

REPLACE THIS BLOCK with your project's verification path — the deploy script, the
staging URL, the manual smoke test.

Whatever it is, keep the principle: **a green anchor set is not evidence a change
is right.** The batch is not done when the merge is green; it is done when a
human has exercised the actual behaviour.

State plainly who pushes and when. If pushing is human-only here, say so — and
back it with the PreToolUse hook, not just this sentence.

──────────────────────────────────────────────────────────────────────────── -->

## Adding new work

When the user hands over a fresh list, do NOT rebuild the queue from scratch —
match each request against existing ids first. Most "new" asks are already in
there under an existing tag, and duplicating one means two agents fixing the same
thing in different files.

For genuinely new items, add them to the MAP (the map is where facts live), then
re-run the extractor. An item needs `files` to be dispatchable — if you cannot
cite one, it is not ready to hand to a builder.

## When NOT to use this

If you cannot find two items with no edge between them, there is no graph to
build. A single bug fix, an exploratory question, or anything where the user wants
to approve each step is cheaper and better as one agent in the main loop. The
coordination is overhead unless the work is wide.

Also skip it for items whose truth lives outside the repo. Dispatching a builder
at those produces confident fiction.

## The rule that keeps this honest

**Anchors, not agreement.** A graph where every node reads another node's report
and they all agree is consistent and unverified. What this system trusts is exit
codes it watched happen and a verifier that never saw the builder's context.
Judge it on numbers that cannot argue back.
