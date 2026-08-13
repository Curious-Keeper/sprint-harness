# Runbook — harness to a new project

The source project reached this state over ~2 months of organic evolution. Almost
none of that time was the harness; it was **learning what the map had to contain**
and rebuilding it twice. This runbook is that path, directed, with the dead ends
removed.

**Budget: 4–6 working sessions to a first green batch.** Most of it is the map.

```
  PHASE 0  decide + install                        30 min, human
  PHASE 1  anchors                                 1–2 h    ← before the map
  PHASE 2  map skeleton: structure + traps         1 session
  PHASE 3  audit lanes → openDebt                  1 session, parallel  ← the compression
  PHASE 4  invariants + coverage honesty           half session
  PHASE 5  wire extractor + contracts              1 session
  PHASE 6  a deliberately small first batch        1 session
```

Each phase has a **checkpoint**. Do not carry a failed checkpoint forward — every
one of them exists because carrying it forward on the source project cost a day.

Copy-paste prompts live in [`templates/prompts/`](../templates/prompts/). The
map-writing standard is [MAP_GUIDE.md](MAP_GUIDE.md).

---

## Phase 0 — decide, then install

**Is this project a candidate?** Three questions; if any is *no*, stop and use a
single agent in the main loop.

1. **≥8 queued items with no edges between most of them?** Five things that all
   touch one module is not a graph.
2. **Can a command tell you the code is broken?** Without anchors, "verify"
   degrades to models agreeing with each other — the exact failure this prevents.
3. **Will a human actually read the reduce output?** The system converts one gate
   per item into one gate per batch. It does not remove the gate.

```bash
~/git_projects/sprint-harness/install.sh /path/to/project --stack node-web
cd /path/to/project && git checkout -b chore/sprint-harness
```

Then, by hand, decide two things and write them down:

- **Where does verification actually happen?** A staging URL, a local docker
  stack, `npm run dev`. This becomes the human gate. If the answer is "we read the
  diff", the harness will not help you — green anchors do not mean correct nodes.
- **Who pushes, and when?** If the answer is "the agent", turn off
  `git.denyPush`. If it is a human, leave it on and mean it.

> **Checkpoint 0:** installed, on a branch, and you can name the verification
> surface out loud.

---

## Phase 1 — anchors, before anything else

**Do this before the map.** Anchors are testable in an hour and the map is worth
nothing without them. The reverse order is how you spend three days writing a
beautiful document that verifies nothing.

Fill `anchors` in `.claude/harness.config.json` and run each by hand.

**The question that catches the most bugs:** *what does a tree containing only
tracked files lack?* Actually do this — do not reason about it:

```bash
git clone . /tmp/probe && cd /tmp/probe && <your anchor commands>
```

Whatever fails is your `setup` array. Node → `npm ci`. Python → `uv sync`. Go and
Rust → usually nothing, the caches are per-machine.

Write the `why` on every setup entry, and make it say what **breaks** if an agent
improvises a shortcut. This is not decoration: on the source project the verifier
contract offered "if a fresh install is too slow, verify in place" and **every
single agent took it**, running anchors against dependency sets that did not
belong to the commit. See [SCARS.md](SCARS.md) #3.

**Make sure each anchor can fail.** `gofmt -l .` prints offending files and exits
0 — as an anchor it is decorative. Wrap it: `test -z "$(gofmt -l .)"`.

> **Checkpoint 1:** every anchor runs green on a fresh clone, and you have watched
> at least one go red on purpose.

---

## Phase 2 — the map skeleton

Prompt: [`templates/prompts/01-map-skeleton.md`](../templates/prompts/01-map-skeleton.md)

This phase produces the cheap, mechanical half: counts, routes, tables, modules,
and — the high-value part — `evolutionTraps`.

**`evolutionTraps` are largely derivable, and this is the single biggest
shortcut in this runbook.** They are the "X does not exist any more" facts that
older code and older docs still imply. On the source project they accumulated by
being burned. In a new project you can *mine them from history in one pass*:

