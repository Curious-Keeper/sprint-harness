# Sprint Harness Toolchain

The Sprint Harness Toolchain is the portable workflow for turning a repository's map into bounded, verified agent work. This glossary names the cross-repo concepts shared by sprint-harness, appmap-board, and the workflow skills.

## Language

**Toolchain**:
The whole portable system: map contract, harness runtime, board, workflow skills, and model/provider configuration.
_Avoid_: Appmap, harness, board as names for the whole system

**Map**:
The repo-local truth file, usually `docs/app-maps/APP_MAP.json`, that records what is true about a codebase and what work is visible.
_Avoid_: Queue, sprint state, task list

**Harness**:
The runtime that turns dispatchable map entries into isolated sprint work, verifies the results, and preserves sprint state outside the map.
_Avoid_: Board, map, skill runner

**Board**:
The human operating surface over one or more maps, including decisions owed, external state, debt, planned work, and closed work.
_Avoid_: Queue UI, sprint runner

**Workflow Skill**:
An agent workflow document that uses the map and harness contract for a specific phase, such as navigating decisions, scoping work, implementing, or multi-model review.
_Avoid_: Prompt snippet, documentation, plugin

**Consumer Project**:
Any repository that uses the toolchain by carrying a map, harness config, queue state, or workflow-specific files.
_Avoid_: Client repo, app repo, target repo

**Provider Roster**:
The configured set of model/provider choices available to workflow roles such as builder, verifier, reviewer, planner, scope reader, and summarizer.
_Avoid_: Model list, API keys, reviewers

**Role**:
A named responsibility used for model selection across the toolchain, such as builder, verifier, reviewer, planner, scope, or summarizer.
_Avoid_: Persona, agent name, model name
