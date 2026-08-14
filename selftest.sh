#!/usr/bin/env bash
#
# Self-test: build a throwaway git repo, install the harness into it, and
# exercise every piece of core/ that can run without dispatching agents.
#
#     ./selftest.sh
#
# Covers: config loading + refusals, the partitioner (collisions, ref edges,
# lanes, exclusive waves, refusals), the push guard, and the paired-artifact
# gate including the waiver path.
#
# The workflow graph (core/sprint-batch.mjs) needs a live agent runtime and is
# NOT covered here — it is syntax-checked only.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
# expect <desc> <expected-exit> <cmd...>
expect() {
    local desc="$1" want="$2"; shift 2
    local out; out=$("$@" 2>&1); local got=$?
    if [ "$got" -eq "$want" ]; then ok "$desc"; else
        no "$desc (wanted exit $want, got $got)"
        printf '%s\n' "$out" | sed 's/^/        /' | head -12
    fi
}

echo "sprint-harness self-test"
echo "════════════════════════"

# ── fixture repo ─────────────────────────────────────────────────────────────
REPO="$TMP/fixture"
mkdir -p "$REPO"/{src,src/__tests__,migrations}
cd "$REPO" || exit 1
git init -q .
git config user.email t@t.t; git config user.name t

for f in src/alpha.tsx src/beta.tsx src/gamma.tsx src/shared.ts; do echo "// $f" > "$f"; done
echo "-- up" > migrations/0001_init.up.sql
echo "-- down" > migrations/0001_init.down.sql
git add -A && git commit -qm "init"

echo
echo "── install ──"
"$HERE/install.sh" "$REPO" --stack node-web >/dev/null 2>&1 \
    && ok "install.sh completes" || no "install.sh completes"
[ -x "$REPO/.claude/hooks/deny-push.sh" ] && ok "push guard placed" || no "push guard placed"
[ -f "$REPO/.claude/harness-core/plan-batch.mjs" ] && ok "core placed" || no "core placed"
jq -e '.hooks.PreToolUse[0].hooks[0].statusMessage == "push guard"' \
    "$REPO/.claude/settings.json" >/dev/null 2>&1 \
    && ok "settings.json wired" || no "settings.json wired"

# install.sh must not clobber work you have already done
echo '{"MARKER":1}' > "$REPO/.claude/harness.config.json"
"$HERE/install.sh" "$REPO" >/dev/null 2>&1
grep -q MARKER "$REPO/.claude/harness.config.json" \
    && ok "re-install does NOT clobber a filled-in config" \
    || no "re-install does NOT clobber a filled-in config"

# A gitignored .claude/ means a builder's worktree has NO harness — an anchor
# invoking a script under it does not fail, the file is not there. Silent, and
# common, so the installer must catch it.
IGN="$TMP/ignored"; mkdir -p "$IGN/src"
git init -q "$IGN"; git -C "$IGN" config user.email t@t.t; git -C "$IGN" config user.name t
echo x > "$IGN/src/a.ts"; echo ".claude/" > "$IGN/.gitignore"
git -C "$IGN" add -A && git -C "$IGN" commit -qm init
# ⚠ CAPTURE, DO NOT PIPE INTO grep -q. `set -o pipefail` is on (line 26), grep -q
# exits the instant it matches, that SIGPIPEs the writer with 141, and pipefail
# reports the pipeline as FAILED even though grep MATCHED. This is scar #4 — the
# same bug the paired-artifact gate was fixed for — and it reproduced here, in the
# test harness, while writing the test for a different bug. Capture to a variable
# and match with a herestring: no second process, no pipe.
ign_out=$("$HERE/install.sh" "$IGN" 2>&1)
grep -q "GITIGNORED" <<< "$ign_out" \
    && ok "installer warns when .claude/ is gitignored" \
    || no "installer warns when .claude/ is gitignored"

