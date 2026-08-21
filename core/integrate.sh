#!/usr/bin/env bash
#
# Merge an accepted batch in WAVE ORDER, and re-run the anchors on the merged
# tree. No model anywhere in it.
#
#     core/integrate.sh <base-branch> <plan.json> <report.json> [--dry-run]
#
# <report.json> is what core/sprint-batch.mjs returned. If you ran more than one
# wave, concatenate the reports into one object with a `nodes` array, or pass
# each wave's report in turn — this script only merges nodes it can see.
#
# Exits 0 when every accepted node merged and the anchors were green on the
# result, 1 on a refusal or a red anchor, 2 on a usage or environment error.
#
# WHY THIS IS A SCRIPT. It was three sentences in a SKILL.md template:
#
#     "Merge accepted branches in wave order, then re-run the anchors on the
#      merged tree — per-node green does not imply merged green."
#
# followed by a `{{INTEGRATE}}` placeholder. Scar #7 is that a rule in a prompt
# is a suggestion, and this particular rule is the one standing between "every
# node passed" and "the thing they add up to passes". Four ways a human doing
# this by hand gets it wrong, all of them silent:
#
#   - merging a node that was `unverified` rather than `accepted`, because the
#     report is long and both look like "not rejected"
#   - merging wave 1 before wave 0, which is the entire reason waves exist
#   - resolving a merge conflict by hand, in the tree, with no verifier left to
#     look at what the resolution did
#   - declaring victory on per-node green without ever running the anchors on
#     the merged result
#
# Each of those is an exit code here instead.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "error: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

BASE="${1:-}"; PLAN="${2:-}"; REPORT="${3:-}"; DRY="${4:-}"
if [ -z "$BASE" ] || [ -z "$PLAN" ] || [ -z "$REPORT" ]; then
    sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
[ -f "$PLAN" ]   || { echo "error: no plan file at '$PLAN'" >&2; exit 2; }
[ -f "$REPORT" ] || { echo "error: no report file at '$REPORT'" >&2; exit 2; }
git rev-parse --verify --quiet "$BASE" >/dev/null \
    || { echo "error: base ref '$BASE' does not exist" >&2; exit 2; }

CFG=""
for c in "${SPRINT_HARNESS_CONFIG:-}" "$ROOT/.claude/harness.config.json" "$ROOT/harness.config.json"; do
    [ -n "$c" ] && [ -f "$c" ] && { CFG="$c"; break; }