```bash
git log -p --diff-filter=M -- migrations/ | grep -iE '^\+.*(DROP|RENAME)'
git log --diff-filter=D --name-only --format='%h %ad %s' --date=short
```

Every dropped column, renamed table, and deleted module is a trap the moment
anything still references it. They read like:

> `orders.freight_charge` **DOES NOT EXIST** — dropped in 0074. Buyer-billed
> freight is an FC line item. Any code or doc referencing the column is pre-0074.

> **Checkpoint 2:** the map validates as JSON, the counts match reality
> (spot-check three), and `evolutionTraps` has at least one entry that would have
> misled you.

---

## Phase 3 — audit lanes (the compression)

Prompt: [`templates/prompts/02-audit-lane.md`](../templates/prompts/02-audit-lane.md) — run once per lane.

This is where `openDebt` comes from, and it is the phase that took the source
project two months and two rebuilds to get right. Three lessons, all expensive:

### 3a. Partition the SURFACE, not the topics

The source project's first audit ran five lanes — deploy, migrations, edge
functions, web data layer, documents/numbering — and **none of them touched the
UI component tree.** Fifty-one components went unaudited, and the gap was only
discovered months later.

**Enumerate your surface first, in writing, then assign every part of it to
exactly one lane.** Anything unassigned is a gap you have chosen; write it into
`coverageGaps` rather than discovering it later.

### 3b. A "blind" audit is not blind if memory loads

The source project's blind audit was contaminated: persistent project memory
loaded every session and named a finding, which is why that finding had to be
flagged. The same run enumerated only part of the migration list and missed the
rest.

**A blind lane must run with project memory disabled and must enumerate its
surface explicitly** — not sample it.

### 3c. Lanes run independent and get reconciled by a human

Do not let lanes read each other's output. Overlap between two lanes on one
finding is *signal* — it means the problem is reachable from two directions.
Reconcile at the end: dedupe by `file:line`, keep the better-evidenced write-up.

### The entry shape

Every `openDebt` entry carries four fields, and the discipline is what makes the
whole harness work — [MAP_GUIDE.md](MAP_GUIDE.md) is the standard:

| field | rule |
|---|---|
| `summary` | one line; becomes the queue item title |
| `evidence` | **`file:line` citations**, not descriptions |
| `mechanism` | the causal chain — *why* it breaks, which is usually surprising |
| `fix` | the shape of the fix, never the diff |

`evidence` is load-bearing for the harness, not just for humans: the extractor
scrapes file paths out of it to build the collision graph, and the builder
verifies the citation still says what it claims before changing it — reporting
`staleEvidence` when it doesn't. **An item with no file citation is not
dispatchable.**

### Id prefixes

Tag ids by source and never renumber: `S#n` schema review, `L#n` audit lane,
`§x.y` a UX audit section, `pw:n` planned work, `cb:` client backlog. The
partitioner treats an exact id match in an item's `ref` as a collision edge, so
stable ids are what stop two agents doing one job described twice.

> **Checkpoint 3:** ≥8 `bounded` items with real `file:line` evidence, and you
> have read them and believe them.

---

## Phase 4 — invariants and honest coverage

Prompt: [`templates/prompts/03-invariants.md`](../templates/prompts/03-invariants.md)

Two sections, both short, both disproportionately valuable.

**`invariants`** feeds `{{REPO_INVARIANTS}}` in both agent contracts. **The bar
for an entry: it has already caused a real bug here.** A list padded with
plausible-sounding rules trains every agent to skim the whole section, which costs
you the entries that matter.

Write each as *rule → concrete failure mode*:

> ❌ "Preserve the hidden-input contract."
>
> ✅ "Pickers carry the ID in a hidden `<input name=…>` while the visible control
> is name-less. A control whose visible input carries the name submits the display
> LABEL instead of the id — silent data corruption on contact creation."

The second one an agent cannot rationalise past.

Also record what is **deliberately outside** each invariant, and why. The source
project's signed-order lock names five fields excluded on purpose because locking
them would block the repair path for an order created against the wrong party.
Without that note, the next agent "fixes" the omission.

