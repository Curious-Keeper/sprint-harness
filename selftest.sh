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

# THE SCHEMA AND THE LOADER CAN DRIFT, and the kit says so as a known gap:
# validate() is hand-written and nothing checked it against the JSON schema. This
# does not do full validation (no ajv dependency), but it catches the class that
# actually bit — a shipped example carrying a key the schema forbids, which makes
# the example fail the validation the schema advertises.
schema_out=$(node -e '
const s = require("'"$HERE"'/harness.config.schema.json");
const fs = require("fs"), path = require("path");
const allowed = new Set(Object.keys(s.properties));
const bad = [];
for (const f of fs.readdirSync("'"$HERE"'/examples")) {
    if (!f.endsWith(".json")) continue;
    const c = JSON.parse(fs.readFileSync(path.join("'"$HERE"'/examples", f), "utf8"));
    for (const k of Object.keys(c)) if (!allowed.has(k)) bad.push(`${f}:${k}`);
}
console.log(bad.join(",") || "clean");' 2>&1)
[ "$schema_out" = "clean" ] \
    && ok "every shipped example uses only keys the schema allows" \
    || no "every shipped example uses only keys the schema allows ($schema_out)"

# Every top-level key the LOADER defaults must exist in the schema, or a
# documented setting is one the schema rejects.
drift_out=$(node --input-type=module -e '
import { readFileSync } from "node:fs";
const schema = JSON.parse(readFileSync("'"$HERE"'/harness.config.schema.json", "utf8"));
const src = readFileSync("'"$HERE"'/core/lib/config.mjs", "utf8");
const block = src.slice(src.indexOf("const DEFAULTS = {"), src.indexOf("\nconst merge ="));
const keys = [...block.matchAll(/^    ([a-zA-Z]+):/gm)].map((m) => m[1]);
const missing = keys.filter((k) => !(k in schema.properties));
console.log(missing.join(",") || "clean");' 2>&1)
[ "$drift_out" = "clean" ] \
    && ok "every config key the loader defaults is in the schema" \
    || no "every config key the loader defaults is in the schema (missing: $drift_out)"

# ── file extensions are the partitioner ──────────────────────────────────────
#
# Union-find is correct given its edges; the edges come from scraping prose. An
# extension the scraper cannot see is a file the collision graph cannot see, and
# the dangerous case is PARTIAL visibility — an item touching a .md and a .ts
# scrapes the .ts, scores `bounded`, and hides the .md collision in a node the
# planner is confident about.
echo
echo "── file extensions ──"
ext_out=$(node --input-type=module -e '
import { citedFiles, buildResolver, DEFAULT_EXTENSIONS, fileRe }
    from "'"$REPO"'/.claude/harness-core/lib/extract.mjs";
const tracked = ["src/nav.ts", "docs/guide.md", "src/App.vue"];
const r = buildResolver(tracked);
const prose = "Update src/nav.ts and the copy in docs/guide.md";
const a = citedFiles(prose, r);
const b = citedFiles(prose, r, { extensions: [...DEFAULT_EXTENSIONS, "md"] });
const noise = citedFiles("See example.com, i.e. the one at foo.unknown", r);
console.log(JSON.stringify({
    defaultFiles: a.files,
    flagged: a.problems.filter(p => p.unknownExtension).map(p => p.resolved),
    configuredFiles: b.files,
    configuredProblems: b.problems.length,
    noiseProblems: noise.problems.filter(p => p.unknownExtension).length,
    tsxWins: [..."edit web/A.tsx now".matchAll(fileRe())].map(m => m[1]),
}));' 2>&1)

xcheck() { # <desc> <jq-filter> <expected>
    local got; got=$(jq -r "$2" <<< "$ext_out" 2>/dev/null)
    [ "$got" = "$3" ] && ok "$1" || no "$1 (got: $got, want: $3)"
}
xcheck "an unconfigured extension is NOT scraped into the graph" \
    '.defaultFiles|join(",")' "src/nav.ts"
xcheck "...but it is REPORTED rather than silently dropped" \
    '.flagged|join(",")' "docs/guide.md"
xcheck "configuring the extension puts the file in the graph" \
    '.configuredFiles|join(",")' "docs/guide.md,src/nav.ts"
xcheck "a configured extension produces no complaint" '.configuredProblems' 0
# A linter that cries wolf is one people stop reading — scar #17.
xcheck "prose that is not a file does not cry wolf" '.noiseProblems' 0
# The alternation must be longest-first or `ts` eats the `tsx`.
xcheck "tsx does not lose the race against ts" '.tsxWins|join(",")' "web/A.tsx"

# DOT-DIRECTORIES. `\b` cannot match before a leading dot, so the old regex
# started one character late and captured `github/workflows/ci.yml` — which
# suffix-matches nothing, because the real path ends in `/.github/...`. Every
# citation of .github/, .claude/ or .circleci/ was silently dropped from the
# collision graph. Found in a live project 2026-08-21, which had been working
# around it with a per-repo alias table.
dot_out=$(node --input-type=module -e '
import { citedFiles, buildResolver, fileRe }
    from "'"$REPO"'/.claude/harness-core/lib/extract.mjs";
const tracked = [".github/workflows/ci.yml", ".claude/work/extract-queue.mjs", "src/a.ts"];
const r = buildResolver(tracked);
console.log(JSON.stringify({
    scraped: [...".github/workflows/ci.yml and .claude/work/extract-queue.mjs".matchAll(fileRe())].map(m => m[1]),
    resolved: citedFiles("bump .github/workflows/ci.yml:60-61 and src/a.ts", r).files,
    midSentence: [..."see `.circleci/config.yml` here".matchAll(fileRe())].map(m => m[1]),
    noDoubleMatch: [...".github/workflows/ci.yml".matchAll(fileRe())].length,
}));' 2>&1)
dcheck() { local got; got=$(jq -r "$2" <<< "$dot_out" 2>/dev/null)
    [ "$got" = "$3" ] && ok "$1" || no "$1 (got: $got, want: $3)"; }
dcheck "a leading dot-directory keeps its dot" \
    '.scraped|join(",")' ".github/workflows/ci.yml,.claude/work/extract-queue.mjs"
dcheck "...and therefore RESOLVES to the tracked file" \
    '.resolved|join(",")' ".github/workflows/ci.yml,src/a.ts"
dcheck "a dot-directory inside prose still matches" \
    '.midSentence|join(",")' ".circleci/config.yml"
dcheck "the path is not ALSO matched one char in" '.noDoubleMatch' 1

# PROSE PUNCTUATION vs A REAL BRACKET. PATH_BODY admits ( and [ because real
# paths contain them (Next.js route groups, dynamic segments), and LEFT_EDGE lets
# a match START on one — required for a dot-directory. Ordinary prose then gets
# glued on: "no overflow container (carriers/[id]/page.tsx" captured the paren
# and suffix-matched nothing, dropping the citation. Same silent edge loss the
# dot-directory fix above exists to prevent, reached through that very fix.
# Found 2026-08-21 on allrail-ops-next, on the first run after installing it.
par_out=$(node --input-type=module -e '
import { citedFiles, buildResolver }
    from "'"$REPO"'/.claude/harness-core/lib/extract.mjs";
const tracked = ["web/app/(app)/carriers/[id]/page.tsx", "web/app/(app)/orders/page.tsx", "src/a.ts"];
const r = buildResolver(tracked);
console.log(JSON.stringify({
    parenProse: citedFiles("no overflow container (carriers/[id]/page.tsx, two tables)", r).files,
    routeGroup: citedFiles("the list lives at (app)/orders/page.tsx today", r).files,
    stillDrops: citedFiles("nothing here", r).files.length,
}));' 2>&1)
pcheck() { local got; got=$(jq -r "$2" <<< "$par_out" 2>/dev/null)
    [ "$got" = "$3" ] && ok "$1" || no "$1 (got: $got, want: $3)"; }
pcheck "a paren from PROSE is trimmed off the path" \
    '.parenProse|join(",")' "web/app/(app)/carriers/[id]/page.tsx"
pcheck "...but a route group the path CLOSES is kept whole" \
    '.routeGroup|join(",")' "web/app/(app)/orders/page.tsx"

cat > "$TMP/badext.json" <<'JSON'
{ "project": { "name": "x", "mainBranch": "main" }, "queue": { "path": "q.json" },
  "anchors": [ { "id": "t", "cmd": "true" } ],
  "extract": { "fileExtensions": [".md"] } }
JSON
out=$(SPRINT_HARNESS_CONFIG="$TMP/badext.json" node -e \
    'import("'"$REPO"'/.claude/harness-core/lib/config.mjs").then(m=>m.loadConfig())' 2>&1)
grep -q 'not a bare extension' <<< "$out" \
    && ok "refuses \".md\" — the dot is a silent no-match" \
    || no "refuses \".md\" — the dot is a silent no-match"

# ── companions ───────────────────────────────────────────────────────────────
#
# `pairedArtifacts` COMPELS a counterpart, but `files` is scraped from citations
# and a map entry cites the code it is about — not the test that does not exist
# yet. So the harness demanded a file no file list granted, and the builder's
# only moves were to fail its own anchor or to leave scope and be rejected.
# Watched happen on a live project; every party behaved correctly and the node
# was still lost.
echo
echo "── companions ──"
comp_out=$(node --input-type=module -e '
import { pairedArtifactFor, withCompanions }
    from "'"$REPO"'/.claude/harness-core/lib/extract.mjs";
const rules = [{ id: "unit", srcDir: "src", srcExt: ".tsx",
                 pairPath: "src/__tests__/{name}.test.tsx",
                 excludeDirs: ["src/__tests__"] }];
console.log(JSON.stringify({
    derived:    pairedArtifactFor("src/feat/Alpha.tsx", rules),
    notForTest: pairedArtifactFor("src/__tests__/Alpha.test.tsx", rules),
    notForExt:  pairedArtifactFor("src/util.ts", rules),
    notOutside: pairedArtifactFor("web/Alpha.tsx", rules),
    prefixOnly: pairedArtifactFor("srcfoo/Alpha.tsx", rules),
    granted:    withCompanions(["src/feat/Alpha.tsx"], { pairedArtifacts: rules }),
    handSeeded: withCompanions(["package.json"], { companions: { "package.json": ["package-lock.json"] } }),
    empty:      withCompanions([], { pairedArtifacts: rules }),
}));' 2>&1)
ccheck() { local got; got=$(jq -r "$2" <<< "$comp_out" 2>/dev/null)
    [ "$got" = "$3" ] && ok "$1" || no "$1 (got: $got, want: $3)"; }
ccheck "the paired counterpart is DERIVED from the gate's own rule" \
    '.derived' "src/__tests__/Alpha.test.tsx"
ccheck "a test file does not get a test of its own" '.notForTest' null
ccheck "a non-matching extension gets nothing" '.notForExt' null
ccheck "a file outside srcDir gets nothing" '.notOutside' null
ccheck "srcDir matches on a path SEGMENT, not a string prefix" '.prefixOnly' null
ccheck "the counterpart lands in the item's file set" \
    '.granted|join(",")' "src/__tests__/Alpha.test.tsx,src/feat/Alpha.tsx"
ccheck "a hand-seeded companion is granted too" \
    '.handSeeded|join(",")' "package-lock.json,package.json"
# Companions apply to what was FOUND. They must never turn an item with no
# derivable files into a dispatchable one.
ccheck "companions cannot rescue an item that cited nothing" '.empty|length' 0

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

# ── the exclusive bridge ─────────────────────────────────────────────────────
#
# An exclusive item must form NO edges. It used to be unioned like everything
# else and only skipped when EMITTING groups, which made it a bridge: two items
# that collide with nothing except the repo-wide item were merged into one serial
# node, and that node inherited the repo-wide item's files as files it OWNED.
#
# Its own queue and config, so the assertions above keep their fixture.
echo
echo "── exclusive bridge ──"
cat > "$REPO/.claude/work/BRIDGE.json" <<'JSON'
{
  "items": [
    { "id": "P1", "title": "shares x with the exclusive item", "status": "open",
      "scope": "bounded", "files": ["src/p1.ts", "src/x.ts"], "newFiles": [] },
    { "id": "P2", "title": "shares y with the exclusive item", "status": "open",
      "scope": "bounded", "files": ["src/p2.ts", "src/y.ts"], "newFiles": [] },
    { "id": "R1", "title": "refs the exclusive item", "status": "open",
      "scope": "bounded", "files": ["src/r1.ts"], "newFiles": [], "mapRef": "H" },
    { "id": "R2", "title": "also refs the exclusive item", "status": "open",
      "scope": "bounded", "files": ["src/r2.ts"], "newFiles": [], "mapRef": "H" },
    { "id": "H", "title": "rewrites a convention", "status": "open",
      "scope": "repo-wide", "files": ["src/x.ts", "src/y.ts"], "newFiles": [] },

    { "id": "D1", "title": "dense 1", "status": "open", "scope": "bounded",
      "files": ["src/dense.ts"], "newFiles": [] },
    { "id": "D2", "title": "dense 2", "status": "open", "scope": "bounded",
      "files": ["src/dense.ts"], "newFiles": [] },
    { "id": "D3", "title": "dense 3", "status": "open", "scope": "bounded",
      "files": ["src/dense.ts"], "newFiles": [] },
    { "id": "D4", "title": "dense 4", "status": "open", "scope": "bounded",
      "files": ["src/dense.ts"], "newFiles": [] },
    { "id": "D5", "title": "dense 5", "status": "open", "scope": "bounded",
      "files": ["src/dense.ts"], "newFiles": [] }
  ]
}
JSON
sed 's#work/QUEUE.json#work/BRIDGE.json#' "$REPO/.claude/harness.config.json" \
    > "$TMP/bridge.json"
P=$(SPRINT_HARNESS_CONFIG="$TMP/bridge.json" node "$PB" P1 P2 R1 R2 H --json 2>/dev/null)

check "a repo-wide item does not bridge two items that share a file with it" \
    '[.nodes[]|select((.items|map(.id)|sort)==["P1","P2"])]|length' 0
check "a repo-wide item does not bridge two items that REF it" \
    '[.nodes[]|select((.items|map(.id)|sort)==["R1","R2"])]|length' 0
check "no node holds more than one item — nothing here actually collides" \
    '[.nodes[]|select(.items|length>1)]|length' 0
check "fan-out width survives the exclusive item" \
    '.parallelWidth' 4
check "the exclusive item is still sequenced into its own wave" \
    '[.nodes[]|select(.nodeId=="H")][0].wave' 1
# The bridge's worst effect: node.files is the UNION of a group's members and
# becomes the builder's "files this node owns" list. P1 declares x and P2
# declares y, so each owning its own is correct; the bridge gave BOTH builders
# BOTH files, and neither item had declared the other's.
check "no wave-0 node owns a file none of its items declared" \
    '[.nodes[]|select(.wave==0)|select((.files|index("src/x.ts")) and (.files|index("src/y.ts")))]|length' 0
check "an item that merely REFS the exclusive one owns only its own file" \
    '[.nodes[]|select(.nodeId=="R1")][0].files|join(",")' "src/r1.ts"
# Sequenced, not grouped — the overlap is real and must stay VISIBLE.
check "the overlap is reported as cross-wave instead" \
    '[.crossWaveFiles[]|select(.file=="src/x.ts")]|length' 1

# ── "there is no graph here" ─────────────────────────────────────────────────
#
# "When not to use this" was documented and never enforced. A one-wide batch is
# not a cheaper loop, it is the same loop plus a builder handoff and N verifiers.
echo
echo "── not a graph ──"
P=$(SPRINT_HARNESS_CONFIG="$TMP/bridge.json" node "$PB" P1 --json 2>/dev/null)
check "a width-1 batch is flagged, not silently emitted" \
    '[.advisories[]|select(test("THERE IS NO GRAPH"))]|length' 1
P=$(SPRINT_HARNESS_CONFIG="$TMP/bridge.json" node "$PB" P1 P2 --json 2>/dev/null)
check "a genuinely parallel batch carries no advisory" \
    '.advisories|length' 0

# The density trap: one node with many items is one builder doing them serially.
# That is correct behaviour, but it is the original loop with a 4x tax, so the
# partitioner has to say so rather than let it be discovered in the diff.
P=$(SPRINT_HARNESS_CONFIG="$TMP/bridge.json" node "$PB" D1 D2 D3 D4 D5 --json 2>/dev/null)
check "five items on one file collapse to a single serial node" \
    '[.nodes[]|select(.items|length==5)]|length' 1
check "a dense node is flagged as having no fan-out inside it" \
    '[.advisories[]|select(test("no fan-out inside a node"))]|length' 1

# Explicit ids still WORK at width 1 — re-verifying one rejected node is a real
# workflow. It is --auto, the machine PROPOSING a batch, that must not offer one.
expect "explicit ids still plan a width-1 batch" 0 \
    env SPRINT_HARNESS_CONFIG="$TMP/bridge.json" node "$PB" P1
expect "--auto REFUSES to propose a batch that is not a graph" 1 \
    env SPRINT_HARNESS_CONFIG="$TMP/bridge.json" node "$PB" --auto 1

# ── scope gate ───────────────────────────────────────────────────────────────
#
# "Do not touch files outside this node's list" was prose in three places — the
# builder contract, the intent lens and the integrate step. Scar #7: a rule in a
# prompt is a suggestion. It is a set difference, so it is an exit code.
echo
echo "── scope gate ──"
SG="$REPO/.claude/harness-core/scope-gate.sh"
SC="$TMP/scope"; mkdir -p "$SC/src"
git init -q "$SC"; git -C "$SC" config user.email t@t.t; git -C "$SC" config user.name t
for f in a b c; do echo "// $f" > "$SC/src/$f.ts"; done
cat > "$SC/plan.json" <<'JSON'
{ "nodes": [
  { "nodeId": "n1", "wave": 0, "exclusive": false, "files": ["src/a.ts"] },
  { "nodeId": "n2", "wave": 0, "exclusive": false, "files": ["src/b.ts"] },
  { "nodeId": "hw", "wave": 1, "exclusive": true,  "files": ["src/a.ts"] }
] }
JSON
git -C "$SC" add -A && git -C "$SC" commit -qm init
git -C "$SC" branch -M main
git -C "$SC" checkout -qb work
echo "// edited" >> "$SC/src/a.ts"; git -C "$SC" commit -qam "in scope"

sg() { ( cd "$SC" && bash "$SG" "$@" >/dev/null 2>&1 ); }
sg main plan.json n1 && ok "passes when every changed file is declared" \
                     || no "passes when every changed file is declared"

echo "// sneaky" >> "$SC/src/c.ts"; git -C "$SC" commit -qam "out of scope"
sg main plan.json n1 && no "FAILS on a file the node does not own" \
                     || ok "FAILS on a file the node does not own"
sg_out=$( cd "$SC" && bash "$SG" main plan.json n1 2>&1 )
grep -q "src/c.ts" <<< "$sg_out" && ok "names the undeclared file" || no "names the undeclared file"

# The union of a wave is what the MERGED tree is allowed to contain. Per-node
# green does not imply merged green.
sg main plan.json --wave 0 && no "wave mode gates the merged tree too" \
                           || ok "wave mode gates the merged tree too"
sg main --files "src/a.ts src/c.ts" && ok "an explicit --files list is accepted" \
                                    || no "an explicit --files list is accepted"

# An exclusive node's file list is incomplete BY CONSTRUCTION. Gating it against
# that list would reject every repo-wide node on sight.
sg main plan.json hw && ok "an exclusive node is EXEMPT, not failed" \
                     || no "an exclusive node is EXEMPT, not failed"
ex_out=$( cd "$SC" && bash "$SG" main plan.json hw 2>&1 )
grep -q "EXEMPT" <<< "$ex_out" && ok "the exemption is stated, not silent" \
                               || no "the exemption is stated, not silent"

# Environment errors must be exit 2, distinct from a real violation (1).
( cd "$SC" && bash "$SG" no-such-ref plan.json n1 >/dev/null 2>&1 )
[ $? -eq 2 ] && ok "a missing base ref is exit 2, not a violation" \
             || no "a missing base ref is exit 2, not a violation"
( cd "$SC" && bash "$SG" main plan.json no-such-node >/dev/null 2>&1 )
[ $? -eq 2 ] && ok "an unknown nodeId is exit 2" || no "an unknown nodeId is exit 2"

# ── anchor placeholders ──────────────────────────────────────────────────────
#
# `{base}` resolves to the NODE'S base, not project.mainBranch. A gate that diffs
# against a ref must be told which ref; judged against main on a stacked branch,
# every node inherits every earlier node's failures and the gate stops
# discriminating exactly when the stack is deepest.
echo
echo "── anchor placeholders ──"
ph_out=$(node -e '
const fs = require("fs");
const src = fs.readFileSync("'"$REPO"'/.claude/harness-core/sprint-batch.mjs", "utf8");
const body = src.replace(/^export const meta[\s\S]*?\n};\n/, "");
const plan = {
  baseBranch: "sprint/base-7", batchName: "b", wave: 0,
  nodes: [{ nodeId: "n1", wave: 0, exclusive: false, files: ["src/a.ts"],
            items: [{ id: "n1", title: "t", detail: "d" }] }],
  harness: {
    anchors: [{ id: "gate", cmd: "gate.sh {base}", cwd: ".", always: false, whenTouches: ["src/"] },
              { id: "keep", cmd: "echo ${SHELL_VAR} ok", cwd: ".", always: true }],
    setup: [], lenses: ["intent","invariants","anchors"], requireAllLenses: true,
    agents: {}, branchPrefix: "sprint", mainBranch: "main",
    scopeGate: ".claude/harness-core/scope-gate.sh",
  },
};
const seen = [];
const fn = new Function("args","log","agent","parallel","pipeline","phase",
  `return (async()=>{${body}})()`);
fn(plan, () => {}, (p) => { seen.push(p); return Promise.resolve(null); },
   (t) => Promise.all(t.map(f => f())), async (items, ...stages) => {
     let out = [];
     for (const it of items) { let v = it; for (const st of stages) v = await st(v, it, 0); out.push(v); }
     return out;
   }, () => {}).then(() => {
     const p = seen.join("\n");
     console.log(JSON.stringify({
       resolved: /gate\.sh sprint\/base-7/.test(p),
       notMain: !/gate\.sh main/.test(p),
       shellVarIntact: /echo \$\{SHELL_VAR\} ok/.test(p),
       nullInstruction: /report gate: null/.test(p),
     }));
   }).catch(e => console.log(JSON.stringify({ error: String(e.message) })));' 2>&1)

pcheck() { local got; got=$(jq -r "$2" <<< "$ph_out" 2>/dev/null)
    [ "$got" = "$3" ] && ok "$1" || no "$1 (got: $got, want: $3; out: $(head -c 200 <<< "$ph_out"))"; }
pcheck "{base} resolves to the node's base branch" '.resolved' true
pcheck "...and NOT to project.mainBranch" '.notMain' true
pcheck "a shell \${VAR} is left alone" '.shellVarIntact' true
pcheck "a conditional anchor is told to report null" '.nullInstruction' true

# An unknown placeholder must THROW before any agent spawns, not reach the shell
# as a literal ref name and exit 2 (which reads as "this node is broken").
bad_out=$(node -e '
const fs = require("fs");
const src = fs.readFileSync("'"$REPO"'/.claude/harness-core/sprint-batch.mjs", "utf8");
const body = src.replace(/^export const meta[\s\S]*?\n};\n/, "");
const plan = { baseBranch: "b", nodes: [{ nodeId: "n", wave: 0, files: [], items: [] }],
  harness: { anchors: [{ id: "x", cmd: "gate.sh {basebranch}", always: true }], setup: [],
    lenses: ["a"], requireAllLenses: true, agents: {}, branchPrefix: "s", mainBranch: "main" } };
new Function("args","log","agent","parallel","pipeline","phase", `return (async()=>{${body}})()`)
  (plan, ()=>{}, ()=>Promise.resolve(null), ()=>Promise.resolve([]), ()=>Promise.resolve([]), ()=>{})
  .then(()=>console.log("NO THROW")).catch(e=>console.log(e.message));' 2>&1)
grep -q "unknown placeholder {basebranch}" <<< "$bad_out" \
    && ok "an unknown placeholder throws, naming the key" \
    || no "an unknown placeholder throws, naming the key ($(head -c 160 <<< "$bad_out"))"

# ── reduce ───────────────────────────────────────────────────────────────────
#
# The reduce decides what a batch MEANS — accepted vs rejected vs unverified,
# whether a partial run is reported as complete, and whether the builder's
# claimed exit codes match what an independent agent observed. It was the only
# load-bearing code in the kit with no test behind it, because a Workflow script
# cannot be imported and this file could therefore only PARSE it.
#
# core/reduce-fixture.mjs slices the real reduce out of the shipped file and runs
# known-bad results through it. Zero agents, zero tokens.
echo
echo "── reduce ──"
RF="$REPO/.claude/harness-core/reduce-fixture.mjs"
SB="$REPO/.claude/harness-core/sprint-batch.mjs"
if [ ! -f "$RF" ]; then
    no "install.sh ships the reduce fixture"
else
    ok "install.sh ships the reduce fixture"
    rf_out=$(node "$RF" "$SB" 2>/dev/null)
    while IFS='|' read -r verdict desc; do
        [ -n "$desc" ] || continue
        [ "$verdict" = "ok" ] && ok "reduce: $desc" || no "reduce: $desc"
    done <<< "$rf_out"

    # The fixture is only worth having if it FAILS on a regression. Mutate the
    # three classifications that scars #2 and #14 exist for and confirm each is
    # caught. A test that cannot fail is the thing this whole kit argues against.
    mutate() { # <desc> <sed-expr>
        sed "$2" "$SB" > "$TMP/mutant.mjs"
        # A mutation test that did not mutate proves nothing, and it fails for a
        # reason that looks identical to a real miss. Say which one it was: these
        # patterns pin exact source text and WILL rot the next time the reduce is
        # edited, which is the point at which the message matters most.
        if cmp -s "$SB" "$TMP/mutant.mjs"; then
            no "reduce fixture CATCHES: $1 (PATTERN DID NOT MATCH — update the sed, not the code)"
            return
        fi
        if node "$RF" "$TMP/mutant.mjs" >/dev/null 2>&1; then
            no "reduce fixture CATCHES: $1"
        else
            ok "reduce fixture CATCHES: $1"
        fi
    }
    mutate "unverified collapsed into rejected (scar #2)" "s/: 'unverified';/: 'rejected';/"
    mutate "a missing scope gate defaulted to 0 (scar #8)" "s/r.build?.scopeGate ?? null;/r.build?.scopeGate ?? 0;/"
    mutate "scope violation dropped from acceptance" "s/&& rejects.length === 0 && scopeClean;/\&\& rejects.length === 0;/"
    mutate "anchor disagreement check disabled (scar #14)" \
        "s/if (observed\[k\] != null && claimed\[k\] != null && observed\[k\] !== claimed\[k\]) {/if (false) {/"
    mutate "single reject downgraded to a majority vote" "s/rejects.length === 0 && scopeClean;/rejects.length < passes.length && scopeClean;/"
    mutate "a not-applicable anchor compared as a number (E#19)" \
        "s/if (observed\[k\] != null && claimed\[k\] != null && observed\[k\] !== claimed\[k\]) {/if (observed[k] !== claimed[k]) {/"
    mutate "a skipped ALWAYS-run anchor treated as success" \
        "s/if (claimed?.\[k\] === undefined || claimed?.\[k\] === null) {/if (false) {/"
    mutate "fan-in guard removed" "s/^if (lost > 0) {/if (false) {/"

    # And it must refuse rather than silently pass if someone moves the markers.
    grep -v "REDUCE-BEGIN" "$SB" > "$TMP/nomarker.mjs"
    node "$RF" "$TMP/nomarker.mjs" >/dev/null 2>&1
    [ $? -eq 2 ] && ok "reduce fixture REFUSES a file whose markers moved" \
                 || no "reduce fixture REFUSES a file whose markers moved"
fi

# ── prebuilt nodes: re-judge, and the canary ─────────────────────────────────
#
# A node carrying `prebuilt` skips the builder and is verified as-is. This runs
# the SHIPPED graph with stubbed agent/pipeline/parallel — the real dispatch and
# the real reduce, zero agents — and asserts the builder is not called while
# every lens still is.
#
# It matters because of what the rest of this file CANNOT prove: the reduce
# fixture shows bad input is classified correctly, not that any verifier detects
# anything. A run where every node is accepted is consistent with three working
# lenses and equally consistent with three that are not looking. Planting a known
# defect and watching for the reject is the only thing that separates them, and
# it is impossible without a way to verify a branch a builder did not just write.
echo
echo "── prebuilt / canary ──"
cat > "$TMP/prebuilt.mjs" <<'MJS'
import { readFileSync } from "node:fs";
const src = readFileSync(process.argv[2], "utf8").replace(/^export const meta/m, "const meta");
const AsyncFn = Object.getPrototypeOf(async function () {}).constructor;
const calls = [];
const models = [];
const agent = async (prompt, opts) => {
    calls.push(opts.label);
    // `model` ABSENT and `model: null` are different things downstream, so
    // record which one actually arrived rather than normalising them.
    models.push([opts.label, "model" in opts ? opts.model : "absent"]);
    if (opts.label.startsWith("verify:")) {
        return { lens: opts.label.split(":")[1], verdict: "reject", evidence: ["planted defect found"],
                 confidence: "high", observedAnchors: { tsc: 0, lint: 0, test: 1 }, observedScopeGate: 0 };
    }
    return { status: "done", branch: "b", commit: "abc1234", filesChanged: ["web/a.tsx"],
             anchors: { tsc: 0, lint: 0, test: 0 }, summary: "built", scopeGate: 0 };
};
const parallel = (t) => Promise.all(t.map((f) => f()));
const pipeline = async (items, ...stages) => {
    const out = [];
    for (const [i, item] of items.entries()) { let v = item;
        for (const s of stages) v = await s(v, item, i); out.push(v); }
    return out;
};
const harness = {
    anchors: ["tsc", "lint", "test"].map((id) => ({ id, cmd: id, cwd: ".", always: true, whenTouches: null })),
    setup: [{ cmd: "npm ci", cwd: ".", why: null }],
    lenses: ["intent", "invariants", "anchors"], requireAllLenses: true,
    agents: { builder: "sprint-builder", verifier: "sprint-verifier" },
    branchPrefix: "sprint", mainBranch: "main",
    scopeGate: ".claude/harness-core/scope-gate.sh", pairedArtifacts: [],
    ...(process.argv[3] ? { verifierModel: process.argv[3] } : {}),
};
const node = (id, extra = {}) => ({ nodeId: id, wave: 0, reason: "r", serial: false, files: ["web/a.tsx"],
    items: [{ id: "x1", title: "t", source: "s", severity: "high", files: ["web/a.tsx"], newFiles: [], detail: "d" }], ...extra });
const plan = { baseBranch: "base", batchName: "canary", wave: 0, harness, nodes: [
    node("normal"),
    node("planted", { prebuilt: { status: "done", branch: "canary/planted", commit: "deadbee",
        filesChanged: ["web/a.tsx"], anchors: { tsc: 0, lint: 0, test: 0 }, summary: "claims green", scopeGate: 0 } }),
]};
const report = await new AsyncFn("args", "log", "agent", "pipeline", "parallel", src)(plan, () => {}, agent, pipeline, parallel);
const p = report.nodes.find((n) => n.nodeId === "planted");
console.log(JSON.stringify({
    builds: calls.filter((c) => c.startsWith("build:")).join(","),
    lenses: calls.filter((c) => c.startsWith("verify:") && c.endsWith(":planted")).length,
    outcome: p?.outcome,
    claimed: p?.claimedAnchors?.test,
    disagreements: (report.warnings ?? []).filter((w) => /ANCHOR DISAGREEMENT/.test(w)).length,
    verifyModels: [...new Set(models.filter(([l]) => l.startsWith("verify:")).map(([, m]) => m))].join(","),
    buildModels: [...new Set(models.filter(([l]) => l.startsWith("build:")).map(([, m]) => m))].join(","),
}));
MJS
pb_out=$(node "$TMP/prebuilt.mjs" "$REPO/.claude/harness-core/sprint-batch.mjs" 2>&1)
pbcheck() { local got; got=$(jq -r "$2" <<< "$pb_out" 2>/dev/null)
    [ "$got" = "$3" ] && ok "$1" || no "$1 (got: $got, want: $3)"; }
pbcheck "a prebuilt node does NOT dispatch a builder" '.builds' "build:normal"
pbcheck "no verify.model means NO model key reaches the verifier" '.verifyModels' "absent"
pbcheck "...and is still judged by every lens" '.lenses' 3
pbcheck "a planted defect comes back REJECTED" '.outcome' "rejected"

# verify.model is how a deliberate second opinion is run: same prompts, one
# variable. It must reach EVERY verifier and NO builder -- a model that leaked
# into the builder would change the work being judged, not the judging.
pbm_out=$(node "$TMP/prebuilt.mjs" "$REPO/.claude/harness-core/sprint-batch.mjs" some-model 2>&1)
pbmcheck() { local got; got=$(jq -r "$2" <<< "$pbm_out" 2>/dev/null)
    [ "$got" = "$3" ] && ok "$1" || no "$1 (got: $got, want: $3)"; }
pbmcheck "verify.model reaches every verifier" '.verifyModels' "some-model"
pbmcheck "...and never reaches a builder" '.buildModels' "absent"
# The claimed anchors must survive UNVALIDATED, or a canary cannot claim a green
# it did not earn and the claimed-vs-observed check has nothing to catch.
pbcheck "a prebuilt node's claimed anchors reach the reduce verbatim" '.claimed' 0
pbcheck "...so the claimed-vs-observed disagreement still fires" '.disagreements' 2

# ── integrate ────────────────────────────────────────────────────────────────
#
# Was a `{{INTEGRATE}}` placeholder and three sentences of prose. It is the step
# between "every node passed" and "the thing they add up to passes".
echo
echo "── integrate ──"
IG="$REPO/.claude/harness-core/integrate.sh"

# Rebuild a throwaway repo per scenario — integrate MOVES BRANCHES, so scenarios
# cannot share one.
mk_integ() { # <dir>
    local D="$1"; rm -rf "$D"; mkdir -p "$D/src" "$D/.claude"
    git init -q "$D"; git -C "$D" config user.email t@t.t; git -C "$D" config user.name t
    printf 'a\n' > "$D/src/a.ts"; printf 'b\n' > "$D/src/b.ts"; printf 'c\n' > "$D/src/c.ts"
    cat > "$D/.claude/harness.config.json" <<'JSON'
{ "project": { "name": "i", "mainBranch": "main" }, "queue": { "path": "q.json" },
  "anchors": [ { "id": "ok", "cmd": "test ! -f src/POISON", "cwd": "." } ] }
JSON
    printf 'plan.json\nreport.json\n' > "$D/.gitignore"
    git -C "$D" add -A && git -C "$D" commit -qm init && git -C "$D" branch -M main
    cat > "$D/plan.json" <<'JSON'
{ "nodes": [ { "nodeId": "n1", "wave": 0, "exclusive": false, "files": ["src/a.ts"] },
             { "nodeId": "n2", "wave": 0, "exclusive": false, "files": ["src/b.ts"] },
             { "nodeId": "hw", "wave": 1, "exclusive": true,  "files": ["src/c.ts"] } ] }
JSON
}
# branch <dir> <node> <file> <line>
mk_branch() {
    git -C "$1" checkout -q -b "sprint/b/$2" main
    echo "$4" >> "$1/src/$3.ts"
    git -C "$1" commit -qam "$2"
    git -C "$1" checkout -q main
}
report() { printf '%s\n' "$2" > "$1/report.json"; }

D="$TMP/i1"; mk_integ "$D"
mk_branch "$D" n1 a "// n1"; mk_branch "$D" n2 b "// n2"
report "$D" '{ "warnings": [], "nodes": [
  { "nodeId": "n1", "outcome": "accepted", "branch": "sprint/b/n1" },
  { "nodeId": "n2", "outcome": "accepted", "branch": "sprint/b/n2" } ] }'
ig_out=$( cd "$D" && bash "$IG" main plan.json report.json 2>&1 ); ig_rc=$?
[ $ig_rc -eq 0 ] && ok "merges an all-accepted wave" || no "merges an all-accepted wave"
grep -q "anchors on the merged tree" <<< "$ig_out" \
    && ok "re-runs the anchors on the MERGED tree" || no "re-runs the anchors on the MERGED tree"
[ "$(git -C "$D" rev-list --count main)" -ge 4 ] \
    && ok "the merges actually landed on the base" || no "the merges actually landed on the base"

# REGRESSION. The merges land ON $BASE, so after wave 0 the ref no longer points
# where the batch started and `$BASE...HEAD` compares the merged tree to itself.
# The gate then reports "nothing to check" and exits 0 — green, for a merge it
# never examined. Caught while testing this script; the base is pinned to a SHA.
D="$TMP/i2"; mk_integ "$D"
mk_branch "$D" n1 a "// n1"
mk_branch "$D" n2 c "// undeclared: no node in wave 0 owns src/c.ts"
report "$D" '{ "warnings": [], "nodes": [
  { "nodeId": "n1", "outcome": "accepted", "branch": "sprint/b/n1" },
  { "nodeId": "n2", "outcome": "accepted", "branch": "sprint/b/n2" } ] }'
ig_out=$( cd "$D" && bash "$IG" main plan.json report.json 2>&1 ); ig_rc=$?
[ $ig_rc -ne 0 ] && ok "CATCHES an undeclared path in the merged tree" \
                 || no "CATCHES an undeclared path in the merged tree"
grep -q "src/c.ts" <<< "$ig_out" \
    && ok "names the undeclared path in the merge" || no "names the undeclared path in the merge"

# A report carrying warnings is a report whose numbers nobody stands behind.
D="$TMP/i3"; mk_integ "$D"; mk_branch "$D" n1 a "// n1"
report "$D" '{ "warnings": ["n1: ANCHOR DISAGREEMENT on test"], "nodes": [
  { "nodeId": "n1", "outcome": "accepted", "branch": "sprint/b/n1" } ] }'
