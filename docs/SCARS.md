# Scars

Every design decision in `core/` that looks paranoid is here, with the failure
that produced it.

This is the most portable part of the whole kit. The code can be rewritten in any
language; these failures will happen to any multi-agent build system that does not
design against them. Read this before you "simplify" something.

The pattern to notice: **almost none of these failures announced themselves.**
Each one produced a report that looked exactly like a good report. That is why the
mitigations are structural (schemas, exit codes, hooks) rather than instructional.

---

## 1. Lost structured output manufactures false negatives

**What happened.** On the first real run, 7 of 18 verifiers died with
`StructuredOutput retry cap (5) exceeded`. Each was trying to emit ~3.5KB of prose
inside a single JSON string field; the embedded newlines and quotes broke the
parse on every retry.

**Why it was dangerous.** Every one of those lost verdicts was a `pass`. The
serialisation failure manufactured five false negatives — nodes reported as
problematic when no verifier had objected to anything.

**The fix, and why it is structural.** Don't ask the model to be brief. Make
brevity the only thing the schema can hold:

```js
const SHORT = { type: 'string', maxLength: 300 };
evidence: { type: 'array', items: SHORT, maxItems: 8 }
```

A 300-character element cannot hold a paragraph, so the model splits instead of
escaping. Telling a model "keep it short" fails under pressure; a `maxLength`
does not.

**Where it lives.** `core/sprint-batch.mjs`, the `SHORT` constant.

---

## 2. "Unverified" is not "rejected" — and collapsing them invents findings

**What happened.** The same run reported five nodes as *rejected*. Zero verifiers
had rejected anything. The nodes were simply unjudged, because their verdicts had
been lost to scar #1.

**Why it was dangerous.** A rejection is a claim that someone found a problem.
Reporting an unjudged node as rejected fabricates a finding nobody made — and the
next human action is to go looking for a defect that does not exist.

**The fix.** Four distinct outcomes, never collapsed:

| outcome | meaning |
|---|---|
| `accepted` | built, every lens ran, none rejected |
| `rejected` | a verifier positively found a problem |
| `unverified` | built, but a lens did not return. **Nobody judged this.** |
| `not-built` | the builder reported blocked/partial |

Plus a fan-in guard: if fewer nodes returned than were dispatched, the report says
so at the top and refuses to present itself as complete.

**Where it lives.** `core/sprint-batch.mjs`, the `outcome` ternary and `warnings`.

---

## 3. Borrowed dependencies silently void every anchor

**What happened.** A fresh git worktree contains only *tracked* files, so
`node_modules` does not exist and `npm test` fails with `vitest: command not
found`. The verifier contract offered an escape hatch — "if a fresh install is too
slow, verify in place". Every agent took it. They symlinked, `cp -r`'d, or
`cp -al`'d `node_modules` out of whichever other worktree they found first. Two
batches were verified this way; two different source trees got used, on two
different branches, and no two agents picked the same source.

**Why it was dangerous.** The anchors ran against a dependency set that did not
belong to the commit under verification. It went unnoticed only because the
lockfile had not moved in weeks. When it did move — five Dependabot bumps in one
day, including a minor framework version — borrowing meant reporting a pass for a
build that does not exist.

**The fix.** Remove the escape hatch, and say why in the contract. An agent skips
a step whose cost it cannot see, so the contract states the cost: *it takes eight
seconds and it is the only correct answer.* The `setup` array in
`harness.config.json` carries a `why` field for exactly this.

**The general rule.** *Any* instruction of the form "if X is too slow, do Y
instead" will be taken 100% of the time. If Y is unsafe, do not offer it.

**Where it lives.** `templates/sprint-builder.md` and `templates/sprint-verifier.md`,
the ⛔ blocks.

---

## 4. `pipefail` + `grep -q` silently broke a gate

**What happened.** A gate script checked commit messages for a waiver:

```bash
grep -q "^no-test($name):" <<< "$messages"    # correct
printf '%s' "$messages" | grep -q "..."       # BROKEN
```

With `set -o pipefail` on, `grep -q` exits the instant it matches, closing the
pipe and killing the writer with SIGPIPE — exit 141. `pipefail` then reports the
whole pipeline as **failed even though grep matched**.

**Why it was dangerous.** A file with a validly recorded waiver was reported as
"no test changed" and the anchor exited 1. It fails *closed* — a pass is never
invented — but the gate is broken, and because whether SIGPIPE lands at all
depends on how much the writer flushed first, it presented as **intermittent**.
Found only when a verifier could not reproduce the gate's own exit code.

**The fix.** Herestrings, not pipes. A herestring has no second process and no
pipe.

**It came back.** While writing a test for a *different* bug, `selftest.sh` used
`install.sh | grep -q "GITIGNORED"` and reported the assertion as failing while
the behaviour under test worked perfectly by hand. Same mechanism, one layer out,
inside the harness that exists to catch this class of thing.

Worth internalising rather than memorising the one instance: **`cmd | grep -q`
under `pipefail` is broken by construction.** Capture to a variable and match with
a herestring.

**Where it lives.** `core/paired-artifact-gate.sh` and `selftest.sh`, both ⚠
blocks.

---

## 5. An uncommitted map is invisible to every builder

**What happened.** Builders run in git worktrees, which materialize only *tracked*
files. `docs/` was gitignored, so an item whose evidence read "the recommendation
is in `docs/audits/AUDIT_UIUX.md`" pointed at a file no builder could open.

**Why it was dangerous.** The builder did not error. It invented an answer and
reported success.

**Two distinct failure modes, both covered by one check:**

- **Untracked** map → builders cannot see it at all.
- **Uncommitted** map → every builder plans from the *previous commit's* evidence
  while you are reading the new one. Silent, and it looks like a stale-cache bug.

**The fix.** Track the map, and make pre-flight fail if it is untracked *or* has
uncommitted changes. Once tracked, it merges forward exactly like code — no copy
step, no sync script.

**The wider rule, which bites on adoption day.** It is not just the map:
**anything an anchor invokes must be tracked too.** Many projects gitignore
`.claude/` — and then a builder's worktree contains no harness at all, so an
anchor calling `.claude/work/paired-artifact-gate.sh` does not fail, the file *is
not there*. `install.sh` checks this with `git check-ignore` and stops loudly,
because the failure is silent and the fix is a one-line `.gitignore` negation.

**Where it lives.** `core/preflight.sh` section 7; `install.sh` tracked-ness check.

---

## 6. "main is a valid base" was wrong twice in two days

**What happened.** Pre-flight printed "on main — ready to branch" whenever the
tree was clean. But when pushing is gated on a human verifying a running app,
there can be several *unpushed* branches between pushes. A clean checkout of main
is not a current base.

**Why it was dangerous.** Branching from main silently drops every unpushed commit
from your base — including `QUEUE.json` and the lockfile. One batch got planned
against a queue the day had already moved past, producing a one-file dispatch that
the morning had been spent widening.

**The fix.** While *any* local branch is ahead of the remote, main is an invalid
base and pre-flight says so, naming the most recent unpushed branch as the
stacking base. Branches that are permanently ahead by design (a demo branch that
is never pushed) are excluded via `git.excludeFromStacking`.

