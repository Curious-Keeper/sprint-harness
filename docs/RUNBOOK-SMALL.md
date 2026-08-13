# Runbook — small project (compressed path)

The [full runbook](RUNBOOK.md) is sized for a codebase with five or more distinct
surfaces and a backlog wide enough that fanning out saves real wall-clock. Below
that, most of its ceremony is overhead.

This is the compressed path: **3–4 light sessions instead of 4–6 heavy ones.**

Read the sizing fork first. On a small project the honest answer is sometimes
"take half the kit", and half the kit is still worth having.

---

## The sizing fork

The harness has two halves, and they pay off at **different sizes**.

| Half | What it is | Pays off at |
|---|---|---|
| **The spine** | map + anchors + deny-push + paired-artifact gate | **any size**, including one-person projects |
| **The graph** | queue, partitioner, fan-out, N-lens verify | only when work is genuinely wide |

Answer these three about the target project:

1. **Can you name 8+ open items where most pairs touch no common file?**
2. **Do you have ≥2 distinct surfaces?** (e.g. schema + app, or API + worker.) One
   flat module tree is one surface.
3. **Will more than one agent's worth of work run per sitting?**

**3 yes → run the compressed path below.** You get everything.

**1–2 yes → take the spine, skip the graph.** See the next section. This is a
legitimate outcome, not a failure — and it is *cheaper to adopt later* than to
adopt now and resent.

**0 yes → take the map and the anchors only.** A single agent in the main loop
with a good map beats a graph with a thin one, every time.

### The density trap

Worth knowing before you decide. On a small codebase the collision graph is
**denser**, not sparser — fewer files means more items sharing them. The
partitioner will correctly merge items into serial nodes, and a batch of six items
can legitimately partition into two nodes.

That is the system working. But it means the fan-out width you actually get is
lower than the item count suggests, so judge question 1 by *files*, not by item
count. If your eight items all touch the same three files, you have one node.

---

## The spine alone

If the graph does not earn its place yet, this is the subset that still does. It
takes about half a session.

```bash
~/git_projects/sprint-harness/install.sh /path/to/project --stack <stack>
```

Then keep:

- **`harness.config.json`** — anchors and setup. The fresh-worktree probe below is
  worth doing regardless of whether you ever fan out.
- **`.claude/hooks/deny-push.sh`** — already wired by the installer. Value is
  independent of project size; it is a gate an agent cannot argue with.
- **`.claude/work/paired-artifact-gate.sh`** — if you have any "change X, change Y"
  convention, this is the cheapest way to make it bind.
- **`APP_MAP.json`** — via prompt S1 below. On a small project the map is *more*
  valuable per line, not less, because there is no second person to ask.
- **`docs/SCARS.md`** as reading.

Skip: `QUEUE.json`, the extractor, `plan-batch.mjs`, the workflow, both agent
contracts.

Adopting the graph later costs one session (prompts S3 + 04) and nothing you
wrote is wasted — the map is the expensive artifact and it carries over intact.

---

## The compressed path

### Step 1 — install, before any session

You do **not** copy this kit into the project. It stays where it is and installs
itself:

```bash
cd /path/to/your-existing-project
git checkout -b chore/sprint-harness
~/git_projects/sprint-harness/install.sh . --stack <node-web|go-service|blank>
```

That copies `core/` to `.claude/harness-core/`, drops the templates you will fill
in, and wires the push guard into `.claude/settings.json`. Nothing is pasted by
hand at any point.

### Step 2 — commit it, and check it is not ignored

```bash
git add .claude && git commit -m "chore: install sprint harness"
```

**This is load-bearing, not hygiene.** Builders run in git worktrees, which
materialize **only tracked files**. Many projects gitignore `.claude/` — and then
a builder's worktree contains no harness at all: an anchor that invokes
`.claude/work/paired-artifact-gate.sh` does not fail, the file *is not there*.

`install.sh` checks this and stops you loudly if `.claude/` is ignored. If it
does, un-ignore the harness before going further:

```gitignore
.claude/*
!.claude/harness-core/
!.claude/agents/
!.claude/skills/
!.claude/work/
!.claude/hooks/
!.claude/harness.config.json
!.claude/settings.json
```

The general rule, which also governs where the map lives: **anything an anchor
invokes, and anything an item's evidence cites, must be tracked.**

### Step 3 — run the sessions

