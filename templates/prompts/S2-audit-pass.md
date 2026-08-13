# Prompt S2 — audit pass (small project)

**Adapts:** full-runbook prompt 02, for a codebase with 1–3 surfaces.
**When:** Sessions B and C. **Run twice, in two separate sessions.**
**Produces:** findings in `openDebt` entry shape, one pass each.

## How to split the two passes

**If the project has 2–3 surfaces:** split by surface. Pass 1 gets one, pass 2
gets the rest. Every part of the inventory belongs to exactly one pass.

**If the project has 1 surface:** split by **question**, over the same code:

- **Pass 1 — correctness:** what produces a *wrong result* rather than an error?
- **Pass 2 — integrity:** what swallows errors, what breaks under concurrent or
  partial writes, what works only because of a coincidence elsewhere?

Different questions over the same code are still independent evidence. Identical
questions over the same code are one opinion run twice, and buy nothing.

## Non-negotiable

1. **Separate sessions.** The two passes must not read each other's output.
   Overlap on a finding is *signal* — it means the defect is reachable from two
   directions.
2. **Project memory OFF.** The source project's "blind" audit was invalidated
   because persistent memory loaded every session and named a finding, which then
   had to be discarded. If you cannot disable it, say so in the output.
3. **This is the step people cut on a small project. Do not cut it.** The passes
   are not about coverage here — one careful read can enumerate a small codebase.
   They are about **independence**. A single session that writes the map and then
   audits it confirms the assumptions it just absorbed. That is a builder grading
   its own work, one layer earlier.

Fill in `<PASS>` and `<SCOPE>` and paste below the line.

---

Audit this codebase for defects along ONE axis, and nothing else.

**PASS: `<PASS — a surface, or "correctness" / "integrity">`**
**SCOPE: `<explicit paths, or "all of src/ through the correctness question">`**

Read `~/git_projects/sprint-harness/docs/MAP_GUIDE.md` first for the entry
standard. Read `<docs/app-maps/APP_MAP.json>` for architecture and
`evolutionTraps` — but treat every claim in it as **unverified**. If the map is
wrong, that is itself a finding, and a valuable one.

## Method

**ENUMERATE your scope explicitly before analysing any of it.** List every file in
scope and confirm the count. Do not sample — the codebase is small enough to read
completely, so read it completely. The source project's audit enumerated only part
of the migration list and silently missed the rest.

Then for each file: what breaks, under what input, in production? Not "is this
good style".

Look hardest for:
- **errors that are swallowed** — bare catches, ignored error returns, fallback
  defaults that mask a missing value
- **contracts that look like style but are data integrity** — a naming convention
  something downstream actually parses
- **things that work only because of a coincidence elsewhere** — the most valuable
  class, and the one only a careful read produces
- **references to things that no longer exist** (check `evolutionTraps`)
- **duplicated logic that must change in lockstep**, with no test binding it
- **anything that produces a WRONG result rather than an error**

Do not report style preferences, "consider extracting this", missing comments, or
anything a linter already catches.

## Entry shape — all four fields, every time

```json
{
  "id": "<PREFIX>#1",
  "summary": "one declarative line — becomes a queue item title",
  "evidence": "path/file.ts:120-134 — what the code actually does, tightly quoted. MORE THAN ONE citation where the defect spans files.",
  "mechanism": "the causal chain. WHY it breaks, and what is surprising about it. If this is obvious from the summary, it is a lint rule, not a map entry.",
  "fix": "the SHAPE of the fix and the constraint it must preserve. Never the diff."
}
```

Two things about `evidence`, load-bearing for machinery you cannot see:

- The extractor **scrapes file paths out of it to build the collision graph**. An
  item with no file citation cannot be dispatched at all.
- **Name only files the fix would EDIT.** A path mentioned in passing or as a
  comparison lands in the item's file set and manufactures a false collision. On a
  small codebase the collision graph is already dense — a spurious edge here
  serialises work that could have run in parallel. Describe cross-references
  without paths.

Assign `high` / `medium` / `low`. `high` means data corruption, a security
boundary, or something a user hits today.

## Calibration

Reject your own weak findings. The bar: **could someone act on this without asking
you a follow-up question?** "This looks fragile" is not a finding.

**Fewer, better.** On a small codebase the temptation is to pad to feel thorough.
Six real findings beat twenty padded ones, because padding trains every future
agent to skim.

If a whole area is genuinely clean, say so plainly. An honest empty result is a
useful result.

## Output

1. Findings as a JSON array, ready to merge into `openDebt`.
2. **`couldNotVerify`** — anything in scope you could not conclude on, and why.
   An honest gap is worth more than a confident guess.
3. **Coverage statement** — exactly which files you enumerated and read, and which
   in scope you did not. This becomes `coverageGaps`.
4. Any claim in the existing map you found to be **wrong**. Those matter more than
   most code findings.
