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

- **`selftest.sh` covers everything except the graph itself.** 50 assertions over
  config refusals, the partitioner (collisions, ref edges, lanes, exclusive
  waves, refusals), the push guard, and the paired-artifact gate including the
  waiver path that SIGPIPE once broke. What it does **not** cover is
  `core/sprint-batch.mjs` end to end — that needs a live agent runtime, so it is
  only parse-checked. The reduce logic in particular (outcome classification,
  anchor disagreement) is pure and should be extracted and tested directly.
- **`config.mjs` validates by hand rather than against the schema.** The JSON
  Schema is authoritative for editors; the loader re-checks the subset that would
  cause a silent weakening. They can drift.
- **The paired-artifact gate is bash + jq**, so it inherits bash's quoting model
  for `pairPath` templates. It handles the common cases; an exotic path with
  regex metacharacters in the *directory* portion is untested.
- **Only `git.stackBranches` encodes branch policy.** Projects with a real
  trunk-based flow will want to turn it off, and nothing else in preflight
  adapts to that.
- **Single-repo only.** No story for a batch that spans two repositories.
