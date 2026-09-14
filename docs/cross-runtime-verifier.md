# Cross-runtime verification — design v0

**Status: the design in §1–§7 is NOT being built, and §8 is why.** The
experiment that was meant to gate shipping an adapter instead retracted the
premise it was testing: run-to-run variance inside one model turned out to be a
larger effect than any systematic blind spot a second vendor would decorrelate.
Three interventions now rank above adapter work, and none of them needs one —
they are listed at the end of §8.

So what this file is now: a **retracted design kept for its findings**, not a
plan. §1–§7 remain coherent and remain unbuilt. Read them as the answer to "if
we ever do this, what did we already work out", not as a roadmap.

**Scope:** the verify stage only. The builder stays Claude-Code-native.

**Home:** drafted in agent-bar, because that is where the thinking was
happening. It lives here now because its findings are about the kit, and because
the one thing it could not be while it sat in a repo under test was *tracked* —
see §8.

### What travelled upstream, and where it landed

| Finding | Landed |
|---|---|
| the canary rig | `core/canary.mjs`, the `install.sh` exclusion, `selftest.sh`'s `── canary rig ──` block |
| §8's aggregate, and the variance finding | SCARS.md #22, DESIGN.md known gaps |
| §2 — the `anchors` lens is not read-only | DESIGN.md, decision #3 |
| §6 — `verify.lenses` is the required set, not a menu | DESIGN.md, decision #3 |
| §4 — a worktree shares the parent's remotes | DESIGN.md known gaps, and the `core/deny-push.sh` header |
| the per-arm numbers | the rig's `results/`, outside every repository |
| §12 R1 — composing with `~/.claude/skills` | **still open, still only here** |

§1–§7 and §9–§11 are the retracted design. Nothing in them is built.

---

## 1. The decision

Verifier first, builder possibly later.

Decorrelated *judgment* is the payoff. Decorrelated *implementation* mostly buys
style variance that then has to be reconciled, and it costs N full builds. The
verifier is also a tenth of the adapter surface: read-only, no scope gate, no
paired-artifact gate, no commit conventions, no publish surface.

The weakness being attacked is already written down in `docs/SURFACE.md` S7 —
*"A builder and a verifier will both report `testGo: pass` and agree with each
other, which is the shape of agreement this harness exists to distrust."*

---

## 2. The finding that reshapes this

**Only two of the three lenses are read-only.**

`verifyPrompt()` in `sprint-batch.mjs` hands the `anchors` lens a worktree to
create, a setup block to run, anchors to execute and a scope gate to shell out
to. It is a build-executing lens that happens to be driven by a model.

That splits the work cleanly, and the split is the design:

| Lens | Nature | Cross-runtime? |
|---|---|---|
| `intent` | judgment — did this do what the item asked | **yes, target** |
| `invariants` | judgment — did it break a known scar | **yes, target** |
| `anchors` | re-run commands, report exit codes | no — see below |

The `anchors` lens is the *least* valuable to make cross-runtime and the *most*
expensive to sandbox. It needs write access, a build toolchain, and the project's
`setup` block; and the thing it produces — an observed exit code — has almost no
model-judgment content. A second runtime re-running `go test` finds exactly what
the first one found.

Leave `anchors` where it is. It is also the strongest candidate in the whole kit
for being demoted to plain code later, since a process can run the anchors in a
fresh tree and report exit codes without a model in the loop at all. Out of
scope here; noted so it is not lost.

---

## 3. The verifier contract

A verifier is a pure function:

```
(repo@base, node branch, queue item, lens) -> verdict
```

Nothing in that signature is Claude-Code-specific. The runtime is an
implementation detail of how the function gets evaluated.

### Invocation

One primitive, and one convention.

```
dispatch(promptFile, { cwd, readOnly, timeoutSec, env }) -> { exitCode }
```

**Convention: the agent writes its verdict to a path the kit names. The kit
validates it in plain code.**

Do not depend on any runtime's structured-output enforcement. `schema:` on
`agent()` is a Claude Code feature; `codex exec` and the rest have their own
shapes or none. A file plus JSON Schema validation is the lowest common
denominator and it is already the kit's posture toward anchors — claimed versus
observed, never trust the report.

The prompt is passed as a **file**, not an argv string. `verifyPrompt()` output
is long, contains backticks, newlines and shell metacharacters, and has already
been observed to mangle across a tool-call boundary.

### Failure semantics

| Condition | Outcome |
|---|---|
| exit 0, valid verdict | the verdict |
| exit non-zero | `unverified` |
| timeout / killed | `unverified` |
| verdict file missing | `unverified` |
| verdict file fails schema | `unverified` |