done
[ -n "$CFG" ] || { echo "error: no harness.config.json found" >&2; exit 2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCOPE_GATE="$HERE/scope-gate.sh"

DRY_RUN=0
[ "$DRY" = "--dry-run" ] && DRY_RUN=1

# A dirty tree turns a failed merge into an unrecoverable mess, and the whole
# point of this script is that every failure leaves you somewhere you can reason
# about.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is not clean. Commit or stash before integrating." >&2
    exit 2
fi

# ── refuse anything that is not `accepted` ───────────────────────────────────
#
# `unverified` is NOT `rejected` and it is also NOT mergeable. A node whose
# verifier crashed has not been judged, and merging it silently converts "nobody
# looked" into "it shipped". That is scar #2 pointed at the tree instead of the
# report.
NOT_ACCEPTED=$(jq -r '[.nodes[]|select(.outcome!="accepted")|"\(.nodeId) [\(.outcome)]"]|.[]' "$REPORT")
if [ -n "$NOT_ACCEPTED" ]; then
    echo "NOT merging $(printf '%s\n' "$NOT_ACCEPTED" | wc -l) node(s) that were not accepted:"
    while IFS= read -r n; do [ -n "$n" ] && echo "  – $n"; done <<< "$NOT_ACCEPTED"
    echo
fi

# Warnings on the report are not advisory here. An anchor disagreement or a lost
# node means the report itself is not trustworthy, and merging on top of it is
# merging on top of a number nobody stands behind.
WARN_COUNT=$(jq -r '(.warnings // [])|length' "$REPORT")
if [ "$WARN_COUNT" != "0" ]; then
    echo "REFUSING: the batch report carries $WARN_COUNT warning(s)." >&2
    jq -r '(.warnings // [])[]' "$REPORT" | sed 's/^/  ! /' >&2
    echo >&2
    echo "  Resolve these before integrating. A warning means some number in this report" >&2
    echo "  is one nobody stands behind — merging on top of it buries the question." >&2
    exit 1
fi

ACCEPTED=$(jq -r '[.nodes[]|select(.outcome=="accepted")|.nodeId]|.[]' "$REPORT")
if [ -z "$ACCEPTED" ]; then
    echo "nothing accepted in this report — nothing to integrate."
    exit 0
fi

# ── anchors, as they will be run on the merged tree ──────────────────────────
run_anchors() {
    local label="$1" rc=0 n
    n=$(jq '.anchors|length' "$CFG")
    echo "  anchors on $label:"
    for ((k = 0; k < n; k++)); do
        local id cmd cwd out code
        id=$(jq -r ".anchors[$k].id" "$CFG")
        cmd=$(jq -r ".anchors[$k].cmd" "$CFG")
        cwd=$(jq -r ".anchors[$k].cwd // \".\"" "$CFG")
        out=$( cd "$ROOT/$cwd" && eval "$cmd" 2>&1 ); code=$?
        if [ $code -eq 0 ]; then
            echo "    ✓ $id (exit 0)"
        else
            echo "    ✗ $id (exit $code)" >&2
            printf '%s\n' "$out" | tail -20 | sed 's/^/        /' >&2
            rc=1
        fi
    done
    return $rc
}

# ── merge, wave by wave ──────────────────────────────────────────────────────
START=$(git rev-parse --abbrev-ref HEAD)

# PIN THE BASE COMMIT BEFORE ANYTHING MOVES.
#
# The merges below land ON $BASE, so once wave 0 is in, the ref `$BASE` no longer
# points at where the batch started — it points at the merge. Diffing `$BASE...HEAD`
# after that compares the merged tree against itself, `git diff` returns nothing,
# and the scope gate reports "nothing to check" and exits 0.
#
# That is a gate that passes because it was asked the wrong question, which is
# indistinguishable in the output from a gate that passed because the tree was
# clean. Caught while testing this script: the happy path printed a green scope
# line for a merge it had never actually examined.
BASE_SHA=$(git rev-parse --verify "$BASE^{commit}")

echo "integrating onto $BASE (from $START), base pinned at ${BASE_SHA:0:9}"
[ $DRY_RUN -eq 1 ] && echo "(dry run — no merges will be made)"

git checkout -q "$BASE" || { echo "error: cannot check out $BASE" >&2; exit 2; }

WAVES=$(jq -r '[.nodes[].wave]|unique|.[]' "$PLAN" | sort -n)
MERGED=0

for w in $WAVES; do
    # Only the accepted nodes of THIS wave, in the plan's own order.
    IN_WAVE=$(jq -r --argjson w "$w" '[.nodes[]|select(.wave==$w)|.nodeId]|.[]' "$PLAN")
    WAVE_MERGED=0

    for nodeId in $(printf '%s\n' "$IN_WAVE"); do
        printf '%s\n' "$ACCEPTED" | grep -qxF "$nodeId" || continue
        branch=$(jq -r --arg n "$nodeId" '.nodes[]|select(.nodeId==$n)|.branch' "$REPORT")
        if [ -z "$branch" ] || [ "$branch" = "null" ]; then
            echo "error: node $nodeId is accepted but the report has no branch for it" >&2
            git checkout -q "$START"; exit 1
        fi
        if ! git rev-parse --verify --quiet "$branch" >/dev/null; then
            echo "error: branch '$branch' for node $nodeId does not exist" >&2
            git checkout -q "$START"; exit 1
        fi

        echo
        echo "── wave $w: $nodeId  ($branch)"
        if [ $DRY_RUN -eq 1 ]; then
            echo "  would merge --no-ff"
            WAVE_MERGED=$((WAVE_MERGED + 1)); MERGED=$((MERGED + 1))
            continue
        fi

        # --no-ff so every node stays one identifiable merge in the history, and
        # --no-edit so this never blocks on an editor.
        if ! git merge --no-ff --no-edit "$branch" >/dev/null 2>&1; then
            echo "  CONFLICT merging $nodeId." >&2
            git merge --abort 2>/dev/null
            echo >&2
            echo "  Aborted, tree restored. A conflict here means two accepted nodes wrote" >&2
            echo "  the same lines, which means the partition was WRONG — they should have" >&2
            echo "  been one serial node. Do not hand-resolve it: the resolution is code" >&2
            echo "  that no builder wrote and no verifier will ever see." >&2
            echo "  Re-partition those items together and re-run the wave." >&2
            git checkout -q "$START"
            exit 1
        fi
        echo "  merged"
        WAVE_MERGED=$((WAVE_MERGED + 1)); MERGED=$((MERGED + 1))
    done

    [ "$WAVE_MERGED" -eq 0 ] && continue
    [ $DRY_RUN -eq 1 ] && continue
    # PER-NODE GREEN DOES NOT IMPLY MERGED GREEN. This is the whole reason the
    # step exists: each branch was verified alone, against the base, by an agent
    # that never saw the other branches in its wave.
    echo
    echo "── wave $w merged ($WAVE_MERGED node(s)) — checking the merged tree"
    if ! "$SCOPE_GATE" "$BASE_SHA" "$PLAN" --wave "$w" >/dev/null 2>&1; then
        "$SCOPE_GATE" "$BASE_SHA" "$PLAN" --wave "$w" >&2
        echo "  The merged tree contains a path no node in this wave declared." >&2
        git checkout -q "$START"; exit 1
    fi
    echo "  ✓ scope: every changed path was declared by a node in wave $w"

    # REGENERATE AFTER THE SCOPE GATE AND BEFORE THE ANCHORS, EVERY TIME.
    #
    # The order is not arbitrary. The scope gate judges what the BUILDERS changed,
    # so it has to run before this step adds files no node declared — otherwise
    # every batch with a generated artifact reports a scope violation for a file
    # this script wrote itself. The anchors run after, because they are supposed
    # to see the regenerated tree.
    #
    # A generated file is the paired artifact of EVERY file that feeds it, and no
    # file list can name it. So no node regenerates it, no anchor checks it, and
    # every anchor is green — on the node and on the merged tree — while the
    # committed artifact silently stops matching the source. CI is then the first
    # thing that notices, after the merge, on the pushed PR.
    #
    # A pairedArtifacts rule is the WRONG fix: most edits to a source do not move
    # the generated file, so a rule demanding it on every node is noise that gets
    # waived by habit. It belongs here, once, where the whole batch exists in one
    # tree. Watched happen on a live project: a builder rewrote a route docstring,
    # the framework publishes docstrings as the OpenAPI description, and the
    # committed schema diverged with everything green.
    REGEN_N=$(jq '(.regenerate // [])|length' "$CFG")
    if [ "$REGEN_N" != "0" ]; then
        echo
        echo "── regenerating $REGEN_N artifact(s) before the anchors"
        for ((k = 0; k < REGEN_N; k++)); do
            rcmd=$(jq -r ".regenerate[$k].cmd" "$CFG")
            rcwd=$(jq -r ".regenerate[$k].cwd // \".\"" "$CFG")
            rout=$( cd "$ROOT/$rcwd" && eval "$rcmd" 2>&1 ); rcode=$?
            if [ $rcode -ne 0 ]; then
                echo "  ✗ regenerate failed (exit $rcode): $rcmd" >&2
                printf '%s\n' "$rout" | tail -20 | sed 's/^/      /' >&2
                echo "  Not running the anchors on a tree whose generated files are unknown." >&2
                exit 1
            fi
            echo "  ✓ $rcmd"
        done
        REGEN_DIFF=$(git status --porcelain)
        if [ -n "$REGEN_DIFF" ]; then
            # NOT a defect. A source edit that moves a generated file is exactly
            # what this step exists to catch, and the regeneration ships with the
            # merge.
            echo "  regeneration changed $(printf '%s\n' "$REGEN_DIFF" | wc -l) file(s) — committing with the merge:"
            printf '%s\n' "$REGEN_DIFF" | sed 's/^/    /'
            git add -A
            git commit -qm "chore: regenerate artifacts after wave $w

The generated files are the paired artifact of every source that feeds them and
no node's file list can name them, so integrate.sh rebuilds them before running
the anchors on the merged tree."
        else
            echo "  no change — the committed artifacts already match the merged sources"
        fi
    fi


    if ! run_anchors "the merged tree after wave $w"; then
        echo >&2
        echo "  RED ANCHORS ON THE MERGED TREE. Every node in this wave was green alone." >&2
        echo "  Whatever this is, no single verifier could have seen it — it only exists" >&2
        echo "  in the combination. Do not push. $BASE now holds the merge; reset it" >&2
        echo "  with: git reset --hard $BASE_SHA" >&2
        exit 1
    fi
done

echo
if [ $DRY_RUN -eq 1 ]; then
    echo "dry run: $MERGED node(s) would merge across $(printf '%s\n' "$WAVES" | wc -w) wave(s)"
    git checkout -q "$START"
    exit 0
fi

echo "integrated $MERGED node(s) onto $BASE; anchors green on the merged tree."
echo
echo "NOT DONE YET. A green anchor set is not evidence the change is RIGHT — it is"
echo "evidence it is not obviously broken. The human gate is next: exercise the"
echo "actual behaviour before this becomes a PR."
exit 0
