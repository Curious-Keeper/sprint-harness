# Design — what generalises, and what cannot

Extracted from a working sprint harness on a Next.js + Supabase client project
that shipped nine batches through it. This document is the audit: which parts
were universal all along, which were project-specific, and where the seam is.

---

## The seam

The system separates into three layers. **The portability of the whole thing
depends on nothing leaking upward.**

```
  ┌─────────────────────────────────────────────────────────────┐
  │ LAYER 3 — THE MAP + THE CONTRACTS          100% yours       │
  │ what is true about this codebase; which invariants have      │
  │ already caused a real bug here                               │
  ├─────────────────────────────────────────────────────────────┤
  │ LAYER 2 — CONFIG                            a JSON file      │
  │ anchors, setup, lanes, paired artifacts, branch policy       │
  ├─────────────────────────────────────────────────────────────┤
  │ LAYER 1 — THE MACHINERY                    copied verbatim   │
  │ partitioner · graph · reduce · guards · gates                │
  └─────────────────────────────────────────────────────────────┘
```

Layer 1 never imports anything from layer 3. Layer 2 is the only channel between
them. That is the entire portability story.

---

## The audit

| Piece | Verdict | Notes |
|---|---|---|
| **Union-find partitioner** | **universal** | A graph problem with a correct answer. Zero domain knowledge. |
| **Wave sequencing** | **universal** | Exclusive nodes bypass the union-find, so sequencing is what makes them safe. |
| **The diamond graph** | **universal** | fan out → N lenses → plain-code reduce. |
| **Reduce + fan-in guard** | **universal** | 4 outcomes, anchor-disagreement detection, never report a partial run as complete. |
| **Bounded output schema** | **universal** | `maxLength` on every free-text field. See scar #1. |
| **`deny-push` hook** | **universal** | Only the denial *message* was project-specific → config. |
| **Scope taxonomy** | **universal** | `bounded`/`repo-wide`/`unscoped`/`needs-design`/`external`/`duplicate`/`held`. Independently re-derivable on any project. |
| **Preflight checks** | **universal shape** | The *checks* generalise; branch names, worktree names and map paths were hardcoded → config. |
| **Paired-artifact gate** | **universal shape** | Was `check-component-tests.sh` with `web/components` baked in → now rule-driven. |
| **Migration lane** | **generalised** | The *specific* lane was domain knowledge; the *concept* (a resource no merge can reconcile) is universal → `lanes[]`. |
| **Anchors** | **config** | The idea "trust exit codes, not agreement" is universal. `tsc`/`lint`/`test` are not. |
| **Two-worktree lifecycle** | **project-specific** | An unusual constraint (a demo worktree carrying code that must never reach the remote). Ships as an *optional* pattern, not a default. |
| **Map schema** | **project-specific shape, universal principles** | See below. |
| **Repo invariants** | **100% project-specific** | Marked as `{{REPO_INVARIANTS}}` in both agent templates. |
| **`extract-queue.mjs`** | **split** | Machinery → `core/lib/extract.mjs`. Map-walking (~40 lines) stays yours. |

---

## Four decisions worth keeping deliberately

### 1. Collision detection is plain code, and it is *forced* to be

Workflow scripts have no filesystem access. So the partition — and now the config
slice — must be computed in the main loop and passed through `args`.

That started as a limitation. It is the best property of the design. It means the
one decision that must be deterministic *cannot* happen inside a model, and the
human sees the partition before anything runs.

Preserved deliberately: `plan.harness` rides inside the plan JSON rather than
being read from disk by the workflow.

### 2. The map is read-only; the queue is state

Two files, two lifecycles:

- **MAP** — what is true about the code. Regenerated from the codebase. Never
  mutated by a sprint.
- **QUEUE** — status, batch, ownership, notes. The only thing a sprint writes.

They rejoin on item id. A rebuild preserves queue state and *reports* ids that
vanished from the map rather than dropping them.

Collapsing these produces a file that is simultaneously a source of truth and a
scratchpad — and a batch that closes an item mutates the evidence future batches
plan from.

### 3. Lenses are distinct questions, so one reject fails the node

Three *identical* reviewers would be a majority vote and should be treated as one.
Three *different questions* are three independent tests, and a single failure is a
real finding.

This is why `verify.lenses` is a list of names the schema enumerates, not a count.
Adding a fourth lens means writing a fourth question.

**Two of the three shipped lenses are read-only; the third is not.** `intent` and
`invariants` read a branch and judge it. `anchors` is handed a worktree to create,
a `setup` block to run, anchors to execute and a scope gate to shell out to — it
is a build-executing lens that happens to be driven by a model. The asymmetry
matters twice. It is why `anchors` is the strongest candidate in the kit for
demotion to plain code: a process can run anchors in a fresh tree and report exit
codes with no model in the loop at all. And it is why the two *judgment* lenses
are the only ones worth decorrelating — a second opinion on an exit code is the
same exit code.

**The trap in `verify.lenses`: it is the REQUIRED set, not a menu.**
`requireAllLenses` compares `verdicts.length === lenses.length`, and
`missingLenses` is computed over the same array. So putting a lens id there is a
promise that the lens will always produce a verdict, and the first time it is
missing, misconfigured or rate-limited, **every node in the wave goes
`unverified`** and the queue halts. A lens that cannot make that promise needs to
be surfaced without being counted — reported, not voting — and `reduceWave` has
no such path today.

