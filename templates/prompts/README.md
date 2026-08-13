# Prompts

Copy-paste session prompts for adopting the harness in a new project. Run them in
order; each assumes the previous one's checkpoint passed. The full sequence with
checkpoints is [`docs/RUNBOOK.md`](../../docs/RUNBOOK.md).

| # | Prompt | Phase | Session produces |
|---|---|---|---|
| 00 | [orientation](00-orientation.md) | 0–1 | `harness.config.json`, verified anchors, `docs/SURFACE.md` |
| 01 | [map skeleton](01-map-skeleton.md) | 2 | `APP_MAP.json` — structure + `evolutionTraps`, **no debt yet** |
| 02 | [audit lane](02-audit-lane.md) | 3 | one surface's findings. **Run once per lane, separate sessions** |
| 03 | [invariants](03-invariants.md) | 4 | `invariants`, `coverageGaps`, both agent contracts |
| 04 | [wire](04-wire.md) | 5 | working extractor, `QUEUE.json`, green pre-flight |
| 05 | [first batch](05-first-batch.md) | 6 | a merged batch, and a list of harness defects |

## Three things that are easy to get wrong

**Do not merge 01 and 02.** The skeleton session reads the whole codebase, which
contaminates it as an auditor — its findings will confirm the assumptions it just
absorbed rather than test them. Structure first, debt in fresh sessions.

**Run each audit lane in its own session, with project memory off.** The source
project's "blind" audit was invalidated because persistent memory loaded every
session and named a finding. Lanes that read each other's output stop being
independent evidence and become one opinion with extra steps.

**Every surface belongs to exactly one lane.** Anything unassigned is a surface
nobody ever audits. The source project's first audit ran five lanes and none
touched the UI component tree; fifty-one components went unexamined and the gap
surfaced months later. Assign from `docs/SURFACE.md`, and write the leftovers into
`coverageGaps` as a deliberate choice.

## Adapting them

The prompts assume the harness is installed at `.claude/harness-core/` and this
kit is at `~/git_projects/sprint-harness`. Adjust paths if not.

They are deliberately blunt about what *not* to do, because every prohibition in
them is a failure that already happened once. Before you soften one, check whether
[`docs/SCARS.md`](../../docs/SCARS.md) explains why it is there.
