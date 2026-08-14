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
