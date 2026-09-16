# Toolchain contract

This document explains how `sprint-harness`, `../appmap-board`, and `../skills` share one toolchain without merging into one repository.

## What each repository owns

`sprint-harness` owns the portable runtime and the contracts that other projects read.

- `templates/MAP.skeleton.json` defines the canonical map shape.
- `docs/MAP_GUIDE.md` defines the writing standard and the lane split.
- `harness.config.schema.json` defines project configuration.
- `core/lib/extract.mjs` defines file citation scraping and queue state rules.
- `CONTEXT.md` defines shared vocabulary.

`appmap-board` owns the human operating surface over maps.

- It reads `templates/MAP.skeleton.json` and `docs/MAP_GUIDE.md` as external contracts.
- It tolerates drift so existing maps remain visible.
- It writes only guarded transitions back to maps: answer a decision, resolve external state, or promote intake into an allowed human-owned section.

`skills` owns agent workflows.

- `manifest.json` is the reviewable index of each skill's coupling to the toolchain.
- Harness-coupled skills must declare each config key that they read.
- Harness-coupled skills must declare each map section that they read or write.

## Change rules

When you change the map shape, update these files in the same branch or in linked branches:

1. `templates/MAP.skeleton.json`
2. `docs/MAP_GUIDE.md`
3. `../appmap-board/appmap/normalize.py`
4. `../appmap-board/appmap/codemod.py`, if a safe mechanical migration exists
5. `../appmap-board/appmap/writeback.py`, if the board writes the section
6. `../skills/manifest.json`, if any skill reads or writes the section
7. The affected skill files in `../skills/*/SKILL.md`

When you change a harness config key, update these files:

1. `harness.config.schema.json`
2. `core/lib/config.mjs`
3. `docs/MODELS.md` or the relevant harness documentation
4. `../skills/manifest.json`, if any skill reads the key
5. `../appmap-board` code, if the board reads the key

When you change shared vocabulary, update `CONTEXT.md` first. Then update prose in the other two repositories to use the same term.

## Vocabulary

`CONTEXT.md` is the shared glossary. Use these names consistently across all
three repositories:

- Toolchain: the full portable system.
- Map: the repo-local truth file, usually `docs/app-maps/APP_MAP.json`.
- Harness: the runtime that dispatches and verifies sprint work.
- Board: the human operating surface over maps.
- Workflow Skill: an agent workflow document.
- Consumer Project: a repository that carries toolchain files.
- Provider Roster: the configured set of model/provider choices.
- Role: a named model-selection responsibility.

Do not use one component name for the whole system. For example, do not call the
whole Toolchain "the harness" or "the board".

## Verification

Run the local check for each repository that the change touches.

```bash
# sprint-harness
./selftest.sh
./check-vocabulary.py

# appmap-board
cd ../appmap-board
python3 -m unittest discover -s tests -t .
python3 tests/mutations.py

# skills
cd ../skills
python3 -m json.tool manifest.json >/dev/null
python3 -m json.tool manifest.schema.json >/dev/null
python3 check_manifest.py
```

For a map shape change, also run the board against a fixture registry before using the real registry.

```bash
cd ../appmap-board
APPMAP_CONFIG=/tmp/fixture-projects.json bin/appmap drift
APPMAP_CONFIG=/tmp/fixture-projects.json bin/appmap normalize
```

## Boundary rules

The map records truth about a codebase. It is not sprint state, a call-notes inbox, or a generated board model.

`QUEUE.json` records sprint state. The extractor can rebuild it from the map while preserving status.

`INTAKE.md` records claims that have not read the repo. A claim can become `plannedWork.backlog`, `plannedWork.decisionsOwed`, or `externalState.open`. It cannot become `openDebt` until a session reads the repo and adds file-line evidence.

A board write must not make a sprint start by side effect. Work reaches a sprint only through the next extraction step.

A skill that starts reading a map section or config key must update `../skills/manifest.json` in the same change.
