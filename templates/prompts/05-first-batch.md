# Prompt 05 — the first batch

**When:** Phase 6, on a green pre-flight with a committed map.
**Produces:** a merged, verified batch — and, more importantly, a list of harness
defects.

**The first batch tests the harness, not the backlog.** Pick 2–3 items you would
be happy to throw away.

---

Run the first sprint batch on this project.

Read `.claude/skills/sprint/SKILL.md` and follow it. Invoke the `/sprint` skill if
it is registered.

## Before dispatch — sharpen the items

Spend real effort here. From the source project's own notes after nine batches:

> *"Every batch that struggled today struggled on scope, not on skill."*

Its cleanest first-time pass was an item that had been **re-scoped three times** as
wrong assumptions were peeled off it. By dispatch it carried the real constraint,
the real hazard, and an explicit do-not-touch.

For each item, before it goes out, confirm:

- the `file:line` evidence **still says what it claims** — check it now, because a
  builder that finds stale evidence will guess
- the file set is what the fix actually needs — no more, no less
- any hazard is stated explicitly, including what **not** to touch
- there is no hidden decision inside it. If the item contains a choice a human
  should make, make it now or pull the item.

Tell me which items you re-scoped and why.

## Dispatch

```bash
.claude/harness-core/preflight.sh
node .claude/harness-core/plan-batch.mjs <ids...> --json > /tmp/plan.json
```

Then the workflow with `batchName`, `wave: 0`, and a `baseBranch` that is **NOT**
the main branch — anchors often only exist on the sprint base, and a builder
branching from main is judged by a weaker set of checks than the batch is held to.

Two known transit failures: `args` may arrive as a JSON string rather than an
object (the script parses either), and smart quotes or raw `<`/`>` inside evidence
strings have failed a launch before any agent ran.

## Read the output for the HARNESS, not the code

In this order:

1. **`dispatched` vs `returned`** — did every node come back? A missing node did
   not fail, it *vanished*, and the batch is not complete.
2. **Missing lenses** — did every lens return for every node? A missing verdict is
   usually a serialisation failure, and a lost `pass` reads downstream as
   **UNVERIFIED**, which is not the same outcome as rejected and must never be
   reported as one.
3. **ANCHOR DISAGREEMENT** — builder claimed one exit code, verifier observed
   another. There is no benign explanation: either a builder reported a green it
   did not see, or one of the two ran against a tree that is not the commit. This
   is the single most valuable line the system produces.
4. **`staleEvidence`** — map citations that no longer matched. Feed every one back
   into the map. That loop is what makes the map improve under use.
5. **`rejects`** — read the evidence, not the verdict. A single reject fails a
   node because the lenses ask *different questions*; it is a finding, not an
   outvoted opinion.

## Integrate

Merge accepted branches in wave order, then **re-run the anchors on the merged
tree**. Per-node green does not imply merged green.

Then stop. **Do not push.** Hand me the branch and the summary; I verify against
the running app and push. A green anchor set is not evidence a change is right.

## Output

1. The reduce summary — accepted / rejected / unverified / not-built.
2. **A list of harness defects found.** Expect several; that is what this batch is
   for. Anything wrong in `core/` goes back to `~/git_projects/sprint-harness`,
   not patched in place here — otherwise we fork the machinery on batch one.
3. `staleEvidence` items, as proposed map edits.
4. Your honest read: did the verification actually verify anything, or did three
   lenses pass everything without looking? If every node passed every lens on a
   first batch, be suspicious and say so.