ig_out=$( cd "$D" && bash "$IG" main plan.json report.json 2>&1 ); ig_rc=$?
[ $ig_rc -eq 1 ] && ok "REFUSES a report that carries warnings" \
                 || no "REFUSES a report that carries warnings"
[ "$(git -C "$D" rev-list --count main)" -eq 1 ] \
    && ok "a refused integrate leaves the base untouched" || no "a refused integrate leaves the base untouched"

# `unverified` is not `rejected` and it is also not mergeable.
D="$TMP/i4"; mk_integ "$D"; mk_branch "$D" n1 a "// n1"; mk_branch "$D" n2 b "// n2"
report "$D" '{ "warnings": [], "nodes": [
  { "nodeId": "n1", "outcome": "accepted", "branch": "sprint/b/n1" },
  { "nodeId": "n2", "outcome": "unverified", "branch": "sprint/b/n2" } ] }'
ig_out=$( cd "$D" && bash "$IG" main plan.json report.json 2>&1 ); ig_rc=$?
[ $ig_rc -eq 0 ] && ok "merges the accepted node beside an unverified one" \
                 || no "merges the accepted node beside an unverified one"
grep -q "NOT merging" <<< "$ig_out" && ok "says which nodes it skipped and why" \
                                    || no "says which nodes it skipped and why"
