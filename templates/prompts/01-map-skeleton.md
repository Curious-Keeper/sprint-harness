# Prompt 01 — map skeleton (structure + evolution traps)

**When:** Phase 2, after anchors are green and `docs/SURFACE.md` exists.
**Produces:** a valid `APP_MAP.json` with structure, counts and `evolutionTraps` —
but **no `openDebt` yet**.
**Why split:** structure is mechanical and cheap; debt needs independent blind
lanes and would be contaminated by a session that just read the whole codebase.

---

Build the first version of this project's map at `<docs/app-maps/APP_MAP.json>`.

Read first:
- `~/git_projects/sprint-harness/docs/MAP_GUIDE.md` — the writing standard
- `~/git_projects/sprint-harness/templates/MAP.skeleton.json` — the shape
- `docs/SURFACE.md` — the surface inventory from the previous session

**This pass writes structure and traps ONLY. Do not populate `openDebt`.** Debt
comes from independent blind audit lanes in the next phase, and findings from a
session that has just read everything are contaminated by exactly the assumptions
we are trying to test.

## The one rule

**Record CONSEQUENCES, not structure.** You can already read the directory
listing, the route table and the schema — so can every future agent. What none of
you can read is the trigger that turns a Save button into a raw database
exception, or the column that was dropped four months ago and still appears in
half the codebase.

Every time you are about to write "the X table has 14 columns", stop and write
what will bite instead.

## Task 1 — meta and counts

Stamp `meta` with today's date, the current HEAD sha, the branch, and whether the
working tree was clean. Then real counts for each surface — migrations, routes,
components, modules, handlers, tables, whatever applies.

These get spot-checked, so derive them with commands rather than estimating, and
tell me the command you used.

## Task 2 — architecture

Walk each surface in `docs/SURFACE.md`. For each element, one line that says what
it is **for** and anything non-obvious about it. Prefer the sentence that would
stop someone making a mistake over the sentence that describes the shape.

Where two things look interchangeable but are not, say so explicitly. Where a
name is misleading, say so.

## Task 3 — evolutionTraps (the highest-value section)

Facts that **used to be true**. Older code, comments and docs still imply they
exist, so an agent pattern-matching on them writes code that references nothing.

Mine these mechanically rather than by reading:

```bash
git log -p --diff-filter=M -- <migrations dir> | grep -iE '^\+.*(DROP|RENAME)'
git log --diff-filter=D --name-only --format='%h %ad %s' --date=short
git log --diff-filter=R --name-status --format='%h %ad %s' --date=short
```

Every dropped column, renamed table, deleted module and renamed export is a trap
the moment anything still references it. **Then grep for each one** — a trap that
nothing references any more is just history; a trap something still references is
a live finding and belongs in the next phase's input.

Format, with the negation in ALL-CAPS because the reader currently believes the
opposite:

```
"orders.freight_charge DOES NOT EXIST — dropped in 0074. Buyer-billed freight is
 an FC LINE ITEM. Any code or doc referencing the column is pre-0074."
```

## Task 4 — generated files and their generators

Any file that must never be hand-edited, and the exact command that produces it.
An agent that hand-edits a generated file produces a diff that vanishes on the
next build, and nothing catches it.

## Task 5 — the empty scaffolding

Create `openDebt` (empty, with its `$comment`), `plannedWork`, `decisionsOwed`,
`externalState`, `shipped` and `sprintHarness` per the skeleton. Sections split by
**dispatchability, not topic** — `decisionsOwed` and `externalState` must never
reach a builder, because an agent asked to check a DNS record or a SaaS console
will report on what it can see locally and present that as the answer.

## Output

- `<docs/app-maps/APP_MAP.json>`, valid JSON, `node -e 'require("./<path>")'` clean
- A list of everything you found that **smells like debt** — do not write it into
  `openDebt`, just hand me the list. It becomes seed input for the audit lanes.
- Anything you could not determine from the repo, as a question.

Do not pad. An entry that merely restates a filename is noise, and noise here
trains every future agent to skim the sections that matter.
