---
name: sprint
description: Run a batch of queue work through the build/verify graph. Use when the user hands over a list of changes, fixes or features to work through, says "run a sprint", "work the queue", "next batch", or asks what is left to do. Also use to add newly-requested work to the queue.
---

<!--
TEMPLATE. Copy to .claude/skills/sprint/SKILL.md and adapt the marked sections.
Project-specific: the {{INTEGRATE}} and {{HUMAN GATE}} steps, which encode YOUR
deploy and verification path. Everything else is portable.
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
                  [integrate]               merge in wave order, re-run anchors
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

If the partition looks wrong, the fix belongs in `extract-queue.mjs`, **not in
the prompt**. Collision detection must stay deterministic.

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

- **`warnings`** — a node that returned nothing, a lens that did not run, or an
  **ANCHOR DISAGREEMENT** (builder claimed exit 0, verifier observed non-zero).
  That last one is the most important line the system can produce.
- **`rejects`** — each carries the lens and the evidence. A single reject fails
  the node; the lenses ask different questions, so one reject is a finding, not
  an outvoted opinion.
- **`staleEvidence`** — map citations that no longer matched the code. These are
  findings about the MAP and should be fed back into it.

`unverified` is **not** `rejected`. A node whose verifier crashed has not been
judged. Re-run verification before treating it either way.

## 5. Integrate

Merge accepted branches in wave order, then re-run the anchors **on the merged
tree** — per-node green does not imply merged green.

<!-- {{INTEGRATE}} — replace with your project's merged-tree anchor commands -->

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