git -C "$D" log --oneline main | grep -q "n2" \
    && no "an unverified node is NOT merged" || ok "an unverified node is NOT merged"

# Wave order is the whole reason waves exist.
D="$TMP/i5"; mk_integ "$D"; mk_branch "$D" n1 a "// n1"; mk_branch "$D" hw c "// repo-wide"
report "$D" '{ "warnings": [], "nodes": [
  { "nodeId": "n1", "outcome": "accepted", "branch": "sprint/b/n1" },
  { "nodeId": "hw", "outcome": "accepted", "branch": "sprint/b/hw" } ] }'
ig_out=$( cd "$D" && bash "$IG" main plan.json report.json 2>&1 ); ig_rc=$?
[ $ig_rc -eq 0 ] && ok "merges across waves" || no "merges across waves"
[ "$(grep -n 'wave 0: n1' <<< "$ig_out" | cut -d: -f1)" -lt \
  "$(grep -n 'wave 1: hw' <<< "$ig_out" | cut -d: -f1)" ] \
    && ok "wave 0 merges BEFORE wave 1" || no "wave 0 merges BEFORE wave 1"

# A conflict between two ACCEPTED nodes means the partition was wrong. Abort and
# restore — a hand-resolution is code no builder wrote and no verifier will see.
D="$TMP/i6"; mk_integ "$D"
git -C "$D" checkout -q -b sprint/b/n1 main; printf 'ONE\n' > "$D/src/a.ts"
git -C "$D" commit -qam n1; git -C "$D" checkout -q main
git -C "$D" checkout -q -b sprint/b/n2 main; printf 'TWO\n' > "$D/src/a.ts"
git -C "$D" commit -qam n2; git -C "$D" checkout -q main
report "$D" '{ "warnings": [], "nodes": [
  { "nodeId": "n1", "outcome": "accepted", "branch": "sprint/b/n1" },
  { "nodeId": "n2", "outcome": "accepted", "branch": "sprint/b/n2" } ] }'
