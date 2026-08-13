# Porting the harness to a new project

Order matters. Each step makes the next one checkable.

---

## Before you start: is this project even a candidate?

Three questions. **If any answer is no, stop** — you will spend a day building
coordination for work that doesn't need it.

1. **Do you have ≥8 queued items with no edges between most of them?** If the
   backlog is five things that all touch the same module, run them serially in the
   main loop.
2. **Can a command tell you the code is broken?** Without anchors, "verify"
   degrades to models agreeing with each other, which is the exact failure this
   exists to prevent. A project with no test suite gets a *worse* result from this
   harness than from careful single-agent work.
3. **Is there a human who will actually gate?** The system converts one gate per
   item into one gate per batch. It does not remove it. Nobody reading the reduce
   output means the graph is theatre.

---

## Step 1 — anchors first, before anything else

Fill in `anchors` in `harness.config.json` and run each command by hand on a clean
checkout.

**The question that catches the most bugs:** *what does a tree containing only
tracked files lack?* Clone your repo into `/tmp` and try. Whatever fails is your
`setup` array.

- Node → `node_modules` is gitignored. `npm ci`.
- Python → `.venv`. `uv sync` or `pip install -e .`
- Go → usually nothing; the module cache is per-machine.
- Rust → usually nothing; `~/.cargo` is per-machine, though a cold build is slow.

Write the `why` field on every setup entry, and make it say what *breaks* if the
agent improvises a shortcut. Agents skip steps whose cost they cannot see — see
scar #3, where an escape hatch offered once was taken by every single agent.

**Make sure each anchor can actually fail.** `gofmt -l .` prints unformatted files
and exits 0. As an anchor it is decorative. Wrap it: `test -z "$(gofmt -l .)"`.

> **Checkpoint:** every anchor runs green on a fresh clone, and you have seen at
> least one of them go red on purpose.

---

## Step 2 — the map

Start from `templates/MAP.skeleton.json`.

**Do not try to auto-generate it.** Every attempt produces a file that describes
*structure* — which any agent can read from the code anyway — rather than
*consequences*, which is the only thing worth writing down. The map's value is
knowledge nobody can derive from the tree:

- columns and tables that **do not exist** despite older code implying they do
- a contract that looks like style but is data integrity
- a trigger that turns a UI Save button into a raw database exception
- two copies of a function in two runtimes that must change in lockstep

Rules that earn their keep:

- **Evidence is a `file:line` citation, not a description.** The builder verifies
  the citation still says what it claims before changing it, and reports
  `staleEvidence` when it doesn't. Map rot becomes a tracked finding instead of
  silent drift.
