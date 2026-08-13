#!/usr/bin/env bash
#
# "If you changed X, you must also change Y" — as an EXIT CODE, with an
# auditable waiver.
#
#     core/paired-artifact-gate.sh [base-ref]     # default: project.mainBranch
#
# Exits 0 if every changed source file has a matching changed counterpart (or a
# recorded waiver), 1 otherwise. Prints the exact filename it wants.
#
# PROJECT-AGNOSTIC: the rules come from harness.config.json `pairedArtifacts`.
# The canonical rule is component -> component test, but the same shape covers
# handler -> integration test, migration -> rollback, proto -> generated client,
# public API -> changelog entry.
#
# WHY A SCRIPT AND NOT A RULE IN THE AGENT CONTRACT. "Write a test with the fix"
# sat in a builder contract as PROSE for a week and produced three test files
# across fifty-one components. The verifier contract is explicit that "only an
# exit code is" an answer — so this is the shape that actually binds: the builder
# runs it as an anchor, and an independent verifier re-runs it.
#
# THE WAIVER IS DELIBERATE AND AUDITABLE. Some changes genuinely should not carry
# a counterpart — a pure class swap, a copy edit, a file that only re-exports.
# Those are waived by a trailer in the node's commit message:
#
#     no-test(OrderActions): class-only change, no behaviour to assert
#
# so an exemption is a line in the history someone can grep, review and argue
# with, rather than a silent omission. A BLANKET waiver is not supported on
# purpose — each file must be named.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "error: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2

CFG=""
for c in "${SPRINT_HARNESS_CONFIG:-}" "$ROOT/.claude/harness.config.json" "$ROOT/harness.config.json"; do
    [ -n "$c" ] && [ -f "$c" ] && { CFG="$c"; break; }
done
[ -n "$CFG" ] || { echo "error: no harness.config.json found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

rule_count=$(jq '.pairedArtifacts | length // 0' "$CFG")
if [ "$rule_count" -eq 0 ]; then
    echo "no pairedArtifacts rules configured — nothing to check"
    exit 0
fi

BASE="${1:-$(jq -r '.project.mainBranch // "main"' "$CFG")}"
if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "error: base ref '$BASE' does not exist" >&2
    exit 2
fi

# Three-dot: what THIS branch changed since it diverged, not what the base did
# after. A two-dot range would flag files the base moved underneath you.
changed=$(git diff --name-only "$BASE...HEAD")
[ -z "$changed" ] && { echo "no changes against $BASE — nothing to check"; exit 0; }

# Every commit message on this branch, for waiver lookup. A waiver only counts
# once it is COMMITTED — run this before you rely on it.
messages=$(git log --format='%B' "$BASE..HEAD")

fail=0
checked=0

for idx in $(seq 0 $((rule_count - 1))); do
    rule=$(jq -c ".pairedArtifacts[$idx]" "$CFG")
    rid=$(jq -r '.id // "rule"'        <<< "$rule")
    src_dir=$(jq -r '.srcDir'          <<< "$rule")
    src_ext=$(jq -r '.srcExt'          <<< "$rule")
    pair_tpl=$(jq -r '.pairPath'       <<< "$rule")
    waiver_tpl=$(jq -r '.waiverTrailer // "no-test({name})"' <<< "$rule")
    mapfile -t excludes < <(jq -r '.excludeDirs[]? // empty' <<< "$rule")

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in "$src_dir"/*"$src_ext") ;; *) continue ;; esac

        skip=0
        for ex in "${excludes[@]:-}"; do
            [ -n "$ex" ] || continue
            case "$f" in "$ex"/*) skip=1; break ;; esac
        done
        [ "$skip" -eq 1 ] && continue

        # A DELETED source file owes nothing.
        [ -f "$f" ] || continue

        name=$(basename "$f" "$src_ext")
        pair_file=${pair_tpl//\{name\}/$name}
        waiver=${waiver_tpl//\{name\}/$name}
        checked=$((checked + 1))

        # ⚠ HERESTRINGS, NOT PIPES, AND THIS IS NOT STYLE.
        #
        # `set -o pipefail` is on. `grep -q` exits the instant it matches, which
        # closes the pipe and kills the writer with SIGPIPE — status 141 — and
        # pipefail then reports the whole pipeline as FAILED even though grep
        # MATCHED. The effect was a silently ignored waiver: a file with a
        # recorded waiver was reported as "no counterpart changed" and the anchor
        # exited 1.
        #
        # It fails CLOSED (a pass is never invented), but it breaks the gate —
        # and whether SIGPIPE lands at all depends on how much the writer got to
        # flush first, so it presented as INTERMITTENT. A herestring has no
        # second process and no pipe.
        if grep -qxF "$pair_file" <<< "$changed"; then
            printf '  \033[32m✓\033[0m %-28s %s\n' "$name" "$pair_file"
            continue
        fi

        # Escape the waiver for use as a regex — a trailer template like
        # "no-test({name})" contains parens that are regex metacharacters.
        waiver_re=$(sed 's/[][(){}.*+?^$|\\]/\\&/g' <<< "$waiver")
        if grep -qE "^${waiver_re}:[[:space:]]*\S" <<< "$messages"; then
            reason=$(grep -E "^${waiver_re}:" <<< "$messages" | head -1)
            printf '  \033[33m~\033[0m %-28s WAIVED — %s\n' "$name" "${reason#"$waiver": }"
            continue
        fi

        printf '  \033[31m✗\033[0m %-28s [%s] no counterpart changed\n' "$name" "$rid"
        printf '      wanted: %s\n' "$pair_file"
        printf '      or waive: %s: <reason>\n' "$waiver"
        fail=1
    done <<< "$changed"
done

if [ "$checked" -eq 0 ]; then
    echo "no matching source files changed against $BASE — nothing to check"
    exit 0
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "OK — every changed source file has a counterpart or a recorded waiver."
else
    echo "FAILED — a source file changed with no counterpart in the same node."
    echo
    jq -r '.pairedArtifacts[]? | select(.help) | "  [\(.id)] \(.help)"' "$CFG"
    cat <<'MSG'

  Write the counterpart so it FAILS against the old behaviour. A test that passes
  both before and after the fix has asserted nothing, and it will be read later
  as proof the bug cannot come back.
MSG
fi
exit "$fail"
