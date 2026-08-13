# sprint-harness

A portable build/verify graph for running batches of code work through parallel
agents, with **one human gate at the end instead of one per item**.

Extracted from a working harness on a Next.js + Supabase client project that
shipped nine batches through it. This repo is the generalisation: the machinery
that was never project-specific, separated from the parts that always will be.

> **Not a framework.** It is ~1200 lines of plain code and four documents. The
> documents are the more valuable half.

---

## The model

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

Four properties do the work:

**1. Collision detection is plain code with no model in it.** Two agents editing
one file in two worktrees is the way a fan-out corrupts a repo. That decision is
union-find over declared file sets, printed for you to read *before* anything
runs.

**2. Verifiers never see the builder's context.** A model grading its own output
is far too easy on itself, and a verifier sharing the builder's context is that
same loop wearing a different hat.

**3. The lenses ask different questions, so one reject fails the node.** Three
identical reviewers are a majority vote. Three different questions are three
independent tests.

**4. Anchors, not agreement.** A graph where every node reads another node's
report and they all agree is *consistent and unverified*. What this trusts is exit
codes it watched happen. When a builder claims exit 0 and an independent verifier
observes 1, the report says so — and that line is the single most valuable output
the system produces.

---

## What you get

```
core/                       copied verbatim into a project — never edited
  plan-batch.mjs            the partitioner: union-find, lanes, waves
  sprint-batch.mjs          the graph: fan out → N lenses → plain-code reduce
  preflight.sh              read-only readiness check
  deny-push.sh              PreToolUse hard-deny, fail-closed
  paired-artifact-gate.sh   "changed X must ship changed Y", with an audit trail
  lib/config.mjs            loader; refuses configs that weaken a guarantee
  lib/extract.mjs           citation resolution, state merge, collision report

templates/                  scaffolds you fill in, once per project
  sprint-builder.md         {{REPO_INVARIANTS}} is yours
  sprint-verifier.md        the same invariants, as a skeptic's questions
  SKILL.md                  the /sprint runbook
  extract-queue.mjs         ~40 lines of map-walking is all you write
  MAP.skeleton.json         four structural principles, no domain content

templates/prompts/          copy-paste session prompts, 00 → 05
examples/                   working configs: node-web, go-service
docs/
  RUNBOOK.md                ← start here: new project → first batch, 4–6 sessions
  MAP_GUIDE.md              how to write the map, with real before/after
  SCARS.md                  ← then this: 14 failures and the guards they produced
  DESIGN.md                 what generalises, what cannot, and known gaps
  PORTING.md                per-step detail, and how to tell if it's working
```

---

## Install

```bash
./install.sh /path/to/project --stack node-web
```

Then follow [**docs/RUNBOOK.md**](docs/RUNBOOK.md) — 4–6 sessions to a first green
batch, with a copy-paste prompt per phase in
[`templates/prompts/`](templates/prompts/):

```
  PHASE 0  decide + install                        30 min, human
  PHASE 1  anchors                                 1–2 h    ← before the map
  PHASE 2  map skeleton: structure + traps         1 session
  PHASE 3  audit lanes → openDebt                  1 session, parallel
  PHASE 4  invariants + coverage honesty           half session
  PHASE 5  wire extractor + contracts              1 session
  PHASE 6  a deliberately small first batch        1 session
```

Almost all of that is the map — the one artifact the harness cannot generate for
you. Anchors come **before** it: they are testable in an hour, and the map is
worth nothing without them.

---

## The three layers

Portability depends entirely on nothing leaking upward.

| Layer | What | Portable? |
|---|---|---|
| **Machinery** | partitioner, graph, reduce, guards, gates | copied verbatim |
| **Config** | anchors, setup, lanes, paired artifacts, branch policy | one JSON file |
| **Knowledge** | the map, and which invariants have already burned you | 100% yours |

`core/` never imports from the knowledge layer. Config is the only channel between
them.

---

## Read SCARS.md

[docs/SCARS.md](docs/SCARS.md) is fourteen failures, each with the design decision
it produced. A sample:

- **Lost structured output manufactured five false negatives.** 7 of 18 verifiers
  died on a retry cap trying to emit 3.5KB of prose into one JSON string field.
  Every lost verdict was a `pass`. Fixed with `maxLength: 300` — telling a model
  "be brief" fails under pressure; a schema constraint does not.
- **Agents borrowed `node_modules` from other worktrees** because the contract
  offered an escape hatch "if a fresh install is too slow". All of them took it.
  The anchors then ran against a dependency set that didn't belong to the commit.
  *Any* instruction of the form "if X is slow, do Y instead" will be taken 100% of
  the time.
- **`set -o pipefail` + `grep -q` silently broke a gate.** grep exits on match,
  SIGPIPEs the writer, pipefail reports the pipeline as failed *even though grep
  matched*. A valid waiver was reported as a violation, intermittently.
- **"A component you change ships a test"** sat in an agent contract as prose for
  a week and produced three test files across fifty-one components. It became an
  exit code and started binding immediately.

The pattern: almost none of these announced themselves. Each produced a report
that looked exactly like a good report.

---

## When NOT to use this

If you cannot find two items with no edge between them, there is no graph to
build. A single bug fix, an exploratory question, or anything where you want to
approve each step is cheaper and better as one agent in the main loop.

The coordination is overhead unless the work is wide.

---

## Status

Working code, extracted and generalised; `core/` runs and is exercised by
`selftest.sh`. It has not yet driven a full batch under its generalised config —
the original did, nine times. Known gaps are listed honestly at the end of
[docs/DESIGN.md](docs/DESIGN.md).
