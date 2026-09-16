# sprint-harness

`sprint-harness` is a portable workflow for running wide code work through
isolated agents, independent verifier lenses, and one human gate at the end.

It was extracted from a Next.js + Supabase project that shipped nine batches
with a project-specific version. This repo holds the reusable part: the graph,
guards, installer, templates, and the adoption docs.

The goal is not to remove judgment. The goal is to replace one approval per item
with one reviewable batch report, without trusting agents to coordinate with each
other.

## The model

<img width="1200" height="630" alt="og-diamond" src="https://github.com/user-attachments/assets/333c84d5-a546-49c7-9c50-219d0762429a" />

```text
  map or queue ─→ [extract] ─→ QUEUE.json
                                  │
                         [plan-batch.mjs]
                                  │
                 union-find over declared files
                                  │
        ┌──────────┬──────────────┼──────────┐
      build      build          build      build     one worktree per node
        │          │              │          │
     verify      verify        verify      verify    fresh context, N lenses
        └──────────┴──────┬───────┴──────────┘
                        reduce                         plain code
                          │
                     integrate.sh                      wave order, anchors on merged tree
                          │
                    human gate                         one report, one diff
                          │
                         PR
```

Four rules do the work:

1. **The partition is code, not a model.** File-set collisions are union-find over
   declared paths. The plan prints before any agent runs.
2. **Verifiers do not share the builder's context.** A verifier starts from the
   branch and the contract, not from the builder's explanation.
3. **Lenses ask different questions.** One rejecting lens rejects the node. Three
   identical reviewers are only a vote.
4. **Anchors beat agreement.** The reducer trusts exit codes that it watched
   happen. If a builder claims exit 0 and a verifier observes exit 1, the report
   names the disagreement.

## What is in this repo

```text
core/
  plan-batch.mjs            builds the waves and collision graph
  sprint-batch.mjs          runs build, verify, reduce, and optional confirm pass
  integrate.sh              merges accepted nodes in wave order and reruns anchors
  scope-gate.sh             rejects undeclared file changes
  paired-artifact-gate.sh   enforces "changed X must ship changed Y"
  preflight.sh              read-only readiness check
  deny-push.sh              fail-closed push guard for agent sessions
  serialize.sh              host-wide lock wrapper for contended anchors
  reduce-fixture.mjs        mutation-tested reducer fixtures, no agents required
  canary.mjs                plants known defects and scores verifier detection
  models.mjs                reports project model roles and local reachability
  lib/                      config, extraction, model, and dispatch helpers

templates/
  sprint-builder.md         builder contract with repo invariants inserted
  sprint-verifier.md        verifier contract with lens questions
  SKILL.md                  installed /sprint workflow
  extract-queue.mjs         project-owned map-to-queue adapter
  MAP.skeleton.json         minimal map shape
  prompts/                  copy-paste adoption prompts for full and small tracks

examples/
  node-web.harness.config.json
  go-service.harness.config.json

docs/
  RUNBOOK.md                full adoption path
  RUNBOOK-SMALL.md          smaller-project path and sizing fork
  MAP_GUIDE.md              how to write dispatchable map entries
  MODELS.md                 model roles, provider catalog, and runners
  SCARS.md                  38 failures and the guards they produced
  DESIGN.md                 what generalises, what cannot, and known gaps
  PORTING.md                detailed porting notes
```

## Install into a project

The kit stays in this clone. `install.sh` copies the runtime into another git
repo under `.claude/`.

```bash
git clone <this-repo-url> ~/git_projects/sprint-harness
cd /path/to/your-existing-project
git checkout -b chore/sprint-harness
~/git_projects/sprint-harness/install.sh . --stack node-web

git add .claude
git commit -m "chore: install sprint harness"
```

Do not skip the commit. Builders run in git worktrees, and worktrees contain only
tracked files. If `.claude/` is ignored or uncommitted, the builder worktree does
not contain the harness.

Then follow the runbook:

- Use [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for the full track.
- Use [`docs/RUNBOOK-SMALL.md`](docs/RUNBOOK-SMALL.md) for a project with one to
  three surfaces.
- Use [`templates/prompts/`](templates/prompts/) as the copy-paste session prompts.

The prompts assume this repo lives at `~/git_projects/sprint-harness`. Adjust the
paths if you clone it somewhere else.

## Adoption shape

The full track is usually four to six working sessions:

```text
PHASE 0  decide and install
PHASE 1  anchors
PHASE 2  map skeleton and evolution traps
PHASE 3  audit lanes into openDebt
PHASE 4  invariants and coverage gaps
PHASE 5  extractor and contracts
PHASE 6  small first batch
```

The map is the main work. The harness can plan from a hand-maintained queue, but
it gets most of its value when the queue is derived from a map with real
`file:line` evidence.

## Configuration layers

Portability depends on keeping three layers separate.

| Layer | Contains | Edited where |
|---|---|---|
| Machinery | graph, reduce, guards, gates | copied from `core/` |
| Config | anchors, lanes, paired artifacts, model roles | `.claude/harness.config.json` |
| Knowledge | map entries, invariants, coverage gaps | your project docs |

`core/` never imports project knowledge. Config is the only channel between the
runtime and the consumer project.

## Model and provider setup

Projects can name roles such as `builder`, `verifier`, `reviewer`, `planner`,
`scope`, and `summarizer` in `.claude/harness.config.json`. Local provider and
runner availability belongs in:

```text
~/.config/sprint-harness/models.json
```

Check a project with:

```bash
node .claude/harness-core/models.mjs status
```

The status command reports which roles resolve, which reviewers are reachable,
which runner would be used, and whether the reviewer roster is actually
cross-vendor. It never prints secret values. See [`docs/MODELS.md`](docs/MODELS.md).

## When not to use it

Do not use the graph when the work is not wide.

If you cannot find two queued items with no edge between them, use one agent in
the main loop. A single bug fix, an exploratory design question, or work that you
want to approve step by step does not need this coordination cost.

On small projects, the spine can still be useful without the full graph: map,
anchors, push guard, and paired-artifact gate.

## Current status

The core scripts run locally under `selftest.sh`.

```text
338 assertions passing
```

The canary rig now plants known defects on prebuilt branches and scores whether
verifier lenses catch them. That closed the older gap where the generalized
harness had not shown its verify stage rejecting bad work. The remaining known
gap is variance: identical verifier runs can disagree on a real defect, so
`verify.confirmAccepted` exists for high-risk batches and is off by default
because it doubles verifier spend.

Read [`docs/SCARS.md`](docs/SCARS.md) before simplifying guards. Most entries are
failures that produced clean-looking reports.

## License

[MPL-2.0](LICENSE). File-level copyleft applies to the harness files. Your
consumer project remains yours.