```
  SESSION A   config + anchors + map skeleton + traps      prompt S1
  SESSION B   audit pass — lane 1                          prompt S2
  SESSION C   audit pass — lane 2                          prompt S2
  SESSION D   invariants + coverage + extractor + wire      prompt S3
  SESSION E   a deliberately small first batch              prompt 05
```

Open a session **in the target project** and paste the prompt. Each prompt is
self-contained; the agent reads what it needs from the installed kit.

B and C are short and can run back to back. Realistically this is a long day, or
two comfortable ones.

> Anything a prompt tells the agent to run — the `/tmp/harness-probe` clone in S1,
> for instance — happens **inside** that session. Those are tasks for the agent,
> not setup steps for you.

### What collapsed, and why it was safe

| Full runbook | Compressed | Why safe here |
|---|---|---|
| Phase 0 + 1 + 2 separate | **Session A** | With ≤3 surfaces, the surface inventory is a paragraph, not a document. It stays a written artifact, just inline. |
| Phase 3, one lane per surface | **2 lanes** | Lane count should track surface count. Two is the floor — see below. |
| Phase 4 separate | **folded into D** | `invariants` on a small project is typically 3–8 entries, and you have just read both lanes' output. |
| Phase 5 separate | **folded into D** | The extractor's `{{EXTRACTION}}` block is shorter when the map has fewer sections. |

---

## What must NOT collapse

Four things. Each one is load-bearing at every size, and each maps to a failure
that already happened.

### 1. Anchors still come before the map

Non-negotiable, and cheaper here than anywhere. A small project's anchors take
twenty minutes to establish. Writing the map first means writing a document that
verifies nothing, and you will not discover that until Session E.

Still run the fresh-worktree probe for real:

```bash
git clone . /tmp/harness-probe && cd /tmp/harness-probe && <anchors>
```

### 2. Two audit lanes minimum, in separate sessions

This is the one people cut, and it is the one that must survive.

The lanes are not about *coverage* on a small project — one careful pass can
enumerate a small codebase exhaustively. They are about **independence**. A single
session that writes the map and then audits it will confirm the assumptions it
just absorbed rather than test them. That is the same failure as a builder grading
its own work, one layer earlier.

If the project genuinely has only one surface, run the two lanes with **different
questions** rather than different paths:

- **lane 1 — correctness**: what produces a *wrong result* rather than an error?
- **lane 2 — integrity**: what swallows errors, what breaks under concurrent or
  partial writes, what depends on a coincidence elsewhere?

Different questions over the same code are still independent evidence. Identical
questions over the same code are one opinion run twice.

And keep the rule: **project memory off**. The source project's blind audit was
invalidated because memory loaded every session and named a finding.

### 3. Zero unresolved citations before the first batch

The extractor's dry run must come back clean. This is not a quality bar, it is a
correctness one: an unresolved or ambiguous citation is a hole in the collision
graph exactly where nobody can see it, and on a dense small-project graph a missed
edge is *more* likely to bite, not less.

### 4. The first batch is still a throwaway

2–3 items you would be happy to discard. It tests the harness, not the backlog.
On a small project it is tempting to make batch one "the real work" because the
backlog is short. Don't.

---

## Small-project adjustments to the map

The [map guide](MAP_GUIDE.md) still applies in full. Three things change:

**`evolutionTraps` may be nearly empty, and that is fine.** A young project has
not dropped much yet. Still run the mining commands — one trap found is worth the
two minutes:

```bash
git log -p --diff-filter=M -- <migrations> | grep -iE '^\+.*(DROP|RENAME)'
git log --diff-filter=D --name-only --format='%h %ad %s' --date=short
```

**`invariants` will be short, and the bar does NOT relax.** The bar is still "it
has already caused a real bug here". Three real invariants are a good map. Eight
aspirational ones are a worse map than three, because padding teaches every agent
to skim the section. If a young project has zero qualifying invariants, write
zero and say so — the section will fill in as things break.

**`coverageGaps` matters more, not less.** With two lanes there is more uncovered
surface by definition. Name it explicitly, so a future audit cannot mistake "we
ran two lanes" for "we looked at everything".

---

## When to graduate

Move to the [full runbook](RUNBOOK.md) when any of these becomes true:

- a batch's partition regularly produces **4+ parallel nodes** — the graph is
  earning its coordination cost
- you add a **third or fourth distinct surface** — lane count should track it
- an audit lane starts **missing things you later find by hand** — two questions
  are no longer enough, and it is time to partition by surface instead
- `coverageGaps` stops shrinking between passes

Graduating costs nothing structural. It is more lanes and more items; `core/` is
identical at both sizes.
