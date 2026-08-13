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