clean_out=$("$HERE/install.sh" "$REPO" 2>&1)
grep -q "GITIGNORED" <<< "$clean_out" \
    && no "installer stays quiet when .claude/ is trackable" \
    || ok "installer stays quiet when .claude/ is trackable"

# ── config ───────────────────────────────────────────────────────────────────
echo
echo "── config ──"
cat > "$REPO/.claude/harness.config.json" <<'JSON'
{
    "project": { "name": "fixture", "mainBranch": "main" },
    "queue":   { "path": ".claude/work/QUEUE.json" },
    "anchors": [ { "id": "test", "cmd": "true", "cwd": "." } ],
    "lanes":   [ { "id": "migration", "itemFlag": "needsNewMigration",
                   "why": "forward-only numbering" } ],
    "pairedArtifacts": [ {
        "id": "unit", "srcDir": "src", "srcExt": ".tsx",
        "pairPath": "src/__tests__/{name}.test.tsx",
        "excludeDirs": ["src/__tests__"],
        "waiverTrailer": "no-test({name})"
    } ],
    "git": { "stackBranches": false }
}
JSON
expect "loads a valid config" 0 \
    node -e 'import("'"$REPO"'/.claude/harness-core/lib/config.mjs").then(m=>m.loadConfig())'

# An anchor-less config must be REFUSED, not defaulted. With zero anchors the
# verify step degrades to models agreeing with each other.
cat > "$TMP/noanchors.json" <<'JSON'
{ "project": { "name": "x", "mainBranch": "main" },
  "queue": { "path": "q.json" }, "anchors": [] }
JSON
out=$(SPRINT_HARNESS_CONFIG="$TMP/noanchors.json" node -e \
    'import("'"$REPO"'/.claude/harness-core/lib/config.mjs").then(m=>m.loadConfig())' 2>&1)
grep -q "at least one anchor" <<< "$out" \
    && ok "refuses a config with zero anchors" \
    || no "refuses a config with zero anchors"