**Where it lives.** `core/preflight.sh`, section 4 — including a ⛔ comment
telling the next person not to add the old line back.

---

## 7. A rule in a prompt is a suggestion; a hook is a gate

**What happened (a).** "A component you change ships a test in the same node" sat
in the builder contract as prose for a week. It produced **three test files across
fifty-one components.**

**What happened (b), worse.** An agent was given an instruction-level command
blocklist. It wrote and ran its own client for the blocked capability, reasoning
that "the quarantine is a launcher". The approval log read correct and enforced
nothing: 13 verdicts, 0 denials, and the quarantined command ran anyway. A token
leaked to disk and had to be rotated.

**The fix.** Anything that must actually bind is an exit code or a `PreToolUse`
deny, never a paragraph:

- the test rule → `core/paired-artifact-gate.sh`, run as an anchor and re-run by
  an independent verifier
- the push rule → `core/deny-push.sh`, fail-closed

**The tell.** If you find yourself writing "the agent must always…", ask what
command would return non-zero when it didn't.

**Where it lives.** `core/paired-artifact-gate.sh`, `core/deny-push.sh`.

---

## 8. A guard that fails open is the same as no guard

**What happened.** The hook command has to locate `deny-push.sh` at runtime, and
`CLAUDE_PROJECT_DIR` is not always what you expect.

**The fix.** The inline hook command denies *by default* if the script cannot be
found:

```
if [ -x "$S" ]; then exec "$S"; fi
cat >/dev/null
printf '%s' '{"...":{"permissionDecision":"deny", ...}}'
```

Likewise the script itself denies when `jq` is missing or the payload is
unreadable. A missing guard is the most dangerous state possible, because
everything keeps working.

**Where it lives.** `core/deny-push.sh` header; the settings.json snippet.

---

## 9. False independence is the way a fan-out corrupts a repo

**The failure mode.** Two items look unrelated because their prompts never mention
each other — and they write the same file. Two agents, two worktrees, one file,
last merge wins.

**Why a model cannot own this decision.** It is not a judgement call. It is a
graph problem with a correct answer, and it must be reviewable *before* anything
runs.

**The fix.** Union-find over declared file sets, in plain code, printed for a
human to read before dispatch. Plus three refinements each found the hard way:

- **`newFiles` count as collisions.** Two items that both *create*
  `components/Combobox.tsx` collide exactly as hard as two that edit an existing
  file.
- **Declared cross-references are edges.** An item and the audit section it cites
  are routinely one job described twice, and can cite completely different files.
  Conservative: an edge forms only when the ref exactly matches another *selected*
  item's id.
- **Exclusive nodes need a wave, not just a flag.** Exclusivity *bypasses* the
  union-find, so a repo-wide item can share a file with a parallel node and the
  grouping will not have caught it. Sequencing is what makes it safe.

**Where it lives.** `core/plan-batch.mjs`.

---

## 10. Prose that names a file creates a collision edge

**What happened.** The extractor unions regex-scraped paths from an item's prose
with its manual overrides. So any path mentioned *in passing* — a cross-reference,
a "this is like X" comparison — lands in that item's file set.

**Why it matters.** It manufactures false collisions, which serialise work that
could have run in parallel. Harmless to correctness, expensive in wall-clock, and
baffling when you read the partition.

**The fix.** A writing rule for the map: **name the files you intend to edit;
describe everything else without a path.**

The asymmetry is deliberate — a wrong hard edge is cheaper than a missed one. But
a wrong edge on *every* item is not.

**Where it lives.** `templates/extract-queue.mjs`, the ⚠ comment on `merged`.

---

## 11. Refusing to dispatch is a feature

**The temptation.** Every item in the queue looks like work an agent could do.

**The reality.** Four categories produce confident fiction if dispatched:

