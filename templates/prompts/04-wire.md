# Prompt 04 — wire the extractor, prove the collision graph

**When:** Phase 5, after the map has real `openDebt` and `invariants`.
**Produces:** a working `extract-queue.mjs`, a `QUEUE.json` with zero unresolved
citations, and a green pre-flight.

This is the phase where the map stops being a document and becomes machinery.

---

Wire this project's queue extractor and prove the collision graph is sound.

Read:
- `.claude/work/extract-queue.mjs` — the template, with `{{EXTRACTION}}` and
  `{{ALIASES}}` to fill
- `.claude/harness-core/lib/extract.mjs` — the machinery it imports; **do not
  modify this file**, it is shared with every other project
- `~/git_projects/sprint-harness/docs/RUNBOOK.md` Phase 5

## Task 1 — the extraction block

Adapt `{{EXTRACTION}}` to walk this map's sections and call `push()` per item.
That is roughly 40 lines and it is the only project-specific code here.

Id conventions: tag by source and **never renumber**. `S#n` schema review, `L#n`
audit lane, `§x.y` a document section, `pw:n` planned work. The partitioner treats
an exact id match in an item's `mapRef` as a collision edge, so stable ids are what
stop two agents doing one job described twice.

Only walk dispatchable sections. `decisionsOwed` and `externalState` must not
produce dispatchable items — an agent pointed at one produces confident fiction.

## Task 2 — run it DRY and fix the holes

```bash
node .claude/work/extract-queue.mjs        # no --write
```

Read three outputs, in this order:

**UNRESOLVED / AMBIGUOUS citations.** Every one is a hole in the collision graph,
exactly where nobody can see it. An ambiguous bare basename matching three files
means the partitioner cannot guarantee two agents will not collide. Fix each with:

- an entry in `{{ALIASES}}` — only where the map uses that shorthand
  **consistently**; a wrong alias silently hides a collision
- a `dirHint` — for basenames that repeat once per module (`index.ts`, `main.go`)
- an `OVERRIDES` `files` entry — when the prose describes a target without a path

**Do not proceed while any citation is unresolved.**

**collisions.** Files claimed by more than one open item. Read this list — it is
the map telling you which work is genuinely entangled. If something looks wrong,
the fix belongs in the extractor or the map, **never in a prompt**.

**scopes.** A high `unscoped` count means the map describes work without citing
files. That is a Phase 3 problem, not an extractor problem — go back rather than
papering over it with overrides.

## Task 3 — the OVERRIDES discipline

The rule for what earns an `OVERRIDES` `files` entry:

> A human can name the exact files it will touch **today**, without designing
> anything first.

That is the only question. Not "is this important", not "do we understand it" —
"can the partitioner guarantee no two agents collide". Everything that cannot
answer it gets a `scope` that keeps it out of a fan-out:

| scope | means |
|---|---|
| `bounded` | files known — dispatchable |
| `repo-wide` | real but unbounded; runs alone in its own wave |
| `unscoped` | the extractor could not derive files → pin them |
| `needs-design` | **nobody** can scope it yet. Scoping IS the work. |
| `external` | truth lives outside the repo |
| `held` | buildable, but a human said not yet — **requires a note** naming who held it and what releases it |

`unscoped` vs `needs-design` is a real distinction and the fix differs: one is a
missing override, the other is a missing decision.

## Task 4 — verify the partition by hand

```bash
node .claude/work/extract-queue.mjs --write
node .claude/harness-core/plan-batch.mjs --auto 8
```

Read the partition and tell me, in your own words:

- which items merged into one serial node, and whether that grouping is *real*
- which were refused, and what each would need to become dispatchable
- whether anything in wave 0 looks like it could collide despite the partitioner

Then deliberately try to break it: pick two items you *know* touch the same file
and confirm they land in one node. If they do not, the collision graph has a hole
and we stop here.

## Task 5 — finish the skill and go green

Fill `{{HUMAN GATE}}` in `.claude/skills/sprint/SKILL.md` with this project's real
verification path. Integration itself needs nothing filled in — `core/integrate.sh`
reads the anchors from `harness.config.json`. If this project has generated files
(an OpenAPI schema, generated clients, a bundled index), add them to `regenerate`
now: no node's file list can name a generated file, so nothing else rebuilds it.

Then:

```bash
.claude/harness-core/preflight.sh
```

Fix what it reports until it is green. **Commit the map and the queue** — builder
worktrees materialize only tracked files, so an uncommitted map means every
builder plans from the previous commit's evidence while you read the new one, and
an evidence path that is gitignored is a file no builder can open.

## Output

- working extractor, `QUEUE.json` written, **zero** unresolved citations
- green `preflight.sh`
- your read of the partition, including anything that surprised you
- a proposed first batch of **2–3 genuinely independent bounded items**, with your
  reasoning for why they cannot collide