out=$(node -e '
    import("'"$REPO"'/.claude/harness-core/lib/config.mjs").then(m => {
        const c = m.loadConfig();
        c.verify.lenses = ["a","a"];
        try { m.workflowSlice(c); } catch (e) {}
        console.log(JSON.stringify(m.workflowSlice(c).anchors.map(a=>a.id)));
    })' 2>&1)
grep -q '\["test"\]' <<< "$out" \
    && ok "workflowSlice carries anchors to the graph" \
    || no "workflowSlice carries anchors to the graph"

# ── partitioner ──────────────────────────────────────────────────────────────
echo
echo "── partitioner ──"
mkdir -p "$REPO/.claude/work"
cat > "$REPO/.claude/work/QUEUE.json" <<'JSON'
{
  "items": [
    { "id": "a", "title": "alpha only",  "status": "open", "scope": "bounded",
      "files": ["src/alpha.tsx"], "newFiles": [] },
    { "id": "b", "title": "beta only",   "status": "open", "scope": "bounded",
      "files": ["src/beta.tsx"],  "newFiles": [] },
    { "id": "c", "title": "also alpha",  "status": "open", "scope": "bounded",
      "files": ["src/alpha.tsx"], "newFiles": [] },
    { "id": "d", "title": "same job as b", "status": "open", "scope": "bounded",
      "files": ["src/gamma.tsx"], "newFiles": [], "mapRef": "b" },
    { "id": "e", "title": "new migration", "status": "open", "scope": "bounded",
      "files": [], "newFiles": ["migrations/0002.up.sql"], "needsNewMigration": true },
    { "id": "f", "title": "other migration", "status": "open", "scope": "bounded",
      "files": [], "newFiles": ["migrations/0003.up.sql"], "needsNewMigration": true },
    { "id": "g", "title": "rename a convention", "status": "open", "scope": "repo-wide",
      "files": ["src/shared.ts"], "newFiles": [] },
    { "id": "h", "title": "no files at all", "status": "open", "scope": "unscoped",
      "files": [], "newFiles": [] },
    { "id": "i", "title": "lives in a SaaS console", "status": "open", "scope": "external",
      "files": ["src/beta.tsx"], "newFiles": [], "dispatchable": false }
  ]
}
JSON

PB="$REPO/.claude/harness-core/plan-batch.mjs"
P=$(node "$PB" a b c d e f g h i --json 2>/dev/null)

check() { # <desc> <jq-filter> <expected>
    local got; got=$(jq -r "$2" <<< "$P" 2>/dev/null)
    [ "$got" = "$3" ] && ok "$1" || no "$1 (got: $got, want: $3)"
}

check "shared file merges a+c into one serial node" \
    '[.nodes[]|select(.nodeId|test("^a \\+ c$|^c \\+ a$"))]|length' 1
check "that node is marked serial" \
    '[.nodes[]|select(.items|length>1)][0].serial' true
check "declared cross-ref merges b+d despite disjoint files" \
    '[.nodes[]|select((.items|map(.id)|sort)==["b","d"])]|length' 1
check "both migrations collapse into one lane node" \
    '[.nodes[]|select(.lane=="migration")]|length' 1
check "the lane node holds both items" \
    '[.nodes[]|select(.lane=="migration")][0].items|length' 2
check "repo-wide item is exclusive" \
    '[.nodes[]|select(.nodeId=="g")][0].exclusive' true
check "repo-wide item gets its own wave (not wave 0)" \
    '[.nodes[]|select(.nodeId=="g")][0].wave' 1
check "unscoped and external are both refused" \
    '.refused|length' 2
check "refusals carry a reason" \
    '[.refused[]|select(.why|length>0)]|length' 2
check "the plan carries the harness slice for the graph" \
    '.harness.anchors[0].id' test
check "cross-wave file overlap is reported" \
    '[.crossWaveFiles[]|select(.file=="src/shared.ts")]|length' 0

# A node whose file is ALSO claimed by the exclusive node must be sequenced.
check "wave 0 holds every non-exclusive node" \
    '[.nodes[]|select(.exclusive==false)|select(.wave!=0)]|length' 0

expect "refuses an unknown item id" 1 node "$PB" nope
expect "refuses when every selection is refused" 1 node "$PB" h i
expect "human-readable output renders" 0 node "$PB" a b

# ── push guard ───────────────────────────────────────────────────────────────
echo
echo "── push guard ──"
G="$REPO/.claude/hooks/deny-push.sh"
denies() { jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }

for cmd in \
    "git push" \
    "git push --force" \
    "git push -f origin main" \
    "git -C /elsewhere push" \
    "cd src && git push origin main" \
    "git status; git push" \
    "git push --force-with-lease" \
    "gh pr create --fill" \
    "gh pr merge 3 --squash" \
    "gh repo sync"
do
    if printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
        | "$G" | denies; then ok "denies: $cmd"; else no "denies: $cmd"; fi
done

# A DELIBERATE over-block, asserted so nobody "fixes" it later. `echo git push`
# is denied because the pattern cannot distinguish an UNQUOTED literal from an
# invocation without parsing shell, and this guard fails closed by design.
# Over-blocking a harmless echo costs nothing; under-blocking one chained push
# costs everything.
if printf '{"tool_input":{"command":"echo git push"}}' | "$G" | denies; then
    ok "over-blocks unquoted 'echo git push' (deliberate — fails closed)"
else
    no "over-blocks unquoted 'echo git push' (deliberate — fails closed)"
fi

# `git stash push` IS DENIED, AND THAT IS PINNED HERE ON PURPOSE.
#
# Five separate sessions have proposed neutralising `git stash push` before the
# match. It is individually defensible every time — stash takes pathspecs, not a
# remote — and it is still refused, because the guard's whole value is that no
# region of a command line gets a `push` token ignored. These assertions exist so
# that session six's carve-out turns the suite red instead of looking harmless.
#
# The workaround belongs in the operator's hands, not in the pattern: `git stash`
# bare is already allowed, `command cp` snapshots a file with no git verb at all,
# and `git show HEAD:path > /tmp/...` reads an old revision. See DEFAULT_REASON.
for cmd in \
    "git stash push" \
    "git stash push -q core/preflight.sh" \
    'git stash push -m "wip"' \
    "git -C /elsewhere stash push"
do
    if printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
        | "$G" | denies; then ok "over-blocks '$cmd' (deliberate — do not carve out)"
    else no "over-blocks '$cmd' (deliberate — do not carve out)"; fi
done
# The spellings that do NOT contain the token are unaffected, which is what makes
# the deny survivable: there is always a permitted way to do the same local work.
for cmd in \
    "git stash" \
    "git stash pop" \
    "git stash list" \
    "git stash save wip"
do
    if printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
        | "$G" | denies; then no "still allows the escape hatch: $cmd"
    else ok "still allows the escape hatch: $cmd"; fi
done

# INERT QUOTED REGIONS. The pattern spans a git invocation's arguments by design
# (`git -C /path push`), so before the fix it also spanned a quoted argument and
# denied `git commit -m "...push..."`. It fired on this repo's own history.
# These assert the strip works AND that it cannot be used to smuggle a push.
for cmd in \
    'git commit -m "docs: fix the push guard"' \
    "git commit -m 'fix: do not push on error'" \
    'git commit -m "it'"'"'s fine, no push here"' \
    'git log --grep="push"'
do
    if printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
        | "$G" | denies; then no "allows quoted mention: $cmd"
    else ok "allows quoted mention: $cmd"; fi
done

# ...and the smuggling attempts the strip must NOT let through.
for cmd in \
    'git commit -m "wip" && git push' \
    "git commit -m 'wip' && git push -f" \
    'echo "$(git push)"' \
    'git commit -m "it'"'"'s ok" && git push -f '"'"'x'"'"'' \
    'git commit -m "unterminated && git push'
do
    if printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
        | "$G" | denies; then ok "still denies: $cmd"
    else no "still denies: $cmd"; fi
done

for cmd in \
    "git status" \
    "git commit -m 'push the button'" \
    "git status && echo push" \
    "git log --oneline"
do
    if printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')" \
        | "$G" | denies; then no "allows: $cmd"; else ok "allows: $cmd"; fi
done

# ── paired-artifact gate ─────────────────────────────────────────────────────
echo
echo "── paired-artifact gate ──"
GATE="$REPO/.claude/work/paired-artifact-gate.sh"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm "harness" >/dev/null 2>&1
git -C "$REPO" branch -M main

git -C "$REPO" checkout -qb work
echo "// changed" >> "$REPO/src/alpha.tsx"
git -C "$REPO" commit -qam "feat: change alpha, no test"
expect "fails when a source file changed with no counterpart" 1 "$GATE" main

echo "test" > "$REPO/src/__tests__/alpha.test.tsx"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "test: add alpha test"
expect "passes once the counterpart is present" 0 "$GATE" main

# The waiver path. This is the case that SIGPIPE + pipefail silently broke:
# grep -q matched, was killed by SIGPIPE, and pipefail reported the whole
# pipeline as failed — so a valid waiver read as a violation. Herestrings fixed
# it, and this assertion is what keeps it fixed.
git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qb waived
echo "// class only" >> "$REPO/src/beta.tsx"
git -C "$REPO" commit -qam "style(beta): class swap

no-test(beta): class-only change, no behaviour to assert"
expect "honours a named waiver trailer (SIGPIPE regression guard)" 0 "$GATE" main

git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qb blankwaiver
echo "// x" >> "$REPO/src/gamma.tsx"
git -C "$REPO" commit -qam "fix(gamma): x

no-test(gamma):"
expect "rejects a waiver with no reason" 1 "$GATE" main

git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qb otherfile
echo "// not a component" >> "$REPO/src/shared.ts"
git -C "$REPO" commit -qam "chore: touch a non-matching file"
expect "ignores files outside the rule's srcDir/srcExt" 0 "$GATE" main

# ── preflight: the stacking base ─────────────────────────────────────────────
#
# REGRESSION TEST for a fail-open found 2026-08-14. The unpushed-branch check
# built its grep exclusion as `$(printf -- '-e %s ' $excluded)`, which with an
# EMPTY excludeFromStacking — the DEFAULT — left a dangling `-e`. grep exited 2
# with "option requires an argument", `2>/dev/null` hid the message, and
# pre-flight printed "nothing unpushed — main is a valid base" while unpushed
# branches sat right there. That is scar #6's guard defeated by scar #8's
# mechanism, in the default configuration.
#
# It needs a REAL remote to exercise, which is exactly why the main fixture
# (no remote) never caught it. Both directions are asserted: the default must
# DETECT, and a configured exclusion must still EXCLUDE — a "fix" that simply
# dropped the exclusion feature would pass the first assertion on its own.
echo
echo "── preflight: stacking base ──"
STK="$TMP/stacked"; ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"
mkdir -p "$STK/src"; git init -q -b main "$STK"
git -C "$STK" config user.email t@t.t; git -C "$STK" config user.name t
echo x > "$STK/src/a.ts"; git -C "$STK" add -A; git -C "$STK" commit -qm init
git -C "$STK" remote add origin "$ORIGIN"
# Install and seed the queue ON MAIN, then push, so that every branch below
# inherits a CLEAN tree with the harness and a queue present. Without this the
# fixture is permanently dirty (untracked .claude/) and queue-less, so pre-flight
# exits 1 for reasons that have nothing to do with the stacking rule — which
# makes the exit code untestable, and the exit code is the whole point here.
"$HERE/install.sh" "$STK" --stack node-web >/dev/null 2>&1
mkdir -p "$STK/.claude/work"
echo '{ "items": [] }' > "$STK/.claude/work/QUEUE.json"
git -C "$STK" add -A; git -C "$STK" commit -qm "harness + queue"
git -C "$STK" push -q -u origin main
# TWO unpushed branches with FORCED distinct commit times, because the stack
# base is "the most recent unpushed branch" and a same-second tie would make
# which one wins depend on sort stability rather than on the rule.
git -C "$STK" checkout -q -b feat/older
echo w > "$STK/src/c.ts"; git -C "$STK" add -A
GIT_AUTHOR_DATE="2026-08-14T10:00:00" GIT_COMMITTER_DATE="2026-08-14T10:00:00" \
    git -C "$STK" commit -qm "older, not pushed"
git -C "$STK" checkout -q main
git -C "$STK" checkout -q -b feat/unpushed
echo y > "$STK/src/b.ts"; git -C "$STK" add -A
GIT_AUTHOR_DATE="2026-08-14T11:00:00" GIT_COMMITTER_DATE="2026-08-14T11:00:00" \
    git -C "$STK" commit -qm "not pushed"

# excludeFromStacking absent ENTIRELY — the shape the bug lived in.
cat > "$TMP/stk-default.json" <<'JSON'
{ "project": { "name": "stk", "mainBranch": "main", "remote": "origin" },
  "queue": { "path": ".claude/work/QUEUE.json" },
  "anchors": [ { "id": "t", "cmd": "true" } ] }
JSON

# FROM main — the state the guard exists to catch. This assertion used to run
# from feat/unpushed, i.e. from the stacking base itself, which is the one
# position where "do NOT branch from main" is advice the operator has ALREADY
# taken. It passed only because the check was red in that case too. Running it
# from main is strictly more faithful to scar #6: main is not a valid base while
# anything is unpushed.
git -C "$STK" checkout -q main
stk_out=$(cd "$STK" && SPRINT_HARNESS_CONFIG="$TMP/stk-default.json" \
    ./.claude/harness-core/preflight.sh 2>&1)
grep -q "UNPUSHED WORK EXISTS" <<< "$stk_out" \
    && ok "preflight DETECTS unpushed branches when standing on main" \
    || no "preflight DETECTS unpushed branches when standing on main"
# Match the STACKING note specifically, not a bare branch name. A plain
# "feat/unpushed" grep passes against the broken version too, because the
# "on '<branch>'; branch the next batch from main" line also contains it —
# an assertion that is green before and after asserts nothing.
grep -q "feat/unpushed  (+1 ahead of origin/main)" <<< "$stk_out" \
    && ok "preflight names the branch to stack on, with its lead count" \
    || no "preflight names the branch to stack on, with its lead count"

# ── being ON the stack base is the SUCCESS state ─────────────────────────────
# Regression test for a cry-wolf found 2026-08-14 on brian-chastain batch 1.
# The block computed stack_base and then called bad() unconditionally, so the
# exact state its own advice tells you to reach — standing on the newest
# unpushed branch — exited 1. The skill says "do not start a batch on a red
# pre-flight", so a red on the success case teaches the operator to run batches
# through a failing gate, and a real fault becomes indistinguishable from the
# one they have learned to ignore.
#
# Asserted in BOTH directions, because a "fix" that simply stopped failing on
# unpushed work would pass the green half alone — and would reinstate scar #6.
git -C "$STK" checkout -q feat/unpushed
stk_on_base=$(cd "$STK" && SPRINT_HARNESS_CONFIG="$TMP/stk-default.json" \
    ./.claude/harness-core/preflight.sh 2>&1)
stk_on_base_rc=$?
grep -q "on the stacking base 'feat/unpushed'" <<< "$stk_on_base" \
    && ok "preflight is GREEN when already on the stacking base" \
    || no "preflight is GREEN when already on the stacking base"
! grep -q "UNPUSHED WORK EXISTS" <<< "$stk_on_base" \
    && ok "preflight does not cry wolf on the base it just recommended" \
    || no "preflight does not cry wolf on the base it just recommended"
[ "$stk_on_base_rc" -eq 0 ] \
    && ok "preflight EXITS 0 when standing on the stacking base" \
    || no "preflight EXITS 0 when standing on the stacking base (got $stk_on_base_rc)"

# An OLDER unpushed branch is still the wrong base: building there means the
# newest unpushed work is not in your tree, which is scar #6 by another route.
git -C "$STK" checkout -q feat/older
stk_old=$(cd "$STK" && SPRINT_HARNESS_CONFIG="$TMP/stk-default.json" \
    ./.claude/harness-core/preflight.sh 2>&1)
grep -q "UNPUSHED WORK EXISTS" <<< "$stk_old" \
    && ok "preflight still RED on an unpushed branch that is not the newest" \
    || no "preflight still RED on an unpushed branch that is not the newest"
grep -q "not the newest unpushed branch" <<< "$stk_old" \
    && ok "preflight says WHY the current branch is the wrong base" \
    || no "preflight says WHY the current branch is the wrong base"
git -C "$STK" checkout -q feat/unpushed

# A branch that is ahead BY DESIGN must still be excluded. BOTH unpushed
# branches are listed: the assertion is "nothing unpushed remains", so leaving
# feat/older out would fail for the right reason and read like a broken
# exclusion feature.
cat > "$TMP/stk-excluded.json" <<'JSON'
{ "project": { "name": "stk", "mainBranch": "main", "remote": "origin" },
  "queue": { "path": ".claude/work/QUEUE.json" },
  "anchors": [ { "id": "t", "cmd": "true" } ],
  "git": { "excludeFromStacking": ["feat/unpushed", "feat/older"] } }
JSON
stk_out2=$(cd "$STK" && SPRINT_HARNESS_CONFIG="$TMP/stk-excluded.json" \
    ./.claude/harness-core/preflight.sh 2>&1)
grep -q "nothing unpushed" <<< "$stk_out2" \
    && ok "excludeFromStacking still excludes" \
    || no "excludeFromStacking still excludes"

# Fail CLOSED when the remote ref is missing: without it every comparison is
# skipped, and an empty result reads exactly like "nothing unpushed".
cat > "$TMP/stk-badremote.json" <<'JSON'
{ "project": { "name": "stk", "mainBranch": "main", "remote": "nosuchremote" },
  "queue": { "path": ".claude/work/QUEUE.json" },
  "anchors": [ { "id": "t", "cmd": "true" } ] }
JSON
stk_out3=$(cd "$STK" && SPRINT_HARNESS_CONFIG="$TMP/stk-badremote.json" \
    ./.claude/harness-core/preflight.sh 2>&1)
grep -q "cannot prove what is unpushed" <<< "$stk_out3" \
    && ok "preflight fails closed when the remote ref is missing" \
    || no "preflight fails closed when the remote ref is missing"

# ── preflight + workflow syntax ──────────────────────────────────────────────
echo
echo "── preflight / syntax ──"
# No remote configured, so preflight MUST fail — and that is the correct
# behaviour: it cannot prove the base is current.
out=$("$REPO/.claude/harness-core/preflight.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "preflight fails closed with no reachable remote" \
                || no "preflight fails closed with no reachable remote"
grep -q "working tree clean" <<< "$out" && ok "preflight reports tree state" \
                                        || no "preflight reports tree state"
grep -q "queue:" <<< "$out" && ok "preflight reads the queue" \
                            || no "preflight reads the queue"

# NOT `node --check`. A workflow script is executed as an ASYNC FUNCTION BODY by
# the runtime, so it legally contains a top-level `return` — which `node --check`
# rejects as an illegal return statement. Validating it the wrong way would
# either fail forever or push someone into removing the early return. Parse it
# the way it is actually run.
node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8").replace(/^export const meta/m, "const meta");
    const AsyncFn = Object.getPrototypeOf(async function () {}).constructor;
    new AsyncFn("args", "log", "agent", "pipeline", "parallel", src);
' "$HERE/core/sprint-batch.mjs" 2>/dev/null \
    && ok "sprint-batch.mjs parses as an async function body" \
    || no "sprint-batch.mjs parses as an async function body"
node --check "$HERE/core/plan-batch.mjs" 2>/dev/null \
    && ok "plan-batch.mjs parses" || no "plan-batch.mjs parses"
for s in "$HERE"/core/*.sh "$HERE/install.sh"; do
    bash -n "$s" 2>/dev/null || no "bash syntax: $(basename "$s")"
done
ok "all shell scripts parse"

# ── the item contract reaches the agents ─────────────────────────────────────
echo
echo "── item contract ──"

# newFiles must survive into node.files, which IS the builder's
# "files this node owns — do not edit anything else" list. The grouped path has
# always unioned it via filesOf(); the repo-wide branch was written separately
# and used item.files alone, so a repo-wide item that CREATES a file handed its
# builder a prompt forbidding the file it was told to create. Both scopes are
# asserted — a fix applied to only one branch is the bug that was just found.
NFR="$TMP/newfiles"; mkdir -p "$NFR/.claude/work"
git init -q "$NFR"; git -C "$NFR" config user.email t@t.t; git -C "$NFR" config user.name t
cat > "$NFR/.claude/harness.config.json" <<'JSON'
{ "project": { "name": "nf", "mainBranch": "main", "remote": "origin" },
  "queue": { "path": ".claude/work/QUEUE.json" },
  "anchors": [ { "id": "t", "cmd": "true" } ] }
JSON
cat > "$NFR/.claude/work/QUEUE.json" <<'JSON'
{ "items": [
  { "id": "RW", "title": "repo-wide that creates a file", "status": "open", "severity": "low",
    "files": ["src/a.ts"], "newFiles": ["src/made-by-rw.ts"], "scope": "repo-wide",
    "scopeNote": "convention", "detail": "d", "dispatchable": true },
  { "id": "GR", "title": "bounded that creates a file", "status": "open", "severity": "low",
    "files": ["src/b.ts"], "newFiles": ["src/made-by-gr.ts"], "scope": "bounded",
    "detail": "d", "dispatchable": true } ] }
JSON
git -C "$NFR" add -A >/dev/null 2>&1; git -C "$NFR" commit -qm init >/dev/null 2>&1
nf_plan=$(cd "$NFR" && node "$HERE/core/plan-batch.mjs" RW GR --json 2>/dev/null)
nf_missing=$(node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const p=JSON.parse(s), miss=[];
  for (const n of p.nodes)
    for (const f of n.items.flatMap(i => i.newFiles || []))
      if (!n.files.includes(f)) miss.push(n.nodeId + ":" + f);
  process.stdout.write(miss.join(","));
});' <<< "$nf_plan")
[ -z "$nf_missing" ] \
    && ok "newFiles reaches node.files in every scope" \
    || no "newFiles dropped from node.files ($nf_missing)"

# An item field that no prompt renders must STOP the launch, not vanish. On
# brian-chastain batch 1 six items were re-scoped onto a `sharpened` key beside
# `detail`; every agent would have run without ever seeing it, and the resulting
# all-green batch would have read as "the constraints held". Both directions:
# a clean item must NOT trip it, or the assertion is just an outage.
item_contract() {
    node -e '
const fs=require("fs");
const src=fs.readFileSync(process.argv[1],"utf8").replace(/^export const meta/m,"const meta");
const harness={anchors:[{id:"t",cmd:"true",cwd:".",always:true}],setup:[],lenses:["intent"],
  requireAllLenses:true,agents:{},branchPrefix:"sprint",mainBranch:"main",pairedArtifacts:[]};
const items=JSON.parse(process.argv[2]);
const plan={nodes:[{nodeId:"N",items,files:["a.ts"],wave:0,serial:false,reason:"x"}],
  harness,wave:0,batchName:"b",baseBranch:"base"};
const f=new Function("args","agent","parallel","pipeline","log","phase","budget","workflow",
  "return (async()=>{"+src+"})()");
f(plan,()=>{},()=>{},()=>{},()=>{},()=>{},{},()=>{})
  .then(()=>process.exit(0))
  .catch(e=>process.exit(/would reach no agent/.test(e.message)?7:0));
' "$HERE/core/sprint-batch.mjs" "$1" 2>/dev/null
    return $?
}
CLEAN_ITEM='[{"id":"A","title":"t","source":"s","severity":"low","files":["a.ts"],"newFiles":[],"detail":"d"}]'
STRAY_ITEM='[{"id":"A","title":"t","source":"s","severity":"low","files":["a.ts"],"newFiles":[],"detail":"d","sharpened":{"x":1}}]'
item_contract "$STRAY_ITEM"; [ $? -eq 7 ] \
    && ok "sprint-batch REFUSES an item field no prompt renders" \
    || no "sprint-batch REFUSES an item field no prompt renders"
item_contract "$CLEAN_ITEM"; [ $? -ne 7 ] \
    && ok "sprint-batch accepts the documented item keys" \
    || no "sprint-batch accepts the documented item keys"

# The graph builds its JSON schema from the anchor ids in the plan, so an anchor
# id that is not a bare word would produce an invalid schema at dispatch time —
# far too late. config.mjs rejects it up front.
cat > "$TMP/badid.json" <<'JSON'
{ "project": { "name": "x", "mainBranch": "main" }, "queue": { "path": "q.json" },
  "anchors": [ { "id": "not a word", "cmd": "true" } ] }
JSON
out=$(SPRINT_HARNESS_CONFIG="$TMP/badid.json" node -e \
    'import("'"$REPO"'/.claude/harness-core/lib/config.mjs").then(m=>m.loadConfig())' 2>&1)
grep -q "bare word" <<< "$out" && ok "refuses an anchor id that breaks the schema" \
                               || no "refuses an anchor id that breaks the schema"

echo
echo "════════════════════════"
echo "$pass passed, $fail failed"
exit $((fail > 0))