ig_out=$( cd "$D" && bash "$IG" main plan.json report.json 2>&1 ); ig_rc=$?
[ $ig_rc -eq 1 ] && ok "ABORTS on a conflict between two accepted nodes" \
                 || no "ABORTS on a conflict between two accepted nodes"
[ -z "$(git -C "$D" status --porcelain)" ] \
    && ok "an aborted merge leaves a clean tree" || no "an aborted merge leaves a clean tree"
grep -q "partition was WRONG" <<< "$ig_out" \
    && ok "says a conflict means the partition was wrong" \
    || no "says a conflict means the partition was wrong"

# Per-node green does not imply merged green.
D="$TMP/i7"; mk_integ "$D"
git -C "$D" checkout -q -b sprint/b/n1 main; touch "$D/src/POISON"
git -C "$D" add -A; git -C "$D" commit -qm n1; git -C "$D" checkout -q main
sed -i 's#"files": \["src/a.ts"\]#"files": ["src/a.ts", "src/POISON"]#' "$D/plan.json"
report "$D" '{ "warnings": [], "nodes": [
  { "nodeId": "n1", "outcome": "accepted", "branch": "sprint/b/n1" } ] }'
ig_out=$( cd "$D" && bash "$IG" main plan.json report.json 2>&1 ); ig_rc=$?
[ $ig_rc -eq 1 ] && ok "FAILS on red anchors on the merged tree" \
                 || no "FAILS on red anchors on the merged tree"