**Never `pass`, never `reject`.** The reduce already draws this distinction hard
— "a node whose verifier crashed has not been judged; reporting it as rejected
invents a finding nobody made." A foreign runtime that half-works must land in
`unverified` and nowhere else.

---

## 4. Substrate guarantees

Today five of the kit's guarantees are enforced by the Claude Code runtime. A
cross-runtime verifier has to own them. Each one gets *stronger* on the way
down, which is the argument for doing this even if only one runtime ever ships.

| Guarantee | Today | Becomes |
|---|---|---|
| read-only | `tools:` frontmatter | perms-stripped verify tree |
| cannot publish | PreToolUse hook | **a tree with no remote** |
| fresh context | fresh subagent | fresh process |
| well-formed output | `schema:` on `agent()` | JSON Schema over a file |
| parallelism | `parallel()` | process pool |

### The verify tree

Per (node, lens):

```
git clone --shared --no-checkout <repo> <verifyTree>
git -C <verifyTree> checkout <branch>
git -C <verifyTree> remote remove origin
install the deny hook in <verifyTree>/.git/hooks/
chmod -R a-w <verifyTree>          # judgment lenses only
```

Two things to note.

**A worktree does not carry the guarantee.** `git worktree` shares `.git/config`
with the parent, remotes included, so a verifier sitting in a worktree still has
the project's real remote in reach. A `--shared` clone with `origin` removed has
nowhere to send anything, because there is no destination configured at all.
That is a substrate guarantee rather than a configured one — it holds for a
runtime whose permission model we do not control, and it holds for a human.

`--shared` uses alternates, so the clone is cheap and the object database is not
copied. Do not gc the parent while a verify tree is alive; they are short-lived.

The hook is belt and braces, and it is what carries the guarantee into any tree
that *does* end up with a remote.

---

## 5. Verdict provenance

`VERDICT_SCHEMA` has no field saying who produced the verdict. It needs one, for
the experiment in §8 and for advisory reporting.

Additive, optional, defaulted so existing verdicts stay valid:

```
runtime   : string   # "claude" | "codex" | ... — the adapter id
model     : string   # as reported/configured, for the record only
advisory  : boolean  # default false; see §6
```

`model` is recorded, never branched on. The kit must not contain a model id
anywhere. Config names a runtime; the runtime resolves the model. This is the
discipline `harness.config.json` already keeps with anchors — a command with an
exit code, never a description — and it is exactly what the `arena` skill
violates by hardcoding four model ids and a machine-local config path into
prose.

---

## 6. Advisory mode, and the trap

A new lens id cannot simply be added to `verify.lenses`. That array is the
required set: `requireAllLenses` compares `verdicts.length === lenses.length`,
and `missingLenses` is computed over it. **Add a foreign lens there and the first
time that runtime is missing, rate-limited or misconfigured, every node in the
wave goes `unverified`.**

So a foreign lens starts non-voting:

- it is dispatched, validated and reported,
- it does not count toward `requireAllLenses`,
- it cannot reject a node,
- its findings appear in the report under their own heading.

Promotion to voting is a deliberate config change, made after §8 produces a
false-reject rate. A noisy foreign lens with a veto, against a default-REJECT
posture, halts the queue.

This is the one change `reduceWave` needs: accept verdicts that are surfaced but
not counted. It is a pure function with fixture tests (`reduce-fixture.mjs`), so
the change ships with cases — an advisory reject must not flip `accepted`, and a
missing advisory verdict must not produce `unverified`.

---

## 7. Where the verdicts are collected

`reduceWave` is already fenced as a pure function of collected verdicts, sliced
out of the file by upstream's `selftest.sh` and evaluated against fixtures. It
does not care where a verdict came from.

So v0 does not touch the Workflow dispatch path at all:

```
  workflow (as today)          -> build + 3 native lenses
  plain node CLI (new)         -> foreign lenses over the node branches
  reduce (existing pure fn)    -> called once, over the union
```

`workflowSlice()` stays unchanged in v0 — runtime config never crosses the
workflow boundary, because foreign dispatch happens outside it.

This is deliberately the seam that keeps the door open. The adapter interface is
designed so the same function can be called by `spawn()` from a headless runner
later, making the Workflow script one front-end of two rather than a thing to be
replaced.

---

## 8. The experiment that gates shipping this

**Built, run, and since graduated. The TOOL is now upstream at
`core/canary.mjs`; the RIG still lives OUTSIDE every repository under test, at
`~/.claude/canary/<project>/`, and that split is load-bearing.**