- **Name only the files you intend to EDIT.** Any path mentioned in an item's
  prose — even in passing — lands in that item's file set and can manufacture a
  false collision. Describe cross-references without paths. (Scar #10.)
- **Closed work MOVES to `shipped`.** It does not sit in the queue with
  `status: done`.
- **COMMIT IT.** Builders run in worktrees, which materialize only *tracked*
  files. An uncommitted map means every builder plans from the previous commit's
  evidence while you read the new one. (Scar #5.)

> **Checkpoint:** the map is committed, and you can point at three entries that
> an agent could not have derived by reading the code.

---

## Step 3 — the extractor

Copy `templates/extract-queue.mjs`, adapt the `{{EXTRACTION}}` block to walk your
map's sections. That is the ~40 lines you actually write; everything else is
imported from `core/lib/extract.mjs`.

Run it **without** `--write` first and read three things:

- **UNRESOLVED / AMBIGUOUS citations** — every one is a hole in the collision
  graph, exactly where you cannot see it. Fix with an alias, a `dirHint`, or an
  `OVERRIDES` entry. Do not proceed with holes.
- **collisions** — files claimed by more than one open item. This is the map
  telling you which work is genuinely entangled.
- **scopes** — how many items came out `unscoped`. A high count means your map
  describes work without citing files.

The scope taxonomy is where the judgement lives:

| scope | means |
|---|---|
| `bounded` | files known — dispatchable |
| `repo-wide` | real but unbounded; runs alone in its own wave |
| `unscoped` | extractor couldn't derive files → pin them in `OVERRIDES` |
| `needs-design` | *nobody* can scope it yet. Scoping **is** the work. |
| `external` | truth lives outside the repo — a builder would invent facts |
| `held` | buildable, but a human said not yet. **Requires a note.** |

`unscoped` vs `needs-design` is a real distinction, and the fix differs: one is a
missing override, the other is a missing decision.

> **Checkpoint:** zero unresolved citations; you have read the collision list and
> it matches your intuition about the codebase.

---

## Step 4 — the invariants

Fill `{{REPO_INVARIANTS}}` in `sprint-builder.md`, then the mirrored checklist in
`sprint-verifier.md`. They are stated **twice on purpose** — the verifier must be
able to check an invariant without having read the builder's contract.

**The bar for an entry: it has already caused a real bug here.** A list padded
with plausible-sounding rules trains every agent to skim the whole section, which
costs you the entries that matter.

Write each as *rule → concrete failure mode*. Compare:

> ❌ "Preserve the hidden-input contract."
>
> ✅ "Pickers carry the ID in a hidden `<input name=…>` while the visible control
> is name-less. A control whose visible input carries the name submits the display
> LABEL instead of the id — silent data corruption on contact creation."

The second one an agent cannot rationalise its way past.

> **Checkpoint:** every invariant names a failure you have personally seen.

---

## Step 5 — the gates

**The push guard.** `install.sh` wires it. Test it:

```bash
echo '{"tool_input":{"command":"git push"}}'   | .claude/hooks/deny-push.sh   # denies
echo '{"tool_input":{"command":"git status"}}' | .claude/hooks/deny-push.sh   # silent
```

If you skip this, understand what you are choosing. An instruction is a suggestion
to a model: on the source project an agent walked around an instruction-level
blocklist by writing its own client, and the approval log showed 13 verdicts and 0
denials while the quarantined command ran anyway.

**Paired artifacts.** Configure at least one rule. The canonical one is
component → test, but the shape covers handler → integration test, migration →
rollback, proto → generated client, public API → changelog.

The general test for whether something belongs here: **you have written it in an
agent contract as prose and it did not bind.** That is the signal to make it an
exit code.

> **Checkpoint:** the push guard denies; the paired gate exits non-zero on a
> deliberately unpaired change.

---

## Step 6 — a deliberately small first batch

Two or three genuinely independent `bounded` items. The first batch is testing the
*harness*, not the backlog.

```bash
.claude/harness-core/preflight.sh
node .claude/harness-core/plan-batch.mjs --auto 3
node .claude/harness-core/plan-batch.mjs <ids...> --json > /tmp/plan.json
```

Then invoke the workflow with `batchName`, `wave: 0`, and a `baseBranch` that is
**not** your main branch — the anchors often only exist on the sprint base.

**Read the reduce output for the harness, not the code:**

- Did every dispatched node return? (`dispatched` vs `returned`)
- Did every lens return for every node? A missing lens is scar #1.
- Any **ANCHOR DISAGREEMENT**? There is no benign explanation — either a builder
  reported a green it didn't see, or one of the two ran against the wrong tree.
- Any `staleEvidence`? Feed it back into the map. That is the map improving.

Expect the first batch to find harness bugs. That is what it is for.

---

## Optional pattern: the two-worktree lifecycle

Deliberately **not** baked into `core/`. Adopt it only if verification needs a
full stack that your publishable tree cannot contain.

The source project keeps two worktrees of one repo:

```
  project-next                              project-demo
  ────────────                              ────────────
  the ONLY place anything is pushed         carries the local stack
                                            NEVER pushed, no remote
        │                                         │
  1  preflight, branch, build, commit             │
        │                                         │
        │  2  verify/batch-N  ◄── branch from the demo branch
        └──── merge sprint branch ───►  │
                                        3  deploy locally, hands-on test
                             ┌──────────┴──────────┐
                          reject                accept
                    delete verify/batch-N   ff into demo branch
                                                  │
  4  human pushes the sprint branch ◄─────────────┘
     from HERE ONLY → PR → main
```

Why it is shaped that way:

- the demo branch always has the latest code to test with, from either worktree
- pushes come from one worktree only, so there is nothing to remember
- every batch begins by proving the publishable worktree is in sync

Wire it with `project.worktree`, `queue.writeOnlyFrom` and
`git.excludeFromStacking`. And back the "never pushed" half with a `pre-push` git
hook, not a habit — `git.prePushGuard.marker` makes preflight check it is
installed. A habit is not a control.

---

## Is it working?

Signals, in rough order of how early you'll see them.

**Good:**
- The partition surprises you occasionally — it catches an entanglement you'd have
  missed. That is the union-find earning its place.
- Rejects cite specific lines and exit codes, not impressions.
- `staleEvidence` findings flow back into the map, so it improves each batch.
- Batches get wider over time as the map's file citations get better.

**Bad:**
- **Every node passes every lens, every batch.** Your verifiers are agreeable, not
  independent. Check they are genuinely fresh-context, and that the lenses ask
  different questions. Green anchors do not mean correct nodes — one batch on the
  source project went 3/3 green on every anchor and 3/3 rejected on semantics.
- **A recurring `unverified` outcome.** Something is failing to serialise. Look at
  field lengths first (scar #1).
- **The partition is one big serial node every time.** Either your map cites files
  it merely mentions (scar #10), or the work genuinely is entangled — in which
  case stop using the harness for it.
- **Nobody reads the reduce output.** The graph is theatre. Go back to one agent
  in the main loop.