grep -q "RED ANCHORS ON THE MERGED TREE" <<< "$ig_out" \
    && ok "names merged-tree failure as its own class" \
    || no "names merged-tree failure as its own class"

# A generated file is the paired artifact of every file that feeds it, and no
# node's file list can name it. integrate.sh rebuilds it after the scope gate
# (which judges what the BUILDERS changed) and before the anchors.
D="$TMP/i8"; mk_integ "$D"
jq '.regenerate = [{"cmd":"printf \"gen:%s\\n\" \"$(cat src/a.ts)\" > src/GENERATED","cwd":"."}]' \
    "$D/.claude/harness.config.json" > "$D/.claude/tmp.json" && mv "$D/.claude/tmp.json" "$D/.claude/harness.config.json"
printf 'gen:a\n' > "$D/src/GENERATED"
git -C "$D" add -A && git -C "$D" commit -qm "add generated artifact"
mk_branch "$D" n1 a "// n1 changes the source the artifact is generated from"
report "$D" '{ "warnings": [], "nodes": [
  { "nodeId": "n1", "outcome": "accepted", "branch": "sprint/b/n1" } ] }'
ig_out=$( cd "$D" && bash "$IG" main plan.json report.json 2>&1 ); ig_rc=$?
[ $ig_rc -eq 0 ] && ok "integrates with a regenerate step" || no "integrates with a regenerate step"
grep -q "regenerating 1 artifact" <<< "$ig_out" \
    && ok "runs the regenerate commands" || no "runs the regenerate commands"
