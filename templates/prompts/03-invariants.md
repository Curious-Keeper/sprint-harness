# Prompt 03 — invariants and honest coverage

**When:** Phase 4, after the audit lanes have been reconciled into `openDebt`.
**Produces:** the `invariants` and `coverageGaps` sections — and directly, the
`{{REPO_INVARIANTS}}` blocks in both agent contracts.

Short phase, disproportionate value. These are the two sections that make the
verifier's `invariants` lens able to reject anything at all.

---

Write the `invariants` and `coverageGaps` sections of
`<docs/app-maps/APP_MAP.json>`.

Read `~/git_projects/sprint-harness/docs/MAP_GUIDE.md` for the standard, plus the
reconciled `openDebt` and every audit lane's coverage statement.

## Task 1 — invariants

**THE BAR FOR AN ENTRY: it has already caused a real bug in this repo.** Not
"this would be bad if violated" — "this WAS bad, and here is the evidence".

This bar is the whole point. A list padded with plausible-sounding rules trains
every agent to skim the entire section, which costs you the entries that matter.
Ten real ones beat forty aspirational ones.

Find them from evidence, not from intuition:

```bash
git log --format='%h %ad %s%n%b' --date=short | grep -iB2 -A6 -E 'fix|revert|hotfix|regress|broke'
```

Also mine: existing `openDebt` mechanisms, database triggers and constraints, any
test whose name describes a *rule* rather than a feature, and code comments that
sound like a warning.

Write each as **rule → concrete failure mode**:

> ❌ "Preserve the hidden-input contract."
>
> ✅ "Pickers carry the ID in a hidden `<input name=…>` while the visible control
> is name-less. A control whose visible input carries the name submits the display
> LABEL instead of the id — silent data corruption on contact creation."

An agent can rationalise past the first. It cannot past the second.

For each, also record:

- **the enforcing mechanism** if one exists — a trigger name, a test file, a CI
  check — so a verifier can grep for it. If nothing enforces it, say
  `"enforcedBy": "nothing — prose only"`. That is itself a finding.
- **anything DELIBERATELY excluded, and why.** This is the one most often missed.
  If a lock covers nine fields and deliberately excludes five, say which and say
  why, or the next agent helpfully "fixes" the omission and breaks whatever the
  exclusion was protecting.
- **a maintenance rule** where one applies: what a *future* change must do to keep
  the invariant true.

## Task 2 — coverageGaps

Write down what nobody looked at. This feels like admitting failure; it is the
section that stops a future audit from concluding "clean" about a surface it never
opened.

From the lanes' coverage statements, record:

- surfaces from `docs/SURFACE.md` that **no lane covered**, named explicitly — not
  "some components", but the list
- **methodology defects**: was any lane contaminated by memory or prior context?
  Did any sample rather than enumerate? These are worth more than most code
  findings, because they tell you which conclusions to distrust.
- what the test suite does **not** cover, stated as a proportion. "There is no
  test suite" and "the suite is three days old and three components wide" are very
  different facts, and the second is the one that misleads.

## Task 3 — the agent contracts

Fill `{{REPO_INVARIANTS}}` in `.claude/agents/sprint-builder.md` and
`{{REPO_INVARIANTS_CHECKLIST}}` in `.claude/agents/sprint-verifier.md` from Task 1.

They are stated **twice on purpose** — the verifier must be able to check an
invariant without having read the builder's contract. Phrase them differently:

- **builder** — rules an author follows, with the failure mode
- **verifier** — questions a skeptic asks *of a diff*: "if any picker changed, does
  the ID still travel in a hidden input?"

Keep the universal entries already in the templates (never delete a test to make a
build pass, never touch secret files, never hand-edit generated files).

## Output

- the two map sections
- both agent contracts filled in
- **a list of invariants you considered and REJECTED for not meeting the bar**,
  with the reason

That last item is the one I will read most carefully. If the rejected list is
empty, you did not apply the bar.
