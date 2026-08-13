# Prompt 02 — one audit lane

**When:** Phase 3. Run this **once per lane**, in a **separate session each**.
**Produces:** findings for one surface, in `openDebt` entry shape.
**This is the phase that took the source project two months and two rebuilds.**

## Rules for running lanes

1. **One lane per session.** Lanes must not read each other's output. Overlap
   between two lanes on one finding is *signal* — it means the defect is reachable
   from two directions.
2. **Disable persistent project memory.** The source project's "blind" audit was
   contaminated because memory loaded every session and named a finding, which
   then had to be discarded. If you cannot disable it, say so in the output — a
   lane that knows the answer is not evidence.
3. **Every part of `docs/SURFACE.md` belongs to exactly one lane.** Anything
   unassigned goes into `coverageGaps` as a deliberate choice, not a discovery
   made months later.
4. **Reconcile afterwards, by hand.** Dedupe by `file:line`; keep the
   better-evidenced write-up.

Fill in `<LANE>` and `<SCOPE>` and paste below the line.

---

Audit ONE surface of this codebase for defects, and nothing else.

**LANE: `<LANE — e.g. "data access layer">`**
**SCOPE: `<explicit paths — e.g. web/lib/**, web/app/**/actions.ts>`**

Read `~/git_projects/sprint-harness/docs/MAP_GUIDE.md` first for the entry
standard. Read `<docs/app-maps/APP_MAP.json>` for architecture and
`evolutionTraps` — but treat every claim in it as **unverified**. If the map is
wrong, that is itself a finding.

## Method

**ENUMERATE your scope explicitly before analysing any of it.** List every file in
scope and confirm the count. Do not sample. The source project's audit enumerated
only part of the migration list and silently missed the rest, and nobody noticed
until much later.

Then, for each file: read it and ask what breaks, under what input, in production.
Not "is this good style".

Look hardest for:
- **errors that are swallowed** — bare catches, ignored error returns, fallback
  defaults that mask a missing value
- **contracts that look like style but are data integrity** — a naming convention
  that something downstream actually parses
- **things that work only because of a coincidence elsewhere** — the most valuable
  class of finding, and the one only a careful read produces
- **references to things that no longer exist** (check `evolutionTraps`)
- **duplicated logic that must change in lockstep** and has no test binding it
- **anything that would produce a WRONG result rather than an error**

Do not report: style preferences, "consider extracting this", missing comments, or
anything a linter would already catch.

## Entry shape — all four fields, every time

```json
{
  "id": "<LANE-PREFIX>#1",
  "summary": "one declarative line — becomes a queue item title",
  "evidence": "path/file.ts:120-134 — what the code actually does, quoted or paraphrased tightly. MORE THAN ONE citation where the defect spans files.",
  "mechanism": "the causal chain. WHY it breaks, and what is surprising about it. If this is obvious from the summary, it is a lint rule, not a map entry.",
  "fix": "the SHAPE of the fix and the constraint it must preserve. Never the diff."
}
```

Two things about `evidence`, because they are load-bearing for machinery you
cannot see:

- The extractor **scrapes file paths out of it to build the collision graph**. An
  item with no file citation cannot be dispatched at all.
- **Name only files the fix would EDIT.** A path mentioned in passing or as a
  comparison lands in the item's file set and manufactures a false collision,
  serialising work that could have run in parallel. Describe cross-references
  without paths.

Assign `high` / `medium` / `low`. `high` means data corruption, a security
boundary, or something a user hits today.

## Calibration

Reject your own weak findings. The bar is: **could someone act on this without
asking you a follow-up question?** A finding whose evidence is "this looks
fragile" is not a finding.

Report **fewer, better** entries. Twelve real ones beat forty padded ones, because
padding trains every future agent to skim.

## Output

1. The findings as a JSON array, ready to merge into `openDebt`.
2. **`couldNotVerify`** — anything in scope you could not reach a conclusion on,
   and why. Be specific. This is not failure; an honest gap is worth more than a
   confident guess.
3. **Coverage statement** — exactly which files you enumerated and read, and which
   in scope you did *not*. This becomes `coverageGaps`.
4. Any claim in the existing map you found to be **wrong**. Those are findings
   about the map and matter more than most code findings.

If you find nothing worth reporting in some part of the scope, say that plainly.
An empty lane honestly reported is a useful result; a padded lane is worse than no
lane at all.