grep -q "regeneration changed 1 file" <<< "$ig_out" \
    && ok "notices the generated file moved" || no "notices the generated file moved"
grep -q "n1 changes the source" "$D/src/GENERATED" \
    && ok "the regenerated artifact reflects the merged source" \
    || no "the regenerated artifact reflects the merged source"
[ -z "$(git -C "$D" status --porcelain)" ] \
    && ok "the regeneration is COMMITTED with the merge" \
    || no "the regeneration is COMMITTED with the merge"
# The scope gate must not blame the batch for a file this script wrote.
grep -q "SCOPE VIOLATION" <<< "$ig_out" \
    && no "regeneration does not trip the scope gate" \
    || ok "regeneration does not trip the scope gate"

# A failing regenerate command must stop before the anchors run on a tree whose
# generated files are unknown.
D="$TMP/i9"; mk_integ "$D"
jq '.regenerate = [{"cmd":"exit 3","cwd":"."}]' \
    "$D/.claude/harness.config.json" > "$D/.claude/tmp.json" && mv "$D/.claude/tmp.json" "$D/.claude/harness.config.json"
git -C "$D" add -A && git -C "$D" commit -qm cfg
mk_branch "$D" n1 a "// n1"
report "$D" '{ "warnings": [], "nodes": [
  { "nodeId": "n1", "outcome": "accepted", "branch": "sprint/b/n1" } ] }'
