#!/usr/bin/env bash
#
# "This node may only touch the files it owns" — as an EXIT CODE.
#
#     core/scope-gate.sh <base-ref> <plan.json> <nodeId>
#     core/scope-gate.sh <base-ref> --files "a.ts b.ts"     # explicit list
#     core/scope-gate.sh <base-ref> <plan.json> --wave 0    # the merged tree
#
# Exits 0 if every path changed against <base-ref> is declared by the node (or
# by every node in the wave), 1 if anything else was touched, 2 on a usage or
# environment error. Prints the exact undeclared paths.
#
# WHY A SCRIPT AND NOT A RULE IN THE CONTRACT. The same sentence was written
# three times in three different places:
#
#   builder contract  "do not touch files outside this node's list"
#   verifier intent   "a file outside the list is an automatic reject"
#   integrate step    "merge accepted branches in wave order"
#
# All three are prose, and scar #7 is that a rule in a prompt is a suggestion.
# It is also the one question in the intent lens that is not a judgement call:
# it is a set difference, and paying an LLM to re-derive a set difference is
# both slower and less reliable than `comm`. The lens keeps the semantic half —
# does the change do what the item asked — and loses the arithmetic.
#
# EXCLUSIVE NODES ARE EXEMPT, and that is not a loophole. A repo-wide node's
# whole definition is "rewrites a convention across files the queue cannot
# enumerate" — its declared `files` list is known-incomplete by construction, so
# gating it against that list would reject every repo-wide node on sight. It is
# made safe by running ALONE in its own wave, not by a file list. The gate says
# so out loud rather than silently passing.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "error: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

usage() {
    sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

BASE="${1:-}"; shift || usage
[ -n "$BASE" ] || usage
git rev-parse --verify --quiet "$BASE" >/dev/null \
    || { echo "error: base ref '$BASE' does not exist" >&2; exit 2; }

DECLARED="" LABEL="" EXCLUSIVE=0

if [ "${1:-}" = "--files" ]; then
    shift
    DECLARED=$(printf '%s\n' ${1:-} | sed '/^$/d' | sort -u)
    LABEL="the given file list"
else
    PLAN="${1:-}"; shift || usage
    [ -f "$PLAN" ] || { echo "error: no plan file at '$PLAN'" >&2; exit 2; }

    if [ "${1:-}" = "--wave" ]; then
        WAVE="${2:-0}"
        # The merged tree carries every node in the wave, so the allowed set is
        # the UNION of what that wave declared. Per-node green does not imply
        # merged green, and a merge that dragged in a path no node declared is
        # exactly the case this catches.
        DECLARED=$(jq -r --argjson w "$WAVE" \
            '[.nodes[]|select(.wave==$w)|.files[]]|unique[]' "$PLAN" | sort -u)
        LABEL="wave $WAVE (union of $(jq -r --argjson w "$WAVE" '[.nodes[]|select(.wave==$w)]|length' "$PLAN") node(s))"
        # A wave containing an exclusive node cannot be gated on a file list
        # either — the same known-incomplete list, merged.
        if [ "$(jq -r --argjson w "$WAVE" '[.nodes[]|select(.wave==$w)|select(.exclusive)]|length' "$PLAN")" != "0" ]; then
            EXCLUSIVE=1
        fi
    else
        NODE="${1:-}"; shift || usage
        [ -n "$NODE" ] || usage
        if [ "$(jq -r --arg n "$NODE" '[.nodes[]|select(.nodeId==$n)]|length' "$PLAN")" = "0" ]; then
            echo "error: no node with nodeId '$NODE' in $PLAN" >&2
            echo "       nodes: $(jq -r '[.nodes[].nodeId]|join(", ")' "$PLAN")" >&2
            exit 2
        fi
        DECLARED=$(jq -r --arg n "$NODE" '.nodes[]|select(.nodeId==$n)|.files[]' "$PLAN" | sort -u)
        LABEL="node $NODE"
        [ "$(jq -r --arg n "$NODE" '.nodes[]|select(.nodeId==$n)|.exclusive' "$PLAN")" = "true" ] && EXCLUSIVE=1
    fi
fi

if [ "$EXCLUSIVE" -eq 1 ]; then
    echo "EXEMPT: $LABEL is exclusive (repo-wide)."
    echo "  A repo-wide node's declared file list is incomplete BY CONSTRUCTION — it"
    echo "  rewrites a convention across files the queue could not enumerate. It is made"
    echo "  safe by running alone in its own wave, not by a file list, so there is no"
    echo "  set to gate against here. Read the diff."
    exit 0
fi

# Three-dot: what this branch changed since it diverged from the base, not what
# the base did afterwards. Scar #4 applies to the comparison below — capture
# into variables and match with herestrings; do not pipe into `grep -q` with
# pipefail on.
CHANGED=$(git diff --name-only "$BASE...HEAD" | sed '/^$/d' | sort -u)

if [ -z "$CHANGED" ]; then
    echo "no changes against $BASE — nothing to check"
    exit 0
fi

UNDECLARED=$(comm -23 <(printf '%s\n' "$CHANGED") <(printf '%s\n' "$DECLARED"))

if [ -n "$UNDECLARED" ]; then
    echo "SCOPE VIOLATION: $LABEL changed $(printf '%s\n' "$UNDECLARED" | wc -l) file(s) it does not own." >&2
    while IFS= read -r f; do [ -n "$f" ] && echo "  + $f" >&2; done <<< "$UNDECLARED"
    echo >&2
    echo "  Declared:" >&2
    while IFS= read -r f; do [ -n "$f" ] && echo "    $f" >&2; done <<< "$DECLARED"
    echo >&2
    echo "  This is not a style rule. Two builders in separate worktrees are safe only" >&2
    echo "  because the partitioner proved their file sets are disjoint. A builder that" >&2
    echo "  edits an undeclared file voids that proof for the whole wave." >&2
    echo >&2
    echo "  If the fix genuinely needed those files, that is an \`outOfScope\` report and" >&2
    echo "  a re-partition — not an edit." >&2
    exit 1
fi

echo "scope ok: $(printf '%s\n' "$CHANGED" | wc -l) changed file(s), all declared by $LABEL"
exit 0