`sprint-batch.mjs` supports `prebuilt` canary nodes — branches that can claim a
green they did not earn, precisely so the claimed-versus-observed check has
something to catch. `canary.mjs` emits a plan of exactly those.

The split is enforced, not merely intended. `core/canary.mjs` is the one file
`install.sh` deliberately does not copy into a project, because installed it
would sit in a tree the verifier it is measuring can read — and it names the rig
directory. `selftest.sh` asserts both halves: that the installer leaves it out,
and that nothing it does install names the rig path. The rig directory now holds
only `cases.json`, `truth.json`, `patches/` and `results/`.

```
canary.mjs list | plant | plan > plan.json | score arm=results.json | clean
```

The cases split between planted defects and clean controls, in a ratio recorded
only in the rig. Every one was verified to leave every anchor green, both before
commit and again on the planted branch. That is the property that makes it a
*judgment* canary: the `anchors` lens has nothing to find, so a detection can
only come from judgment.

**Why nothing about the cases is written down in this repo.** The first control
arm caught a verifier grepping the ground-truth manifest out of the working tree
it was launched from. It disclosed the grep and its finding held up
independently, so that run stands — but a readable rig makes every later arm
comparison worthless, and a document naming the cases is exactly as readable as
a manifest. So this section records the METHOD and the AGGREGATE only. Case
detail, ground truth, patches and per-run write-ups live outside any repo under
test. Gitignoring is not sufficient; an ignored file is still greppable.

Residual traces are accepted where they name no case. `sprint-batch.mjs`
describes the canary concept in a comment; `core/canary.mjs` describes the
method in its header; SCARS.md #22 and DESIGN.md carry the aggregate. All of
those are readable, and none of them is a manifest. **This file used to record
more than any of them — the case count, the defect/control split, the per-arm
numbers — and that is why it could not be tracked where it was written.** A
tracked copy in a repo under test is materialised into every verifier worktree,
and the leak `install.sh` now excludes `canary.mjs` to prevent would have come
straight back in through `docs/`. Those numbers now sit with the rig write-ups,
which is what let the rest of this file move up here and be tracked.

### The per-arm record

Arms 1–3 (2026-09-11), arm 4 (2026-09-12) and arm 5 (2026-09-13) are written up
in the rig's `results/`, outside every repository. Case counts, the
defect/control split and per-arm detection numbers stay there for the same
reason the patches do. What survives here is what they *mean*, below.

### What this does to the premise of this document

§8 was built on the idea that a second provider decorrelates *systematic* blind
spots. On this evidence the dominant failure mode is **run-to-run variance
within one model**, not a systematic blind spot. Variance is answered by
repetition and redundancy, both of which the harness already has, and neither of
which needs a second vendor.

Three interventions now rank above any adapter work, and none needs one:

1. Route substantive `couldNotVerify` content into the accept decision — a lens
   naming a defect in another lens's territory should at minimum warn.
2. Decide what to do about nodes accepted with zero rejects on a single run:
   re-verify, or accept that some defects pass on any given run.
3. Only then ask whether a foreign runtime adds anything.

**§1's ordering still holds — verifier before builder — but the reason has
changed.** It is no longer "decorrelate the vendor". It is "the verify stage is
less deterministic than its reports imply", and that is a cheaper problem.

### Findings about the repo, not the rig

An arm judges the repo it runs against, so it also surfaces real defects that
have nothing to do with the planted ones. Those are project findings, not rig
findings: file them in that project's queue and record them with the run's
write-up, not here.

### Arms

Run three arms over the same branches:

| Arm | Varies | Holds constant |
|---|---|---|
| control | — | model, scaffold |
| tier 2 | model | scaffold (Claude Code) |
| tier 3 | model + scaffold | nothing |

Measure three numbers:

1. detection rate per arm,
2. **disjoint detections** — defects found by exactly one arm,
3. false-reject rate on clean branches.

(2) is the whole case. Two competent arms finding the same defects means
provider diversity bought a second opinion that three lenses already provide.
(3) decides whether a foreign lens is ever allowed to vote.

If tier 3 does not beat tier 2 on (2), stop: take the cheap win, add a
second-family lens inside Claude Code, and do not build the adapter.

---

## 9. Config deltas

Additive. A project that configures nothing gets byte-identical behaviour and
never sees the word "runtime".