ig_out=$( cd "$D" && bash "$IG" main plan.json report.json 2>&1 ); ig_rc=$?
[ $ig_rc -eq 1 ] && ok "a failing regenerate stops the integrate" \
                 || no "a failing regenerate stops the integrate"
grep -q "anchors on the merged tree" <<< "$ig_out" \
    && no "...before the anchors run" || ok "...before the anchors run"

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

# A FRESHLY CUT branch points at the same commit as the base it came from, and
# `git log -1 --format=%ct` is identical for both — so which one sorts first is
# arbitrary. A name-only comparison reports the correct base as "not the newest"
# and goes red on a tree that is in exactly the right state: scar #17 again, one
# step later. Standing on either is equivalent for what the NEXT commit is based
# on, so both must be green.
git -C "$STK" checkout -q -b chore/next feat/unpushed
stk_fresh=$(cd "$STK" && SPRINT_HARNESS_CONFIG="$TMP/stk-default.json" \
    ./.claude/harness-core/preflight.sh 2>&1)
stk_fresh_rc=$?
! grep -q "UNPUSHED WORK EXISTS" <<< "$stk_fresh" \
    && ok "preflight is GREEN on a branch cut from the stacking base (same commit)" \
    || no "preflight is GREEN on a branch cut from the stacking base (same commit)"
