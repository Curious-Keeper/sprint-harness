# Prompt S1 — bootstrap (small project)

**Collapses:** full-runbook prompts 00 + 01.
**When:** Session A, immediately after `install.sh`.
**Produces:** verified anchors, `harness.config.json`, a short surface inventory,
and `APP_MAP.json` with structure + `evolutionTraps` — but **no `openDebt`**.

Only use this on a project that passed the sizing fork in
[`docs/RUNBOOK-SMALL.md`](../../docs/RUNBOOK-SMALL.md). On a larger codebase run
00 and 01 separately.

Replace `<…>` and paste everything below the line.

---

I am installing a sprint harness into this project — a build/verify graph that
fans work out to parallel agents in isolated worktrees and verifies each node with
independent skeptics. It is installed at `.claude/harness-core/` with templates in
`.claude/`. This is a small codebase, so we are running the compressed path.

Read first, and do not skip — these encode failures that cost real days:

1. `~/git_projects/sprint-harness/docs/SCARS.md`
2. `~/git_projects/sprint-harness/docs/MAP_GUIDE.md`
3. `~/git_projects/sprint-harness/docs/RUNBOOK-SMALL.md`

**Hard boundary for this session: do NOT write `openDebt`, the queue, or any
agent contract.** Findings come from independent audit passes in the next
sessions. A session that has just read the whole codebase is contaminated as an
auditor — it will confirm the assumptions it absorbed rather than test them. If
you notice things that smell like defects, collect them in a separate list and
hand them to me. Do not put them in the map.

## Task 1 — anchors, and prove they can fail

An anchor is a command whose **exit code** the builder reports and an independent
verifier re-runs. It is the only thing this system trusts. Find this project's
compile/type check, linter, test suite, and any correctness script already in
`package.json` / `Makefile` / CI.

Run each. Report the exact command, working directory, and duration.

**Verify each can actually FAIL.** A command that prints problems and exits 0
(like `gofmt -l`) is decorative as an anchor and must be wrapped so it returns
non-zero. Demonstrate at least one going red on purpose.

Do not take CI config at face value.

## Task 2 — the fresh-worktree probe

Builders run in git worktrees, which materialize **only tracked files**. Actually
perform this — do not reason about it:

```bash
git clone . /tmp/harness-probe && cd /tmp/harness-probe
# run each anchor from Task 1
```

Report exactly what fails. Whatever is needed to make them pass is the `setup`
array. Clean up `/tmp/harness-probe` afterwards.

For each setup command write a `why` stating **what breaks if an agent improvises
a shortcut**. On the source project the contract offered "if a fresh install is
too slow, verify in place" and every single agent took it, running anchors against
dependency sets that did not belong to the commit under test.

## Task 3 — surface inventory (short)

List every distinct surface of this codebase — each a place a defect could live
and be missed. For each: what it is, rough size, and how a bug there would
present.

This can be a few paragraphs rather than a document, but **write it down** — it
determines how we split the audit passes. Be exhaustive rather than tidy;
anything you omit becomes a surface nobody ever audits.

Then tell me directly: **does this project have 1 surface, or 2–3?** It changes
how the next two sessions are split, so do not hedge.

## Task 4 — paired artifacts

Is there a rule here of the form *"if you change X you must also change Y"*?
Component → test, migration → rollback, proto → generated client, API →
changelog. Name any that exist, and say whether anything currently enforces it or
it is just a habit.

## Task 5 — the map: structure and traps only

Build `<docs/app-maps/APP_MAP.json>` from
`~/git_projects/sprint-harness/templates/MAP.skeleton.json`.

**The one rule: record CONSEQUENCES, not structure.** You can read the directory
listing, the route table and the schema — so can every future agent. What none of
you can read is the trigger that turns a Save button into a raw database
exception, or the column dropped four months ago that still appears in half the
codebase. Structure is free; consequences are the map's entire value.

- **`meta`** — today's date, HEAD sha, branch, working-tree state, and real counts
  per surface. Derive counts with commands and show me the command.
- **`architecture`** — one line per element saying what it is *for* and anything
  non-obvious. Where two things look interchangeable but are not, say so. Where a
  name is misleading, say so.
- **`evolutionTraps`** — facts that USED to be true. Mine these mechanically:

  ```bash
  git log -p --diff-filter=M -- <migrations dir> | grep -iE '^\+.*(DROP|RENAME)'
  git log --diff-filter=D --name-only --format='%h %ad %s' --date=short
  git log --diff-filter=R --name-status --format='%h %ad %s' --date=short
  ```

  Then **grep for each hit** — a trap nothing references any more is just history;
  one something still references is a live finding for the next session. Put the
  negation in ALL-CAPS, because the reader currently believes the opposite:

  > `orders.freight_charge` **DOES NOT EXIST** — dropped in 0074. Any code or doc
  > referencing the column is pre-0074.

  On a young project this section may be nearly empty. That is fine — still run
  the commands.
- **generated files** and the exact command that produces each. An agent that
  hand-edits one produces a diff that vanishes on the next build.
- **empty scaffolding** for `openDebt`, `plannedWork`, `decisionsOwed`,
  `externalState`, `shipped`, `sprintHarness`. Sections split by
  **dispatchability, not topic** — `decisionsOwed` and `externalState` must never
  reach a builder, because an agent asked to check a DNS record or a SaaS console
  will report on what it can see locally and present it as the answer.

## Output

1. `.claude/harness.config.json`, validated:
   `node -e 'import("./.claude/harness-core/lib/config.mjs").then(m=>m.loadConfig())'`
2. `<docs/app-maps/APP_MAP.json>`, valid JSON, `openDebt` empty.
3. The surface inventory, and your 1-vs-2-3 answer.
4. **A separate list of things that smell like debt** — NOT written into the map.
5. Anything you could not determine, as a question.

Flag disagreements rather than guessing. If an anchor is slow, unreliable, or
tests almost nothing, say so now — I would rather know than discover it when a
batch reports green against a check that proves nothing.