```jsonc
{
  "verify": {
    "lenses": ["intent", "invariants", "anchors"],   // unchanged: the required set
    "requireAllLenses": true,
    "advisoryLenses": [                              // new, optional, default []
      { "id": "intent-x", "lens": "intent", "runtime": "codex" }
    ]
  },
  "runtimes": {                                      // new, optional
    "codex": {
      "cmd": ["..."],                                // argv template
      "promptVia": "file",
      "verdictOut": "{verdictPath}",
      "requiresEnv": ["..."],
      "timeoutSec": 600,
      "readOnlyCapable": true
    }
  }
}
```

`agents: { builder, verifier }` in `lib/config.mjs` is already the role seam. It
currently resolves to Claude Code subagent names; it grows a runtime dimension
when the builder follows.

### Naming

The kit says "agent type" where it will need **role binding**: a lens maps to
`(runtime, model, agent definition)`. Worth renaming before the schema
calcifies, since the kit is synced into a new repo each time.

---

## 10. Per-runtime invocation — UNVERIFIED

Targets: `claude`, `cursor`, `codex`, `opencode`, `pi`.

Each ships a non-interactive one-shot form, which is all `dispatch` needs. **The
exact argv, cwd semantics, read-only flags, exit-code meanings and how each
reports failure are not yet verified and must not be assumed.** One probe per
runtime, recorded here, before any adapter is written. A runtime that cannot be
made to (a) run headless in a given directory, (b) be denied write access, and
(c) exit non-zero on failure does not get an adapter.

| Runtime | argv | cwd | read-only | exit codes |
|---|---|---|---|---|
| claude | ? | ? | ? | ? |
| codex | ? | ? | ? | ? |
| cursor | ? | ? | ? | ? |
| opencode | ? | ? | ? | ? |
| pi | ? | ? | ? | ? |

---

## 11. Deferred

- **Builder.** Needs worktree, scope gate, paired-artifact gate, anchor
  execution, commit conventions, publish denial. Revisit only if §8 shows the
  payoff is there.
- **Arena-shaped nodes.** N builders at one item plus synthesis, selected by
  item class in `plan-batch.mjs`, for items whose risk is *shape* rather than
  correctness. Needs a fourth role (`synthesizer`) with write access. Carries
  one idea worth stealing on its own: **divergence as a spec defect** — N
  candidates disagreeing wildly means the item was under-specified, which today
  is indistinguishable from a builder failing.
- **Headless runner.** `core/run-wave.mjs` as a plain process, making the
  Workflow script one front-end of two. Brings durable restartable runs and live
  observability with it.
- **Demoting `anchors` to plain code.** See §2.

---

## 12. Open requirements

### R1 — compose with `~/.claude/skills` (2026-09-11)

`~/.claude/skills` is a symlink to `git_projects/skills`, a 27-skill library whose
first commit is "portable agent skills for the plan-to-sprint pipeline". Several
of them already reach into harness internals, so this is composition, not
adjacency. The pipeline is:

```
navigator -> plannedWork.backlog -> scope -> openDebt -> extract-queue
          -> QUEUE.json -> plan-batch -> sprint -> canary/interrogate
```

Three concrete consequences for this design.

**`interrogate` already owns a reviewer roster, in this config file.** It reads
`interrogate.reviewers` from `.claude/harness.config.json` — one entry per
reviewer, each naming a model, read-only, with defined behaviour for slug rot
and for `inherit-parent` / `auto`. **§9's `runtimes` and `advisoryLenses` must
extend that roster rather than invent a parallel key**, or the project ends up
with two places that answer "who reviews this, on what model".

But note what `interrogate` is and is not. It spawns one reviewer per configured
*model* through the host's own subagent mechanism — **tier 2 in §2's terms:
decorrelated weights, identical scaffold**. Its `agents/openai.yaml` is interface
metadata for a skill platform, not a runtime adapter. So it does not answer the
cross-runtime question; it answers the cheaper half of it, and it is the
ready-made **tier-2 arm for the §8 experiment**. Its output is changeset-shaped
(findings against a rubric) rather than lens-shaped (a verdict per node), so
scoring it needs a mapping into `canary.mjs score`.

**Schema conflict, small and real.** `harness.config.schema.json` sets root
`additionalProperties: false` and has no `interrogate` property. `loadConfig`
will not reject the block — `validate()` only checks required fields — but any
schema-aware editor flags it. Add the property when the roster lands.

**`no-comments` collides with house style.** It deletes comments in scope and
"fixes the code they were covering for". Both this repo and `core/` carry
deliberately dense explanatory comments recording scars. If that skill is ever
run here, the collision is head-on and should be an explicit exclusion.

### R2 — (add as decided)