[ "$stk_fresh_rc" -eq 0 ] \
    && ok "preflight EXITS 0 on a same-commit stacking base" \
    || no "preflight EXITS 0 on a same-commit stacking base (got $stk_fresh_rc)"
git -C "$STK" checkout -q feat/unpushed
git -C "$STK" branch -qD chore/next

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

# ── serialised anchors (SCARS #35) ──────────────────────────────────────────
echo
echo "── serialised anchors ──"

# The lock is the whole point: two runs must not overlap. Each writes a marker,
# sleeps, then checks nobody else claimed it meanwhile.
cat > "$TMP/overlap.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" > "$1/holder"
sleep 1
[ "$(cat "$1/holder")" = "$$" ] || echo "OVERLAP" >> "$1/violations"
SH
chmod +x "$TMP/overlap.sh"
mkdir -p "$TMP/lockprobe"
: > "$TMP/lockprobe/violations"
for _ in 1 2 3 4; do
    "$HERE/core/serialize.sh" selftest-overlap "$TMP/overlap.sh" "$TMP/lockprobe" &
done
wait
[ ! -s "$TMP/lockprobe/violations" ] \
    && ok "serialize.sh actually serialises concurrent runs" \
    || no "serialize.sh actually serialises concurrent runs"

# A lock that alters what an anchor reports is worse than no lock.
"$HERE/core/serialize.sh" selftest-rc sh -c 'exit 3'; [ $? -eq 3 ] \
    && ok "serialize.sh propagates the wrapped exit code" \
    || no "serialize.sh propagates the wrapped exit code"
"$HERE/core/serialize.sh" selftest-rc true; [ $? -eq 0 ] \
    && ok "serialize.sh propagates success" \
    || no "serialize.sh propagates success"

"$HERE/core/serialize.sh" 2>/dev/null; [ $? -eq 2 ] \
    && ok "serialize.sh refuses a call with no command" \
    || no "serialize.sh refuses a call with no command"

# The rendered command must hop out of the anchor's cwd to reach the wrapper,
# or the builder runs `./.claude/...` from web/ and gets a 127 that reads as a
# broken node rather than a broken config.
render_anchor() {
    node -e '
const fs=require("fs");
const src=fs.readFileSync(process.argv[1],"utf8").replace(/^export const meta/m,"const meta");
const plan=JSON.parse(process.argv[2]);
// Capture the PROMPT rather than just watching for a throw: what matters is the
// exact string the builder is handed, including the hop out of the anchor cwd.
const agent=(prompt)=>{ console.log(prompt); throw new Error("stop-after-render"); };
const f=new Function("args","agent","parallel","pipeline","log","phase","budget","workflow",
  "return (async()=>{"+src+"})()");
f(plan,agent,(fns)=>Promise.all(fns.map(fn=>fn())),()=>{},()=>{},()=>{},{},()=>{})
  .then(()=>process.exit(0))
  .catch(e=>{ console.error(e.message); process.exit(0); });
' "$HERE/core/sprint-batch.mjs" "$1" 2>&1
}
mkplan() {
    cat <<JSON
{ "batchName":"b","wave":0,"baseBranch":"main",
  "nodes":[{"nodeId":"N","items":[{"id":"A","title":"t","source":"s","severity":"low","files":["a.ts"],"newFiles":[],"detail":"d"}],
            "files":["a.ts"],"wave":0,"serial":false,"exclusive":false,"lane":null,"reason":"x"}],
  "harness":{ "anchors":[{"id":"test","cmd":"npm test","cwd":"web","always":true,"whenTouches":null,"serialize":true}],
  "setup":[],"lenses":["anchors"],"agents":{"builder":"b","verifier":"v"},
  "branchPrefix":"sprint","mainBranch":"main","scopeGate":"sg","pairedArtifacts":[]$1 } }
JSON
}

# The hop is the part that bites: an anchor with cwd "web" must reach the wrapper
# at ../.claude/..., or the builder runs it from web/, gets a 127, and reports a
# number that reads as "this node is broken" rather than "this config is wrong".
# cwdHop is lifted straight out of the source so the test cannot drift from it.
hop=$(node -e '
const fs=require("fs");
const src=fs.readFileSync(process.argv[1],"utf8");
const m=src.match(/const cwdHop = [\s\S]*?\n};/);
if(!m){ console.log("NOTFOUND"); process.exit(0); }
const cwdHop=eval("("+m[0].replace(/^const cwdHop = /,"").replace(/;$/,"")+")");
console.log([".","","web","a/b"].map(c=>c+"=>"+cwdHop(c)).join(" "));
' "$HERE/core/sprint-batch.mjs")
[ "$hop" = ".=>./ =>./ web=>../ a/b=>../../" ] \
    && ok "cwdHop reaches the repo root from any anchor cwd" \
    || no "cwdHop reaches the repo root from any anchor cwd ($hop)"


# Silently dropping the lock is the dangerous failure: it looks exactly like an
# anchor that never needed one, until the next wide wave goes red at random.
out=$(render_anchor "$(mkplan '')")
grep -q "no harness.serializer" <<< "$out" \
    && ok "sprint-batch REFUSES serialize:true with no serializer path" \
    || no "sprint-batch REFUSES serialize:true with no serializer path"

echo
echo "════════════════════════"
echo "$pass passed, $fail failed"
exit $((fail > 0))