**`coverageGaps`** is where you write down what nobody looked at. It feels like
admitting failure; it is the section that stops a future audit from concluding
"clean" about a surface it never opened.

> **Checkpoint 4:** every invariant names a failure you have personally seen, and
> `coverageGaps` names at least one surface no lane covered.

---

## Phase 5 — wire the extractor and the contracts

Prompt: [`templates/prompts/04-wire.md`](../templates/prompts/04-wire.md)

Adapt `{{EXTRACTION}}` in `.claude/work/extract-queue.mjs` to walk your map's
sections — this is the ~40 lines you actually write. Then run it **without**
`--write` and read three outputs:

- **UNRESOLVED / AMBIGUOUS citations** — each is a hole in the collision graph,
  exactly where you cannot see it. Fix with an alias, a `dirHint`, or an
  `OVERRIDES` entry. **Do not proceed with holes.**
- **collisions** — files claimed by more than one open item. This is the map
  telling you which work is genuinely entangled.
- **scopes** — a high `unscoped` count means your map describes work without
  citing files. Go back to Phase 3.

Then fill `{{REPO_INVARIANTS}}` in both agent contracts from Phase 4, and the
`{{INTEGRATE}}` / `{{HUMAN GATE}}` blocks in `SKILL.md` from Phase 0.

**Commit the map.** Builders run in git worktrees, which materialize only
*tracked* files. An uncommitted map means every builder plans from the previous
commit's evidence while you read the new one — and an evidence path that is
gitignored is a file no builder can open, so it invents an answer and reports
success. [SCARS.md](SCARS.md) #5.

> **Checkpoint 5:** zero unresolved citations; `preflight.sh` is green; the map is
> committed.

---

## Phase 6 — a deliberately small first batch

Two or three genuinely independent `bounded` items. **The first batch tests the
harness, not the backlog.**

```bash
.claude/harness-core/preflight.sh
node .claude/harness-core/plan-batch.mjs --auto 3
node .claude/harness-core/plan-batch.mjs <ids...> --json > /tmp/plan.json
```

Invoke the workflow with `batchName`, `wave: 0`, and a `baseBranch` that is **not**
your main branch — anchors often only exist on the sprint base.

**Read the reduce output for the harness, not the code:**

- Did every dispatched node return? (`dispatched` vs `returned`)
- Did every lens return for every node? A missing lens is a serialisation failure
  ([SCARS.md](SCARS.md) #1), and a lost `pass` reads downstream as *unverified*.
- Any **ANCHOR DISAGREEMENT**? There is no benign explanation.
- Any `staleEvidence`? Feed it back into the map. That is the map improving.

Expect the first batch to find harness bugs. That is what it is for.

---

## The lesson that outranks the rest

From the source project's own batch notes, after nine batches:

> *"Every batch that struggled today struggled on scope, not on skill."*

The cleanest first-time pass was an item that had been **re-scoped three times**
as wrong assumptions were peeled off it. By dispatch it carried the real
constraint, the real hazard, and an explicit do-not-touch.

Time spent sharpening an item before dispatch returns more than any change to the
graph. When a batch goes badly, the fix is almost always in the map — not in the
prompt, and not in `core/`.

---

## Ongoing: keeping the map honest

The source project's map was regenerated twice; the first version was "actively
wrong in ten places" within six weeks. Three disciplines keep it from rotting:

1. **Stamp what was verified, and when.** `"REGENERATED <date> against HEAD
   <sha>"`. A reconciliation pass that only updates what it can *prove* changed
   must **not** restamp the verification date — mark those entries `amended`
   instead. A map claiming freshness it does not have is worse than a stale one.
2. **Closed work MOVES to `shipped`.** Delete it from `openDebt`; do not mark it
   done in place. An item that is both queued and closed is exactly the ambiguity
   this removes, and the extractor never sees `shipped`, so it cannot be
   re-dispatched.
3. **`staleEvidence` from builders is a finding about the map.** Feed it back
   every batch. That loop is what makes the map get *better* under use instead of
   drifting.
