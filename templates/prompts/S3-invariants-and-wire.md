# Prompt S3 — reconcile, invariants, wire (small project)

**Collapses:** full-runbook prompts 03 + 04, plus lane reconciliation.
**When:** Session D, after both audit passes.
**Produces:** a complete map, both agent contracts, a working extractor, a
`QUEUE.json` with zero unresolved citations, and a green pre-flight.

This is the session where the map stops being a document and becomes machinery.

---

Reconcile the two audit passes into the map, write the invariants, and wire the
extractor.

Read:
- `~/git_projects/sprint-harness/docs/MAP_GUIDE.md` — the entry standard
- both audit passes' output, including their coverage statements
- `.claude/work/extract-queue.mjs` — the template, with `{{EXTRACTION}}` and
  `{{ALIASES}}` to fill
- `.claude/harness-core/lib/extract.mjs` — the machinery it imports. **Do not
  modify this file**; it is shared with every other project.

## Task 1 — reconcile the passes into `openDebt`

Merge both passes. Dedupe by `file:line`, keeping the better-evidenced write-up.

**Where both passes found the same defect, say so explicitly in the entry.** That
is not redundancy — it means the problem is reachable from two directions, which
usually raises its severity.

Where they **disagree** about the same code, do not silently pick one. Re-read the
code yourself and record which was right; a pass that was wrong is a signal about
how much to trust the rest of its output.

Assign stable ids by source and **never renumber them** — the partitioner treats
an exact id match in an item's `mapRef` as a collision edge, so stable ids are
what stop two agents doing one job described twice.

## Task 2 — invariants

**THE BAR: it has already caused a real bug in this repo.** Not "this would be bad
if violated" — "this WAS bad, and here is the evidence".

The bar does **not** relax because the project is small. Three real invariants are
a good map; eight aspirational ones are a worse map than three, because padding
teaches every agent to skim the section. **If this project has zero qualifying
invariants, write zero and say so** — the section fills in as things break.

Find them from evidence, not intuition:

```bash
git log --format='%h %ad %s%n%b' --date=short | grep -iB2 -A6 -E 'fix|revert|hotfix|regress|broke'
```

Also mine: the `mechanism` fields you just reconciled, database triggers and
constraints, any test whose name describes a *rule* rather than a feature, and
code comments that read like warnings.

Write each as **rule → concrete failure mode**:

> ❌ "Preserve the hidden-input contract."
>
> ✅ "Pickers carry the ID in a hidden `<input name=…>` while the visible control
> is name-less. A control whose visible input carries the name submits the display
> LABEL instead of the id — silent data corruption on contact creation."

An agent can rationalise past the first. It cannot past the second.

For each, also record **the enforcing mechanism** (a trigger name, a test file, a
CI check) so a verifier can grep for it — or `"enforcedBy": "nothing — prose
only"`, which is itself a finding. And record anything **deliberately excluded**
and why, or the next agent helpfully "fixes" the omission.

## Task 3 — coverageGaps

With only two passes there is more uncovered surface by definition. Name it
explicitly, so a future audit cannot mistake "we ran two passes" for "we looked at
everything".

Record: surfaces no pass covered (named, not "some of the UI"); any methodology
defect (was a pass contaminated by memory? did one sample rather than enumerate?);
and what the test suite does **not** cover, as a proportion. "There is no test
suite" and "the suite is three days old and three files wide" are very different
facts, and the second is the one that misleads.

## Task 4 — the agent contracts

Fill `{{REPO_INVARIANTS}}` in `.claude/agents/sprint-builder.md` and
`{{REPO_INVARIANTS_CHECKLIST}}` in `.claude/agents/sprint-verifier.md`.

Stated **twice on purpose** — the verifier must be able to check an invariant
without having read the builder's contract. Phrase them differently: the builder
gets rules an author follows; the verifier gets questions a skeptic asks *of a
diff* ("if any picker changed, does the ID still travel in a hidden input?").

Keep the universal entries already in the templates.

## Task 5 — the extractor, and prove the collision graph

Adapt `{{EXTRACTION}}` to walk this map's sections and call `push()` per item —
roughly 40 lines, the only project-specific code here. Only walk dispatchable
sections; `decisionsOwed` and `externalState` must not produce dispatchable items.

Then run it **dry**:

```bash
node .claude/work/extract-queue.mjs        # no --write
```

Read three outputs, in order:

**UNRESOLVED / AMBIGUOUS citations.** Every one is a hole in the collision graph,
exactly where nobody can see it. **Do not proceed while any remain.** Fix with an
entry in `{{ALIASES}}` (only where the map uses that shorthand *consistently* — a
wrong alias silently hides a collision), a `dirHint`, or an `OVERRIDES` `files`
entry.

**collisions.** Files claimed by more than one open item. On a small codebase
expect this list to be **long** — fewer files means more sharing. That is the
system working, not a defect. If something looks wrong, the fix belongs in the
extractor or the map, **never in a prompt**.

**scopes.** A high `unscoped` count means the map describes work without citing
files. That is an audit-pass problem, not an extractor one — tell me rather than
papering over it with overrides.

The rule for what earns an `OVERRIDES` `files` entry:

> A human can name the exact files it will touch **today**, without designing
> anything first.

Everything that cannot answer that gets a `scope` keeping it out of a fan-out:
`repo-wide`, `needs-design`, `external`, `held` (which **requires** a note naming
who held it and what releases it).

## Task 6 — partition, then try to break it

```bash
node .claude/work/extract-queue.mjs --write
node .claude/harness-core/plan-batch.mjs --auto 6
```

Tell me in your own words: which items merged into one serial node and whether
that grouping is *real*; which were refused and what each needs to become
dispatchable.

Then deliberately try to break it: **pick two items you KNOW touch the same file
and confirm they land in one node.** If they do not, the collision graph has a
hole and we stop here.

## Task 7 — finish and go green

Fill `{{HUMAN GATE}}` in `.claude/skills/sprint/SKILL.md` with this project's
real verification path. Integration needs nothing filled in — `core/integrate.sh`
reads the anchors from `harness.config.json`. If this project has generated files,
add them to `regenerate` now: no node's file list can name a generated file.

```bash
.claude/harness-core/preflight.sh
```

Fix what it reports until green. **Commit the map and the queue** — builder
worktrees materialize only tracked files, so an uncommitted map means every
builder plans from the previous commit's evidence while you read the new one.

## Output

- complete map: `openDebt`, `invariants`, `coverageGaps`
- both agent contracts filled in
- working extractor, `QUEUE.json`, **zero** unresolved citations
- green `preflight.sh`
- your read of the partition, including anything that surprised you
- **a list of invariants you considered and REJECTED** for not meeting the bar,
  with reasons. If that list is empty, you did not apply the bar.
- a proposed first batch of **2–3 genuinely independent bounded items**, with your
  reasoning for why they cannot collide
