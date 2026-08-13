# Prompt 00 — orientation (the first session in the new project)

**When:** immediately after `install.sh`, in the target project.
**Produces:** a filled `harness.config.json`, verified anchors, and a written
surface inventory that Phase 3 partitions into lanes.
**Do not** let this session write the map. It is establishing ground truth.

Replace `<…>` and paste everything below the line.

---

I am installing a sprint harness into this project — a build/verify graph that
fans work out to parallel agents in isolated worktrees and verifies each node with
independent skeptics. It is already installed at `.claude/harness-core/` with
templates in `.claude/`.

Read these first, in order, and do not skip them — they encode failures that cost
real days:

1. `.claude/harness-core/lib/config.mjs` (the config contract)
2. `~/git_projects/sprint-harness/docs/SCARS.md`
3. `~/git_projects/sprint-harness/docs/RUNBOOK.md` — we are doing **Phase 0 and
   Phase 1 only** in this session

**This session must not write the map, the queue, or any agent contract.** Those
come later and depend on what we establish here.

## Task 1 — anchors

An anchor is a command whose **exit code** the builder reports and an independent
verifier re-runs. It is the only thing this system trusts. Find this project's:

- type/compile check
- linter
- test suite
- any project-specific correctness script already in `package.json` / `Makefile` /
  CI config

For each, tell me the exact command, its working directory, and roughly how long
it takes. **Verify each one can actually FAIL** — a command that prints problems
and exits 0 (like `gofmt -l`) is decorative as an anchor and must be wrapped so it
returns non-zero.

Do not take CI config at face value. Run them.

## Task 2 — the fresh-worktree probe

Builders run in git worktrees, which materialize **only tracked files**. Actually
perform this, do not reason about it:

```bash
git clone . /tmp/harness-probe && cd /tmp/harness-probe
# now run each anchor from Task 1
```

Report exactly what fails and why. Whatever is needed to make them pass is the
`setup` array. Then clean up `/tmp/harness-probe`.

For each setup command, write a `why` that states **what breaks if an agent
improvises a shortcut**. This matters more than it sounds: on the source project
the contract offered "if a fresh install is too slow, verify in place" and every
single agent took it, running anchors against dependency sets that did not belong
to the commit under test.

## Task 3 — the surface inventory

Enumerate every distinct surface of this codebase — each one a place a defect
could live and be missed. For example: schema/migrations, background jobs, HTTP
handlers, the data-access layer, the UI component tree, auth, build/deploy config,
generated code, third-party integrations.

For each: what it is, roughly how big (file/line counts), and how a bug there
would present.

**Be exhaustive rather than tidy.** In Phase 3 these become independent audit
lanes, and anything you omit here becomes a surface nobody ever audits. On the
source project the first audit ran five lanes and none of them touched the UI
component tree; fifty-one components went unexamined and the gap surfaced months
later.

## Task 4 — paired artifacts

Is there a rule here of the form *"if you change X you must also change Y"*?
Component → test, migration → rollback, proto → generated client, public API →
changelog. Name any that exist as a convention, and say whether it is currently
enforced by anything or is just a habit.

## Task 5 — the human gate

Where does verification actually happen — a staging URL, a local docker stack,
`npm run dev`? And does a human or an agent push?

If the honest answer to the first is "we read the diff", say so plainly. Green
anchors are not evidence a change is correct, and I need to know that up front.

## Output

1. A filled-in `.claude/harness.config.json` — anchors, setup, pairedArtifacts,
   git policy. Validate it loads: `node -e 'import("./.claude/harness-core/lib/config.mjs").then(m=>m.loadConfig())'`
2. `docs/SURFACE.md` — the Task 3 inventory. This is the input to Phase 3.
3. A short list of anything you could not determine, stated as a question.

Flag disagreements rather than guessing. If an anchor is slow, unreliable, or
tests almost nothing, tell me — I would rather know now than discover it when a
batch reports green against a check that proves nothing.
