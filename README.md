# sprint-harness

A portable build/verify graph for running batches of code work through parallel
agents, with **one human gate at the end instead of one per item**.

Extracted from a working harness on a Next.js + Supabase client project that
shipped nine batches through it. This repo is the generalisation: the machinery
that was never project-specific, separated from the parts that always will be.

> **Not a framework.** It is ~1700 lines of plain code — 1026 of them excluding
> comments and blanks — and six documents. The documents are the more valuable
> half.

---

## The model

<img width="1200" height="630" alt="og-diamond" src="https://github.com/user-attachments/assets/333c84d5-a546-49c7-9c50-219d0762429a" />


### Full Graph

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
  RUNBOOK-SMALL.md          compressed path for 1–3 surfaces, + the sizing fork
  MAP_GUIDE.md              how to write the map, with real before/after
  SCARS.md                  ← then this: 19 failures and the guards they produced
  DESIGN.md                 what generalises, what cannot, and known gaps
  PORTING.md                per-step detail, and how to tell if it's working
```

---

## Install

The kit stays here. It installs **into** a project — you never copy or paste it in.

```bash
git clone # clone this repo wherever you want to store the full harness and examples, etc...
cd /path/to/your-existing-project # go to whichever project you want to use the harness in
git checkout -b chore/sprint-harness # create a harness branch for initial setup
~/git_projects/sprint-harness/install.sh . --stack node-web # read the runbook along side your install for steps

git add .claude && git commit -m "chore: install sprint harness" # This can't be skipped
 # the agents can only see/use what is tracked because they fan out using worktrees. Not tracked = broken
```

That second command is load-bearing. Builders run in git worktrees, which
materialize **only tracked files** — so a gitignored `.claude/` means a builder's
worktree contains no harness at all, and an anchor invoking a script under it does
not fail, it *is not there*. `install.sh` refuses quietly to let that pass: it
checks and stops you loudly.

Then open a session in that project and paste the first prompt.

> **`templates/` stays in this clone; it is not copied into your project, and
> that is intentional.** The prompts and [`MAP.skeleton.json`](templates/MAP.skeleton.json)
> are adoption material for *you*, not runtime material for the harness — nothing
> in `core/` reads them. Keep this repo checked out somewhere while you work
> through the runbook and reference them from here; the paths in the docs assume
> `~/git_projects/sprint-harness`, so adjust if you cloned elsewhere.

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

**Smaller project?** [docs/RUNBOOK-SMALL.md](docs/RUNBOOK-SMALL.md) compresses this
to 3–4 light sessions, and opens with a sizing fork — because the harness has two
halves that pay off at different sizes. The **spine** (map, anchors, push guard,
paired-artifact gate) is worth having on a one-person project. The **graph**
(queue, partitioner, fan-out, N-lens verify) needs work that is genuinely wide.
Taking only the spine is a legitimate outcome, and adopting the graph later costs
one session with nothing wasted.

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

[docs/SCARS.md](docs/SCARS.md) is nineteen failures, each with the design decision
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

Working code, extracted and generalised. `core/` runs and is exercised by
`selftest.sh` — 81 assertions, currently green.

**Batches driven under the generalised config: two.** Both on a small Astro site
with no test suite and no linter, which is a useful stress of the "anchors are
whatever exits non-zero" claim:

| batch | dispatched | nodes | waves | rejected |
|---|---|---|---|---|
| batch-1 | 6 | 4 | 1 | 0 |
| batch-2 | 6 | 5 | 1 | 0 |

Those two batches produced scars 17, 18 and 19. The original, project-specific
version drove nine.

**Read the acceptance rate as a gap, not a result.** 10 of 10 nodes accepted
first-pass means the lenses agreed with the builders; it does not mean the
builders were right, and it does not show the harness catching bad work, because
**it has not yet been given any.** The one run that genuinely exercised the verify
stage is the batch where 3 of 3 nodes were green on every anchor and all 3 were
rejected on semantics — and that ran under the original, not this.

Known gaps are listed honestly at the end of [docs/DESIGN.md](docs/DESIGN.md).

---

## License

[MPL-2.0](LICENSE). File-level copyleft: keep the notice, and publish your
changes *to these files*. Deliberately **not** GPL — `install.sh` copies `core/`
into your repository, and a whole-work copyleft would reach the project you
installed it into. Your code stays yours; the harness stays open.