### 4. Refusal is a first-class outcome

At every level the system prefers to refuse rather than guess:

- the extractor refuses to derive files it cannot resolve, and *reports* the
  ambiguity
- the partitioner refuses to dispatch unscoped items
- the verifier defaults to REJECT
- the reduce step refuses to call a partial run complete
- the hooks fail closed

An agentic system's failure mode is not "it stops" — it is "it proceeds
confidently on a bad assumption". Every refusal above is a place that failure was
observed.

---

## The map: what actually generalises

The extracted project's map is a 260KB JSON document. Its *shape* is
project-specific. Its **principles** are not:

1. **Evidence is a `file:line` citation, not a description.** A builder verifies
   the citation still says what it claims before changing it — and reports
   `staleEvidence` when it doesn't. That turns map rot into a tracked finding
   instead of silent drift.
2. **Closed work MOVES to a `shipped` section.** It does not sit in the queue with
   `status: done`. An item that is both queued and closed is exactly the ambiguity
   this removes.
3. **Sections split by dispatchability, not by topic.** Code debt, decisions owed
   to a human, and external state are different *lanes*, because only the first
   can be handed to a builder.
4. **The map records its own harness.** A `sprintHarness` section describing the
   shape, the lenses, and the batch history means a fresh agent can read how the
   system works from the same file it plans from.

`templates/MAP.skeleton.json` encodes exactly these four and nothing else.

---

## What was deliberately *not* generalised

**The two-worktree lifecycle.** The source project keeps a second worktree
carrying code that must never reach the remote, and merges sprint work forward
into it for hands-on verification. It is a genuinely good pattern for
"verification needs a full stack that the publishable tree cannot contain" — but
it is unusual, and baking it into `core/` would tax every project that doesn't
need it. Documented in `PORTING.md` as an optional pattern.

**Auto-batch sizing beyond `--auto N`.** Cheapest-safe-first is a fine default.
Anything smarter would be guessing at priorities that live in a human's head.

**A map generator.** Every attempt to auto-generate the map produces a file that
describes structure (which any agent can read from the code anyway) rather than
*consequences* — which columns don't exist despite older code implying they do,
which contract looks like style but is data integrity. That knowledge is written
by whoever got burned. It cannot be extracted.

---

## Known gaps

Honest list of what this kit does not yet do.

- **The verify stage is less deterministic than its reports imply.** This is now
  the big one, and it replaces the older gap — "the lenses have never been shown
  to reject" — which `core/canary.mjs` closed. Planted defects on prebuilt
  branches do get rejected, and clean controls do not: across the arms run
  2026-09-11 to 2026-09-13, detection ran 3/4 to 4/4 with 0/2 false rejects. The
  problem the rig surfaced instead is **run-to-run variance inside one model**.
  Two runs identical in every respect — same plan, same branches, same prompts,
  same model — disagreed on a real defect, and the second accepted the node. So a
  node accepted with zero rejects on a single run is weaker evidence than the
  report makes it look, and `verify.confirmAccepted` exists for exactly that,
  switched off by default because it doubles verifier spend. Two narrower gaps
  fall out of the same finding: a lens that names a defect in another lens's
  territory files it under `couldNotVerify`, which gates nothing, and detection is
  proven against one project's rig rather than in general. See SCARS.md #22.
- **The "cannot publish" guarantee is enforced by the runtime, not by the
  substrate.** Builders run in `git worktree`s, and a worktree shares
  `.git/config` with the parent — **remotes included**. So an agent sitting in one
  has the project's real `origin` in reach, and the only thing in front of it is
  the `deny-push` PreToolUse hook. That guard is real (see scar #8) but it holds
  exactly as far as the runtime it is installed in: it is a configured guarantee,
  not a structural one. `git clone --shared` with `origin` removed would put the
  guarantee in the filesystem instead — nothing to push to, because no destination
  is configured — at the cost of a clone per node rather than a worktree.
  `--shared` uses alternates, so the object database is not copied and the cost is
  small, but nothing in the kit does this today.
- **The graph is still not covered end to end.** `core/sprint-batch.mjs` needs a
  live agent runtime. The reduce inside it is now sliced out by
  `core/reduce-fixture.mjs` and mutation-tested, but the agent orchestration
  around it is only parse-checked.
- **`config.mjs` validates by hand rather than against the schema.** The JSON
  Schema is authoritative for editors; the loader re-checks the subset that would
  cause a silent weakening. `selftest.sh` now checks that every key the loader
  defaults exists in the schema and that no shipped example uses a key the schema
  forbids, which catches the drift that actually bit — but it is not full schema
  validation, and there is no ajv dependency to do it with.
- **The paired-artifact gate is bash + jq**, so it inherits bash's quoting model
  for `pairPath` templates. It handles the common cases; an exotic path with
  regex metacharacters in the *directory* portion is untested.
- **Only `git.stackBranches` encodes branch policy.** Projects with a real
  trunk-based flow will want to turn it off, and nothing else in preflight
  adapts to that.
- **Single-repo only.** No story for a batch that spans two repositories.