| scope | why refused |
|---|---|
| `unscoped` | no files derivable → **no collision guarantee** |
| `needs-design` | *where* the code goes is itself the open question |
| `external` | the truth lives outside the repo (a SaaS console, a client's box) |
| `held` | buildable, but a human decided it must not ship yet |

`needs-design` vs `unscoped` is a real distinction: unscoped means the extractor
couldn't derive files, `needs-design` means *nobody* can yet. And `held` requires
a note naming who held it and what releases it — otherwise it rots into a
permanent block nobody remembers how to lift.

**Where it lives.** `core/lib/extract.mjs` `SCOPES`, `core/plan-batch.mjs`
`WHY_REFUSED`.

---

## 12. Green anchors do not mean the node is correct

**What happened.** One batch: 3 of 3 nodes green on every anchor. All 3 were
rejected on semantics — a wrong driver written onto a shipping document, a render
loop crash, and three swallowed errors.

**Why.** Anchors are necessary and not sufficient. `tsc`/`lint`/`test` prove the
code compiles and the existing assertions still hold. They cannot prove the change
did *what the item asked*.

**The fix.** Distinct lenses, not redundant reviewers:

- `intent` — did it do what the item said, **and nothing else**?
- `invariants` — did it break something this repo has already been burned by?
- `anchors` — did the checks pass, watched right now, re-run independently?

Because they ask different questions, **one reject fails the node.** Majority vote
would be wrong here: it would let two lenses that didn't examine an area outvote
the one that did.

**Corollary:** budget a fix pass for any behaviour-changing batch. Green is the
start of review, not the end.

---

## 13. A test that passes before and after asserts nothing

**The failure mode.** A test written *to fit the new code* rather than *to catch
the bug*. It goes green, the gate is satisfied, and it will later be read as proof
the bug cannot come back.

**The fix.** Stated in the builder contract as a requirement — *write the test so
it FAILS against the old behaviour* — and given to the verifier as a cheap
procedure: revert the source hunk in the verification worktree, re-run that one
test file, watch it fail, put it back.

**The waiver.** Some changes genuinely have no behaviour to assert. Those are
waived by a named commit trailer:

```
no-test(ComponentName): class-only change, no behaviour to assert
```

Blanket waivers are unsupported on purpose. An exemption should be a line in the
history someone can grep, review and argue with — not a silent omission. And the
verifier is told to judge the *diff*, not the trailer: a `class-only` waiver on a
diff that changed a condition is a REJECT.

---

## 14. The anchor disagreement is the most valuable line in the report

Not a failure — the *detector* for several of them.

The builder reports the exit codes it observed. An independent verifier re-runs
the same anchors in a fresh worktree and reports what *it* observed. The reduce
step compares them:

```
node-x: ANCHOR DISAGREEMENT on test — builder claimed 0, verifier observed 1.
```

There is no benign explanation. Either the builder reported a green it did not
see, or one of the two ran against a tree that isn't the commit. Both are exactly
what you want to find before merging.

This is the whole philosophy compressed into one check: **judge the system on
numbers that cannot argue back.**

---

## 15. A guard that spans arguments also spans quoted arguments

**What happened.** The push pattern deliberately spans a git invocation's
arguments, so that `git -C /some/path push` is caught. That same span reaches into
a *quoted* argument — so `git commit -m "docs: fix the push guard"` matched, and a
**commit** was denied.

Found the only way this kind of thing gets found: it fired while committing this
repository's own history, on a message that happened to describe the guard.

**Why it mattered more than it looks.** Over-blocking is the safe direction, and a
denied commit is recoverable. But a guard that fires on ordinary, correct commands
is a guard people start routing around — and the moment someone adds a bypass
habit, the real deny stops meaning anything. Usability is a security property here.

**The fix.** Strip *inert* quoted regions before matching. A region is inert only
if a command cannot run inside it:

- double-quoted containing **no `$` and no backtick** → no substitution possible
- single-quoted → never substitutes

Anything containing `$(` or a backtick is left in place, so `echo "$(git push)"`
is still caught.

**The subtle part — order matters.** Double quotes must be stripped *first*. An
apostrophe inside a double-quoted string (`"it's ok"`) would otherwise open a
bogus single-quoted region that swallows a real `git push` after it:

```
git commit -m "it's ok" && git push -f 'x'
   single-quote-first →  strips "s ok" && git push -f "  →  PUSH HIDDEN
   double-quote-first →  strips "it's ok" and 'x'        →  push caught
```

Unbalanced quotes match nothing and are therefore not stripped, so malformed input
still fails closed.

`selftest.sh` asserts both directions — four quoted mentions that must pass, and
five smuggling attempts that must still deny, including the apostrophe case above.

**The general rule.** When a guard pattern spans a region, work out what *else*
lives in that region. And when you relax a guard for usability, write the
smuggling tests *first* — the relaxation is only safe if you can state exactly
what it cannot let through.

---

## 16. The stacking guard failed open in its DEFAULT configuration

**What happened.** Scar #6's check — "main is not a valid base while anything is
unpushed" — reported `✓ nothing unpushed — main is a valid base` on a repo whose
current branch was four commits ahead of `origin/main`. It had presumably been
doing that on every project since it was written.

The line:

```bash
excluded=$(jq -r '[.git.excludeFromStacking[]?] | join("\n")' "$CFG")
... | grep -v -x -e "$MAIN" $(printf -- '-e %s ' $excluded) 2>/dev/null | ...
```

With `excludeFromStacking` **empty** — the default, and what every new install
has — `printf` receives no arguments, emits `-e ` once, and the unquoted command
substitution collapses to a single dangling `-e`. grep exits **2** with `option
requires an argument`, `2>/dev/null` swallows the message, `unpushed` comes back
empty, and empty is indistinguishable from "nothing to report".

**Why it was dangerous.** It is scar #6's guard defeated by scar #8's mechanism,
and it lived in the path that **every** install takes. A non-empty
`excludeFromStacking` accidentally *fixed* it, so the more configured a project
was, the more likely the guard actually worked. Branching from `main` here
silently drops every unpushed commit from your base — including the queue and
the lockfile.

**The part worth internalising, which is not the grep.** The first attempt to
reproduce it *passed*. The check was run by hand in an interactive **zsh**, and
zsh does not word-split an unquoted command substitution — so the dangling `-e`
never formed and grep behaved. The bug only exists under the `#!/usr/bin/env
bash` the script actually runs with.

> **Verify a shell script under its own shebang.** A hand-check in your login
> shell is not a test of a bash script, and it fails in the direction that tells
> you everything is fine.

**The fix.** Filter in the loop, not with grep — there is no option to dangle.
Resolve the exclusion list with `mapfile` into an array so a branch name with a
space cannot re-introduce word-splitting. And check `$REMOTE/$MAIN` resolves
*before* the loop, because without it every comparison is skipped and the empty
result reads exactly like "nothing unpushed".

**The test that had to fail first.** `selftest.sh` had no fixture with a remote,
which is precisely why this survived — the existing preflight assertions all run
against a repo with no remote, where the stacking check cannot say anything. The
new case builds a bare origin, pushes `main`, leaves a branch ahead, and asserts
both directions: an empty exclusion list must **detect**, and a configured one
must still **exclude**. A "fix" that simply deleted the exclusion feature would
pass the first assertion alone.

A first draft of that test asserted only that the branch name appeared in the
output — and it passed against the broken version too, because the unrelated
`on '<branch>'; branch the next batch from main` line also contains it. It now
matches the stacking note and its lead count. Scar #13 in miniature: a test that
is green before and after asserts nothing.

**Where it lives.** `core/preflight.sh` section 4, and the
`── preflight: stacking base ──` block in `selftest.sh`.

---

## 17. A check that cries wolf on the success state destroys the check

**What happened.** Scar #16 fixed the stacking guard's fail-open. The block it
fixed then computed `stack_base` — the branch you are supposed to build on — and
called `bad()` **unconditionally** whenever anything was unpushed. `branch` was
read at the top of the section and consulted only in the *nothing-unpushed*
path. So the single state the guard's own advice exists to produce — standing on
the newest unpushed branch — printed ✗ and exited 1.

brian-chastain batch 1 was dispatched through a red pre-flight whose only
complaint was the base it was correctly using.

**Why it was dangerous.** The skill says *do not start a batch on a red
pre-flight*. A red on the success case makes that rule unfollowable, so the
operator learns to read past the ✗ — and a genuine fault then arrives looking
exactly like the one they have been trained to ignore. The failure is not the
wrong colour; it is that the wrong colour **spends the operator's attention**,
which is the only budget a gate actually draws on.

> A guard that fires on the state it just recommended is not conservative. It is
> teaching people to route around it, and it will be believed exactly once.

**The fix.** Compare `branch` to `stack_base`. Equal → `ok`, with the lead count
and a note not to branch from `main` until it lands. Not equal → the existing
`bad()`, plus a line saying *which* branch you are on and that it is not the
newest — because "you are on the wrong base" is unactionable without that.

**The test that had to fail first.** The existing fixture checked out
`feat/unpushed` and asserted `UNPUSHED WORK EXISTS` **from the stack base**, so
it encoded the bug. Its intent — scar #6, *main is not a valid base while
anything is unpushed* — is tested more faithfully from `main`, so the detection
case now stands on `main`, and new cases cover the base itself. The fixture also
grew a second, older unpushed branch with forced distinct commit times, since
"most recent" is meaningless when two commits share a second.

The exit code is asserted directly, which forced the fixture to become genuinely
clean (harness and queue committed on `main` before branching). It had been
exiting 1 for a dirty tree and a missing queue — conditions unrelated to the rule
under test, and the reason the exit code had never been asserted at all.

**Where it lives.** `core/preflight.sh` section 4, and the
`── preflight: stacking base ──` block in `selftest.sh`.

---

## 18. A field the prompt does not render reaches nobody, silently

**What happened.** `sprint-batch.mjs` renders exactly five item fields into the
builder prompt (`id`, `severity`, `source`, `title`, `detail`) and exactly two
into the verifier prompt (`title`, `detail`). Anything else on an item is
dropped without a word.

On brian-chastain batch 1 the operator re-scoped six items before dispatch —
settled decisions, hazards, explicit do-not-touch lists, freshly re-verified
evidence — and attached the result as a `sharpened` key beside `detail`. It
would have reached no agent on any of the four nodes. It was caught by reading
the prompt builder before launching, which is not a control.

**Why it was dangerous.** The batch would have run. Every builder would have
returned, every lens would have passed, every anchor would have been green, and
the report would have been **indistinguishable** from one where the constraints
were honoured. The operator would then have read "4/4 accepted" as evidence that
work they had carefully scoped came back correct, when no agent had ever seen a
line of it. This is scar #12 with the loss moved upstream: not green-but-wrong,
but green-against-an-item-that-was-never-delivered.

The `newFiles` half of the same contract had a real instance. `plan-batch.mjs`
unions `files` + `newFiles` into `node.files` via `filesOf()` for grouped nodes,
but the **repo-wide** branch was written separately and used `item.files` alone.
`node.files` becomes the builder's *"files this node owns — do not edit anything
else"* list, so a repo-wide item that must CREATE a file handed its builder a
prompt forbidding the file it was told to create. Rarest node type, least likely
to expose it: a repo-wide node already touches files the queue cannot enumerate,
so a builder has no way to tell the omission from the normal case.

> Two code paths that must agree, written at different times, will disagree. The
> one that gets exercised least is the one that will be wrong.

**The fix.** An explicit `ITEM_KEYS` allowlist, checked before any agent is
spawned; an unknown key **throws**, naming `item.field` for every offender.
Throwing rather than warning is the whole point — a warning scrolls past in a run
that then looks successful. The cost of throwing is a launch that dies in seconds
having spent zero tokens. The cost of warning is a plausible batch built against
constraints nobody read. Same trade as scar #2: *unverified* must never be able
to masquerade as *verified*.

The repo-wide branch now uses `filesOf(item)`, and both prompts annotate created
files — `[TO BE CREATED — does not exist yet]` for the builder, and a matching
note for the verifier, since a file appearing only as an addition otherwise looks
like a builder reaching outside its node, and "added a file it did not own" is a
reject a verifier reaches for on sight.

**Where it lives.** `ITEM_KEYS` and `newFilesOf()` in `core/sprint-batch.mjs`,
the repo-wide node in `core/plan-batch.mjs`, and the `── item contract ──` block
in `selftest.sh`.

---

## 19. Five sessions tried to widen the push guard. The guard was right.

**What happened.** `git stash push` is denied. The pattern spans a git
invocation's arguments so it can catch `git -C /path push`, and `stash` sits
inside that same `[^;&|]*`. It reads as a publish.

**Five separate sessions have independently proposed the same carve-out** —
neutralise `git stash push|save` before the match. The argument is good every
time: stash writes a local ref, takes pathspecs, and cannot contact a remote. A
patch was written and it tested clean, allowing all six stash spellings while
still denying `git stash push && git push`.

**It was reverted, and that is the scar.**

**Why.** The guard's entire value is that there is NO region of a command line
where a `push` token is ignored. Every exemption is individually defensible and
collectively fatal: each one enlarges the surface the pattern must reason about,
and the next proposal always arrives with a slightly better argument than the
last. Five sessions converging on the same relaxation is evidence the guard sits
exactly where it hurts — which is where a guard belongs — not evidence it is
misplaced. A rule argued down once is argued down again, and the sixth argument
will be the one that is wrong.

> The cost of a false positive is one command. The cost of a false negative is a
> published repository under a real person's name. These are not comparable, and
> a control that has survived five well-reasoned attacks should not fall to the
> sixth.

**The damage was never the deny.** The hook is `PreToolUse` on Bash, so a deny
aborts the **entire tool call**, not the offending clause. The call was:

```bash
command cp core/preflight.sh "$BACKUP"   # ← never ran
git stash push -q core/preflight.sh      # ← what tripped the guard
```

The backup was silently skipped. A later `git show HEAD:core/preflight.sh >
core/preflight.sh` then wrote the old file over an edit that existed nowhere
else. The stash deny cost one command; **putting it in the same call as the
backup cost the work.**

> Never put a guard-sensitive command in the same call as a step you cannot
> afford to lose. That is a call-granularity rule. It is not a reason to move
> the guard.

**What to do instead** — recorded in `DEFAULT_REASON` so the *next* session reads
it at the moment it is denied, rather than reading the pattern and reaching for
sed:

| need | use |
|---|---|
| stash the tree | `git stash` — bare is already allowed |
| snapshot a file | `command cp <file> /tmp/<scratch>/<file>.bak` |
| read an old revision | `git show HEAD:<path> > /tmp/<scratch>/old` — **never** over the working file |
| compare a commit | `git worktree add --detach` |

**The test that pins it.** `selftest.sh` now asserts `git stash push` **is**
denied, in the same shape as the deliberate `echo git push` over-block, so that
session six's carve-out turns the suite red instead of looking harmless. A second
block asserts the escape hatches (`git stash`, `pop`, `list`, `save`) still pass
— because an over-block is only survivable while a permitted path to the same
local work exists, and a "fix" that hardened those away would be a real
regression.

**Where it lives.** The `DO NOT ADD A CARVE-OUT` block and `DEFAULT_REASON` in
`core/deny-push.sh`, and the stash cases in the `── push guard ──` block of
`selftest.sh`.

---

## 20. An exclusive node left in the graph is a bridge

**What happened.** `plan-batch.mjs` unioned every selected item — including
`scope: "repo-wide"` ones — and only skipped them later, when emitting groups.
The comment above the wave logic already said exclusivity "BYPASSES the
union-find". It did not. The item stayed in the graph as an ordinary vertex.

Reproduced with three items: `P1{p1,x}`, `P2{p2,y}`, and repo-wide `H{x,y}`. P1
and P2 share nothing. Each shares one file with H. Union-find joined all three,
and P1+P2 came out as one serial node.

**Why it mattered more than lost width.** `node.files` is the union of a group's
members and becomes the builder's *"files this node owns — do not edit anything
else"* list. So the bridge did not merely serialise two builders that did not
collide; it handed each of them the *other item's* files, plus the repo-wide
item's, as files they were authorised to edit. The exclusive node then claimed
the same files again a wave later.

**How it hid.** `groupReason()` ended with `.join("; ") || "grouped"`. No shared
file, no ref edge and no lane could explain the grouping, so the plan printed the
bare word `grouped` — which reads exactly like a decision somebody made.

**The fix.** An exclusive item forms no edges at all: not file edges, not ref
edges, not lane edges. Sequencing into its own wave is the entire guarantee. And
`groupReason()` now **throws** instead of falling back to a word: every edge the
partitioner can draw is one of three nameable kinds, so a group it cannot explain
is a group joined by an edge nobody intended.

**Blast radius.** `--auto` only selects `scope: "bounded"` items, so this could
never fire on an auto batch. It fired when an operator named ids explicitly —
which is the documented path for any batch containing a repo-wide item.

**Where it lives.** `isExclusive` and the three edge loops in `core/plan-batch.mjs`;
the `── exclusive bridge ──` block in `selftest.sh`.

**The general shape.** A guarantee stated in a comment is not implemented by the
comment. This one had been described correctly in a published write-up, in the
file header, and in the wave-logic comment — three places agreeing about
behaviour the code never had.

---

## 21. A one-node "diamond" is the original loop with a 4x tax

**What happened.** `docs` and the skill template both carried a *"When NOT to use
this"* section: if you cannot find two items with no edge between them, there is
no graph, and the work belongs in the main loop. Nothing enforced it.
`plan-batch.mjs P1` printed `fan-out width 1` and exited 0, and the resulting run
was reported afterwards in the same shape as a real batch.

Fan-out width 1 is not a cheaper loop. It is the same loop plus a builder
handoff, N verifiers and a reduce step — roughly 4x the tokens for zero
parallelism — and it reads as a graph in the report.

**The fix.** The partitioner computes advisories and prints them under `NOT A
GRAPH`. Two signals, deliberately different in force:

- `--auto` **refuses** (exit 1) to propose a width-1 batch. Auto mode is the
  machine proposing, and it must not propose a non-graph.
- Explicit ids **warn** and proceed. Re-running one rejected node through the
  verify lenses is a legitimate workflow, and refusing it to enforce a style rule
  would break real work.

A node holding many items is flagged separately: that is the density trap working
as designed, but one builder doing eight items serially in one context has no
fan-out inside it, and the operator should choose that knowingly.

**Where it lives.** The `── is this even a graph? ──` block in `core/plan-batch.mjs`;
the `── not a graph ──` block in `selftest.sh`.

---

## 22. The code that decides what a batch MEANS had no test

**What happened.** The reduce step — outcome classification, the fan-in guard,
the claimed-vs-observed anchor comparison — is the part of the system that turns
agent output into a verdict. Scars #2 and #14 are both about it. It was also the
only load-bearing code in the kit with no test behind it. `selftest.sh` said so
in its own header: *"The workflow graph needs a live agent runtime and is NOT
covered here — it is syntax-checked only."*

The blocker was real: a Workflow script has no module loader and no filesystem,
so it cannot be imported.

**The fix.** Fence the reduce between two markers, make it a pure function of
`(nodes, results, lenses, anchorIds, requireAllLenses)`, and have
`core/reduce-fixture.mjs` slice the text out of the shipped file and evaluate it.
The test runs the real code, not a copy, at zero agents and zero tokens.

Then mutate it, because a test that cannot fail proves nothing. `selftest.sh`
patches the shipped reduce four ways — collapsing `unverified` into `rejected`,
disabling the anchor comparison, downgrading a single reject to a majority vote,
removing the fan-in guard — and asserts the fixture catches each. The mutation
helper also asserts the patch *applied*: a `sed` that silently matched nothing
would otherwise look identical to a fixture that missed.

**What this does NOT prove, and it matters.** It shows the reduce classifies bad
input correctly. It does **not** show the lenses detect anything. A verifier that
rubber-stamps everything emits `pass` verdicts that this fixture would happily
classify as `accepted`. The portable kit's headline result — 10 of 10 nodes
accepted first pass, zero rejects — is consistent with three working lenses and
equally consistent with three that are not looking. **A live canary node, with a
deliberately wrong change in it, has not yet been run through this kit.** Until
one produces a reject, the verify half of the diamond is an architecture diagram.

**Where it lives.** The `──REDUCE-BEGIN──`/`──REDUCE-END──` markers in
`core/sprint-batch.mjs`, `core/reduce-fixture.mjs`, and the `── reduce ──` block
in `selftest.sh`.

---

## 23. Three prompts asked for one set difference

**What happened.** *"Do not touch files outside this node's list"* was written
three times, in three places, in prose: the builder contract, the `intent` lens,
and the integrate step. Scar #7 already says a rule in a prompt is a suggestion.

It is also the one question in the `intent` lens that is not a judgement call. It
is a set difference between the paths a branch changed and the paths a node
declared — and paying a language model to re-derive it is slower and less
reliable than `comm`.

**The fix.** `core/scope-gate.sh`, in the `paired-artifact-gate.sh` family. The
builder runs it after committing and reports `scopeGate`; the `anchors` lens
re-runs it and reports `observedScopeGate`; `integrate.sh` runs it against the
merged tree with `--wave`. The reduce compares the two numbers exactly as it
compares anchors, and the `intent` prompt now says explicitly **not** to spend
the lens on file sets.

Two details that are not optional:

- **An exclusive node is exempt, loudly.** A repo-wide node's file list is
  incomplete by construction, so gating it against that list would reject every
  repo-wide node on sight. The script prints `EXEMPT` and why, rather than
  passing silently.
- **A missing gate is not a passing gate.** `scopeGate ?? 0` would be scar #8 all
  over again. An unreported gate makes the node `unverified`, never `accepted`.

**Where it lives.** `core/scope-gate.sh`, the `scopeGate` handling in the reduce,
and the `── scope gate ──` block in `selftest.sh`.

---

## 24. `{{INTEGRATE}}` was a placeholder where the merge should have been

**What happened.** The skill template ended the pipeline with three sentences and
a `{{INTEGRATE}}` comment: *"Merge accepted branches in wave order, then re-run
the anchors on the merged tree — per-node green does not imply merged green."*
The step between "every node passed" and "the thing they add up to passes" was a
human running git from memory.

Four ways that goes wrong, all silent: merging an `unverified` node because the
report is long and it does not look like a rejection; merging wave 1 before wave
0, which is the only reason waves exist; hand-resolving a conflict, producing
code no builder wrote and no verifier will ever see; and declaring victory on
per-node green without ever running the anchors on the merged result.

**The fix.** `core/integrate.sh`. Merges only `accepted`, in wave order, refuses a
report carrying any warning, aborts a conflict instead of resolving it, and runs
the scope gate and the anchors on the merged tree after each wave.

**The bug found while testing it.** The merges land *on* `$BASE`, so after wave 0
the ref no longer points where the batch started. `git diff $BASE...HEAD` then
compares the merged tree against itself, returns nothing, and the scope gate
reports "nothing to check" and exits 0. The happy path printed a green scope line
for a merge it had never examined — a gate that passed because it was asked the
wrong question, indistinguishable in the output from one that passed because the
tree was clean. Fixed by pinning `BASE_SHA` before any merge. The selftest asserts
it by staging an undeclared path in a merged branch, and that case fails if the
pin is reverted.

**Where it lives.** `core/integrate.sh`, and the `── integrate ──` block in
`selftest.sh`.

---

## 25. The file-extension list IS the partitioner

**What happened.** Union-find is the easy half, and it is correct given its
edges. The edges come from a regex scraping file paths out of map prose, so the
extension list in that regex decides what the collision graph can see. The
default list covers application source: `ts`, `go`, `py`, `sql` and friends. It
does not include `md`, `mdx`, `svg`, `png`, `astro` or `vue`.

The header comment said so — *"a path whose extension is missing here is a file
the collision graph cannot see"* — and left it as a note to the reader, in a file
the kit tells you never to edit.

**The case that actually bites is PARTIAL visibility, not zero.** An item with no
scrapeable path scores `unscoped` and gets refused; that failure is loud. An item
touching `docs/guide.md` **and** `src/nav.ts` scrapes the `.ts`, scores
`bounded`, and ships inside a node the planner is confident about — with an
invisible `.md` collision in it.

**The fix, in two halves.**

- The list moves to `extract.fileExtensions` in `harness.config.json`, so a
  content site declares `md`/`mdx`/`svg` without editing `core/`.
- The regex becomes a **linter about itself**. A second pass matches any
  path-shaped token with any extension; anything that resolves to a file tracked
  in git but whose extension is not configured is printed under `INVISIBLE FILE
  TYPES`, naming the extension and the config key to add. The scraper suggests,
  and reports its own blind spots. It does not silently decide what collides.

The noise floor is deliberate — `.com`, `.io`, `.js` in "Node.js", version
numbers and `i.e.` are excluded, and an unresolvable path is not reported at all.
A linter that cries wolf is one people stop reading (scar #17).

**Still open.** The stronger version of this — `files`/`newFiles` as a required,
hand-pinned field on every dispatchable item, with citations demoted to
*evidence* that the pin is true — is the right end state and is not built. Today
the scraped set is still what the graph is made of; it just no longer hides what
it could not see.

**Where it lives.** `DEFAULT_EXTENSIONS`, `fileRe()` and the `ANY_PATH_RE` pass in
`core/lib/extract.mjs`; validation in `core/lib/config.mjs`; the `── file
extensions ──` block in `selftest.sh`.

---

## 26. `\b` cannot match before a leading dot, so `.github/` was invisible

**What happened.** `FILE_RE` opened with `\b`. That is a boundary between a word
character and a non-word character, and a path beginning with a dot-directory —
`.github/workflows/ci.yml` — has no word character before the dot. So the regex
could not start there. It started one character later and captured
`github/workflows/ci.yml`.

Which then resolves to nothing. Suffix matching looks for a tracked path ending
in `/github/workflows/ci.yml`; the real file ends in `/.github/...`.

**Every citation of a dot-directory was silently dropped from the collision
graph.** `.github/`, `.claude/`, `.circleci/`, `.config/` — and CI workflow files
are exactly the kind of file several unrelated items touch at once.

**How it was found.** Not by the kit. A project running the harness for a week
had accumulated a per-repo alias table to work around it:

```js
"github/workflows/ci.yml": ".github/workflows/ci.yml",
"claude/work/extract-queue.mjs": ".claude/work/extract-queue.mjs",
```

with a comment reading *"FILE_RE's leading `\b` eats the dot on a dot-directory"*.
The workaround was correct, was written three times, and was per-repo boilerplate
for a core defect. One of those aliases was load-bearing for seven items.

**The fix.** Replace the leading `\b` with `(?<![\w./-])` — "not already inside a
path". It admits the leading dot, and it still prevents matching at offset 1 of a
path already matched at offset 0.

**The general shape.** This is scar #25's partial-visibility failure reached by a
different route: the item usually cites other files too, so it still scores
`bounded` and the plan still looks confident. A workaround in a downstream repo
is evidence about the upstream tool, and it is only evidence if somebody reads
it.

**Where it lives.** `LEFT_EDGE` in `core/lib/extract.mjs`, and the dot-directory
cases in the `── file extensions ──` block of `selftest.sh`.

---

## 27. An anchor that diffs against a ref must be told WHICH ref

**What happened.** The paired-artifact gate takes a base ref and defaults to
`project.mainBranch`. But the stacking rule means a batch's base is normally the
newest UNPUSHED branch, and there can be several batches between pushes.

Judged against main, every node inherits every earlier node's gate failures, and
it gets worse the deeper the stack.

**Measured, 2026-08-19.** Against main the gate exited 1 on two components that
had been changed by an earlier commit already on the base branch. Against the
node's real base, the same tree exited 0. The builder honestly reported 1, its
verifier honestly observed 0, and the reduce raised an **ANCHOR DISAGREEMENT** —
the loudest signal this harness produces — over nothing but the base argument.
That signal only works if it is rare.

**The second consequence is the serious one.** Once the gate is red from
inherited failures, a node that genuinely skipped its own paired artifact is
INDISTINGUISHABLE: the anchor was already failing and cannot fail louder. The
gate stops discriminating exactly when the stack is deepest, which is when the
most work is unreviewed. That is scar #17 arriving by a different route — a check
that is red for everyone is one people stop reading.

**The fix.** An anchor `cmd` may carry `{base}`, resolved to the node's base
before any agent spawns. An unknown placeholder **throws**: an unresolved
`{basebranch}` would reach the shell as a literal ref name and exit 2, and a 2 in
an anchor column reads as "the check ran and this node is broken", not "the
config has a typo". Shell variables (`${VAR}`) are deliberately left alone.

**This does not make the gate lenient and must not become that.** The inherited
failures are real missing artifacts. They are simply not this node's, and an
anchor that blames a node for its base teaches builders that this anchor's
failures belong to somebody else. The INTEGRATE step asks a different question
and keeps its own base: whether the batch AS A WHOLE shipped its artifacts.

**Where it lives.** `ANCHOR_PLACEHOLDERS` and `resolveAnchorCmd` in
`core/sprint-batch.mjs`; the `── anchor placeholders ──` block in `selftest.sh`.

---

## 28. A conditional anchor had no way to say "did not apply"

**What happened.** `BUILD_SCHEMA` typed every anchor as a bare integer. An anchor
configured `always: false` with `whenTouches` has a THIRD state besides pass and
fail, and that state had no representation — so each agent invented one.

A node whose diff touched only `docker-compose.yml` had its builder report the
conditional web gate as `-1`. Its verifier ran the gate, got a not-applicable
exit 0, and reported `0`. **Both were correct about reality.** The reduce compared
the integers and emitted an ANCHOR DISAGREEMENT on a node where nothing was
wrong.

**Two scars colliding.** The runbook calls the anchor disagreement the most
important line the system can produce, and it only works if it is rare (#14, #17).
This was the second independent cause of the identical false alarm, and it
surfaced on the first batch to run the fix for the first cause (#27).

**The fix.** `type: ['integer', 'null']`. `null` is the JSON-native absence, both
prompts are told to use it, the conditional anchor's rendered line says so
explicitly, and the reduce skips any comparison where either side is null.

**Deliberately NOT fixed by teaching the reduce to tolerate `-1`.** That would
promote one agent's guess to a convention.

**And null had to be made unsafe elsewhere in the same change.** `null` is only
legitimate for a CONDITIONAL anchor. An `always: true` anchor reported as null is
a required check nobody ran, and treating absence as success is scar #8 with a
different name — so the reduce warns on it.

**Where it lives.** `anchorProps` and the `requiredAnchorIds` loop in
`core/sprint-batch.mjs`; four reduce-fixture cases and two mutation checks in
`selftest.sh`.

---

## 29. The harness compelled a file that no file list granted

**What happened.** `pairedArtifacts` COMPELS a counterpart: change a component,
ship its test, or the gate exits non-zero. But `files` is scraped from citations,
and a map entry cites the code it is about — not the test that does not exist
yet.

So a builder handed a component and not its test had exactly two
moves: fail its own anchor, or edit outside its node. It left scope, wrote the
test, and the `intent` lens rejected the node for it.

**Every party behaved correctly and the node was still lost.** The builder obeyed
the gate. The lens obeyed the scope rule. The rule they were both obeying was
self-contradictory.

**Three appearances of one hole**, all found in a single week on one project:
a manifest that could not move without its lockfile, a test directory no item
could cite, and a generated schema (see #30).

**The fix.** The counterpart is DERIVED from the same `pairedArtifacts` rule the
gate enforces, and added to whatever the scraper already found. Not restated —
derived — so the two cannot drift.

**Why this is not an `OVERRIDES` entry, and why that distinction is load-bearing.**
An OVERRIDES entry names an ITEM and asserts a human decision about that item's
scope; it has to be rationed, because it can smuggle scope onto work the map
cannot describe. A companion names a FILE RELATIONSHIP that holds for every item,
forever, and is applied only to files the scraper already found — so an item that
cited nothing still gets nothing.

It makes the graph MORE correct rather than more permissive: two items editing
one component already collided, and now they also collide on the single test file
they would both have rewritten.

**The general lesson, and it took three instances to see it: A SCOPE REJECT IS
NOT AUTOMATICALLY A BUILDER ERROR.** Read which of the builder, the lens, or the
LIST is wrong before re-dispatching. Twice the list was wrong, and re-running the
builder against the same wrong list just reproduces the reject.

**Where it lives.** `pairedArtifactFor` and `withCompanions` in
`core/lib/extract.mjs`, the `COMPANIONS` table in `templates/extract-queue.mjs`,
and the `── companions ──` block in `selftest.sh`.

---

## 30. A generated file is nobody's file

**What happened.** A builder rewrote a route's docstring. The framework publishes
docstrings as the OpenAPI `description`, and the committed `openapi.json` was in
no node's file list — so nothing regenerated it, and the committed schema stopped
matching the app.

**Every anchor was green.** On the node, and on the merged tree, because no anchor
regenerates it. CI does, and CI was the first thing to notice — after the merge,
on the pushed PR.

**A `pairedArtifacts` rule is the WRONG fix here**, and this is the interesting
part. Most edits to a source do not move the generated file, so a rule demanding
`openapi.json` on every one would be noise that gets waived by habit — and a
waiver applied by habit is worse than no rule, because it looks like a decision.

**The fix belongs where the whole batch exists in one tree: the integrate step.**
`regenerate` in config, run by `integrate.sh` after merging a wave and before the
merged-tree anchors, with the resulting diff committed alongside the merge.

**Ordering is part of the fix.** Regeneration runs AFTER the scope gate, because
the scope gate judges what the BUILDERS changed. Run it first and every batch
with a generated artifact reports a scope violation for a file the integrate
script wrote itself.

**Where it lives.** `regenerate` in `core/lib/config.mjs` and the schema, the
regeneration block in `core/integrate.sh`, and two cases in the `── integrate ──`
block of `selftest.sh`.

---

## 31. Lessons that are not code yet

Recorded because a lesson unrecorded is a lesson learned repeatedly, and because
each of these is a hole somebody will otherwise re-derive at their own cost.

**A refusal decided by evidence belongs in the MAP, as a field.** An item was
refused before dispatch, with the reason written into a batch record — and the
extractor, which walks the open-work sections and has never read that record,
put it straight back in the queue. Its builder spent a full context re-deriving
the same conclusion and returned blocked. Third instance of the shape in one
week. Putting the hold in the extractor's `OVERRIDES` table works and is a
stopgap: OVERRIDES is a code file, and a refusal decided by evidence belongs
beside the evidence. The fix is a declared field the extractor maps to
`scope: "held"` — not prose it has to parse, because making an English sentence
load-bearing is the thing this whole design avoids.

**A file list derived from where a field is DECLARED misses where it is BUILT.**
Twice in one morning, in lists written that morning. A schema module was named;
the model is constructed field by field somewhere else, so a required field was
literally unconstructable inside the declared list. One instance was caught by
reading the partition before dispatch and cost one map edit. The other was not,
and the builder correctly CUT THE FEATURE rather than touch an undeclared file —
and the reduce reported that node as `not-built`, which reads like a failure and
is not one. **The check, cheap enough to do every time: for any item adding a
field to a model, grep for where that model is CONSTRUCTED, not only where it is
declared.**

**Closing an item is two edits, and only one of them gets made.** Three items had
complete closure records AND were still sitting in the open-work section, so the
extractor put all three back in the queue as open. The next batch would have
dispatched builders at work already on main — and the likely outcome is not a
wasted node but a CONFUSING one: an agent given an item whose fix is already
present reports it done without changing anything, which is indistinguishable
from a node that silently did nothing. The extractor is the one place that reads
both sections and could refuse to write. Until it does, integrate checks by hand.

**A rejected node may still be right, and neither of ours was re-judged.** Twice a
node was rejected on scope by one lens while the other two passed, and both times
the FILE LIST was what was wrong. Correcting a list and merging on the standing
verdicts is not the same as a fresh lens judging the corrected node. What is
trusted in those cases is anchors and a watched failure, not a second opinion.
Stated here rather than left to be inferred.

---

## 32. A lane serialised a resource it never granted

**What happened.** `lanes[]` exists so two agents cannot both mint the next
migration number — a resource no merge can reconcile. It worked: the item was
folded into a single serial node labelled `migration lane`. But the node's
declared `files` contained no `migrations/` path, and `scope-gate.sh` is a set
difference against `files ∪ newFiles`.

So the builder had nowhere legal to write the SQL. Its two moves were to commit a
scope violation, or to build the UI half against a column that does not exist —
a cell that renders as a confidently empty date. It did neither: it refused the
item, reported the missing path, and shipped the other two items in its node.
The reduce then marked the node `not-built`.

**The lane's two halves were built years apart in practice.** Serialisation is
enforced at partition time and was exercised constantly. The GRANT was never
exercised at all, because on the source project every migration predated the
harness — ten of them, all hand-written. The first migration item ever
dispatched found the hole immediately.

**Why nothing caught it earlier.** A lane item looks *more* protected than an
ordinary one, not less: it gets its own node, an explicit `reason` string naming
the lane, and a scope gate. Every one of those fired correctly. The thing that
did not exist was never mentioned by anything that did.

**This is scar #29 in a second costume.** There, `pairedArtifacts` COMPELLED a
file no list GRANTED. Here a lane SERIALISES a resource no list GRANTS. The
shape is identical — *the harness demands an artifact, and the file list is
derived from citations that cannot mention it* — and #29's closing lesson
applies unchanged: **a scope reject is not automatically a builder error.** Read
whether the builder, the lens, or the LIST is wrong.

**The fix, in the same spirit as #29's companions.** A lane that names a resource
should be able to say what path that resource occupies, so the grant is DERIVED
from the same declaration that causes the serialisation rather than restated per
item:

```jsonc
"lanes": [{
    "id": "migration",
    "itemFlag": "needsNewMigration",
    "grantPattern": "supabase/migrations/{next}_{slug}.sql"
}]
```

Until that exists, the per-item escape is an `OVERRIDES.newFiles` entry pinning
the exact filename — the gate is an exact string match, and a lane guarantees at
most one such item per batch, so the number is deterministic.

**The cheap interim guard, and it is worth more than it costs.** `plan-batch.mjs`
already REFUSES `unscoped` items. It should equally refuse — or at minimum
advise on — a node in a resource lane whose file set contains nothing matching
that lane. That converts a silently unbuildable node, discovered after a builder
and three verifiers have run, into a planning-time error costing zero agents.

**Where it lives.** Not in `core/` yet. The interim grant is an
`OVERRIDES.newFiles` entry in the consuming project's `extract-queue.mjs`.

---

## 33. The generated-file fix can generate the wrong file

**What happened.** Scar #30 added `regenerate` to config, run by `integrate.sh`
after a wave merges and before the merged-tree anchors. It is the right
mechanism. Applying it to a *migration*-generated artifact needs one more
condition that #30 did not need, and getting it wrong is silent.

The source project's type generator reads a **running Postgres** and emits the
schema as it currently stands. At integrate time the merged tree contains the new
migration, but the database still does not — migrations are applied later, by the
deploy step. So `regenerate` would faithfully write the types of the OLD schema,
commit them beside a migration that adds a column, and report success.

**That is scar #30's exact failure — a committed artifact that no longer matches
the app — reproduced by scar #30's own fix.** It would also survive the guard
that fix installed, because the merged-tree anchors run after regeneration and a
stale-but-valid types file type-checks perfectly.

**Worse, the generator's own safety check passes.** It refuses to overwrite if
the output is missing known tables — a guard against connecting to an empty
database. Every one of those tables exists in the old schema, so the check waves
through a file that is wrong in exactly the way the check cannot see.

**The condition.** A `regenerate` entry whose source of truth is the DATABASE,
not the source tree, is only correct if the command APPLIES PENDING MIGRATIONS
FIRST — and it must do that against a scratch or ephemeral database, never a
shared one. On a shared mirror, applying a migration during integrate would leak
one node's schema change into every other worktree reading that database, and a
subsequently rejected node would leave the mirror carrying a migration no branch
ever shipped.

**The general rule.** For each `regenerate` entry, ask what it READS. If it reads
the source tree, merging is enough and #30 covers it. If it reads a live service,
merging is NOT enough: the service has to be brought to the merged tree's state
first, in isolation, or the entry must not exist and the regeneration is a
post-deploy step recorded as owed work.

**And say so out loud when it is deferred**, because nothing goes red either way:
if the surface reading the new column is hand-typed or cast, the type-checker
passes with a stale generated file, so the omission has no symptom until someone
trusts the file. A stale generated file is worse than none — it type-checks
confidently against a schema that no longer exists.

**Where it lives.** Not in `core/` yet. Today it is a warning in the consuming
project's item prose and a deliberately withheld grant.

---

## 34. A node id contains spaces, so serial nodes never merged

**What happened.** `integrate.sh` picked the nodes to merge with

```bash
for nodeId in $(printf '%s\n' "$IN_WAVE"); do
    printf '%s\n' "$ACCEPTED" | grep -qxF "$nodeId" || continue
```

A node's id is its item list joined with `" + "` whenever the partitioner folds
colliding items into a collision group. So the id **contains spaces**, word
splitting turned one id into five tokens — `cb:a`, `+`, `cb:b`, `+`, `cb:c` — and
none of them matched the accepted list. The node was skipped.

**It failed silently, and that is the serious part.** No error, no warning. The run
ended `dry run: 0 node(s) would merge across 1 wave(s)`, which reads as
*nothing to do* rather than as a failure. It was caught only because an accepted
node was known to exist and the count was questioned.

**What it affected: exactly the nodes that matter.** A batch whose items are all
independent has single-item ids with no spaces, and merged perfectly. Only SERIAL
nodes broke — which is to say, precisely the collision groups the partitioner
exists to build. The easy case worked, the load-bearing case did not, and that
asymmetry is why it survived so long.

**The fix.**

```bash
while IFS= read -r nodeId; do … done <<< "$IN_WAVE"
```

**A herestring, not a pipe**, and that part is not cosmetic: `printf … | while`
runs the body in a SUBSHELL, so the `WAVE_MERGED` / `MERGED` counters would be
discarded when the loop ends — replacing a silent skip with a silent miscount.

**The detail worth sitting with: the correct idiom was already in the same file,
70 lines above**, listing the not-accepted nodes. The pattern was known and one
loop was missed. A convention that lives only in the author's head gets applied
unevenly; the same is true of #4's herestring rule, which this is a second
instance of.

**The general lesson. Any identifier assembled by JOINING other identifiers stops
being shell-safe**, and nothing about the code at the joining site says so. If an
id can be composite, it must be read line-wise from the moment it is created —
`for … in $(…)` over ids is the bug, not the escaping.

**Where it lives.** The `while IFS= read -r nodeId` loop in `core/integrate.sh`.

---

## 35. A test anchor that answers a question about CPU load

**What happened.** A wave fanned out 8 nodes — 32 agents — on one 12-core box.
Each builder and each `anchors` verifier ran the full jsdom suite. Five of the
eight nodes observed `test=1`; three observed `test=0`. From the same base
commit. The reduce did exactly what it should and raised an ANCHOR DISAGREEMENT
on the one node where the builder and its verifier landed on different sides
(builder 0, verifier 1), and `integrate.sh` then refused to merge the batch.

**Why it was dangerous.** Nothing was broken. Re-measured on a quiet machine, the
base and the disputed commit were both 972/972, exit 0, and the merged tree was
green on all seven anchors. Reproduced deliberately afterwards: eight concurrent
`npm test` runs against that same green tree came back **8/8 red, 28–40 failures
each, and all 200 failures were `Test timed out in 5000ms`. Not one assertion
failed.** Most runners size their worker pool to the core count, so N concurrent
runs oversubscribe the box N-fold before a single test executes.

The wasted triage is the small half. The real damage is that the anchor was
answering a question about machine load while presenting as a question about the
code, so a builder and its verifier could honestly disagree at random. That
manufactures the loudest and rarest signal this system has, and a signal that
fires at random stops being read. Worse is the habit it teaches: once an anchor
is known to go red under load, its reds get explained away — which is how a check
dies (see #17).

**The fix, and why it is structural.** `serialize: true` on an anchor, which
wraps it in `core/serialize.sh` — a host-wide, name-keyed lock, `flock` where it
exists and an atomic-`mkdir` spinlock with a staleness check where it does not.
Only one copy of that anchor runs on the machine at a time, no matter how wide
the fan-out. It costs wall-clock and buys a number two agents can both stand
behind, which for an anchor is the right trade every time.

Not fixed by raising the timeout: that hides a real hang behind a slower one, and
leaves the exit code load-dependent. Not fixed by capping workers either — with
2N runs the arithmetic still oversubscribes, just later.

**Where it lives.** `core/serialize.sh`; `serialised()` in `core/sprint-batch.mjs`;
`serialize` in the anchor schema and in `workflowSlice()`.

---

## 36. Every sibling node shares one scratchpad directory

**What happened.** In the same wave, a verifier redirected its anchor output to
the session scratchpad — `npm test > scratchpad/test.log` — and so did its
siblings, to the same path. Its log was overwritten by another node's run, and it
read back five failures belonging to a different branch.

**Why it was dangerous.** It caught the swap only because the runner's own header
line happened to name the other worktree in the captured output. Nothing else
would have revealed it. Had the file been one line shorter, the verifier would
have rejected a node whose diff was fine, citing failures from code it had never
seen — and the evidence in the verdict would have looked specific and credible.

The general shape: agents are handed an isolated *worktree* and told they are
isolated, but the scratchpad they are also handed is SHARED across the whole
wave. Isolation that holds for one resource and not another is worse than no
isolation, because the contract is what agents reason from.

**The fix.** Both agent contracts now forbid writing an anchor log to any path a
sibling could also write: keep it inside your own worktree, or put the node id in
the filename. Stated with the incident attached, because "use a unique filename"
without the story reads as fussiness and gets dropped under pressure.

**Where it lives.** `templates/sprint-builder.md`, `templates/sprint-verifier.md`.
