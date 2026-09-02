#!/usr/bin/env bash
#
# Run one command while holding a named, host-wide lock.
#
#     core/serialize.sh <lock-name> <command> [args...]
#
# WHY THIS EXISTS. A wave fans out N nodes, and each node is a builder plus an
# `anchors` verifier that re-runs every anchor itself. A heavyweight suite is
# therefore started up to 2N times at once on ONE machine, and most runners size
# their own worker pool to the core count — so N concurrent runs oversubscribe the
# box by roughly N times before a single test executes.
#
# Measured on a 12-core box, 2026-09-02: eight concurrent `npm test` runs against a
# tree that is 972/972 green alone produced 8/8 RED, 28-40 failures each, and every
# one of the 200 failures was `Test timed out in 5000ms`. Zero assertion failures.
# The suite was correct; the ANCHOR was not, because it answered a question about
# machine load rather than about the code.
#
# That is the specific way an anchor stops being worth having. A red that a builder
# and a verifier can disagree about at random manufactures ANCHOR DISAGREEMENTs —
# the loudest signal this harness produces — and the signal only works while it is
# rare. Worse, once an anchor is known to go red under load, its reds get explained
# away, which is the habit that destroys a check.
#
# Serialising costs wall-clock and buys a number two agents can both stand behind.
# For an anchor that is the right trade every time: the whole system is built on
# exit codes somebody watched happen.
#
# THE LOCK IS ADVISORY AND HOST-WIDE, keyed by name only, so every worktree on the
# box queues on the same lock — which is the point, since they share the CPU.
#
# The wrapped command's exit code is propagated unchanged. A lock is not allowed to
# change what an anchor reports; it only changes when the anchor runs.

set -uo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: serialize.sh <lock-name> <command> [args...]" >&2
    exit 2
fi

NAME=$1
shift

case "$NAME" in
    */*|"") echo "serialize.sh: lock name must not be empty or contain '/'" >&2; exit 2 ;;
esac

TMP="${TMPDIR:-/tmp}"
TMP="${TMP%/}"

# How long to wait for the lock before giving up. A wave of 16 runs of a 25s suite
# needs ~7 minutes; 30 is generous without hanging a batch forever on a stale lock.
WAIT_SECS="${SPRINT_LOCK_TIMEOUT:-1800}"

# ── preferred path: flock(1) ────────────────────────────────────────────────────
# Held on a file descriptor by the kernel, so a killed agent releases it. That
# matters more than it sounds: an orphaned lock in a batch of 32 agents would
# otherwise strand every node still queued behind it.
if command -v flock >/dev/null 2>&1; then
    exec flock -w "$WAIT_SECS" "$TMP/sprint-anchor-$NAME.lock" "$@"
fi

# ── fallback: mkdir spinlock ────────────────────────────────────────────────────
# flock is util-linux and is NOT present on macOS, which is a first-class target
# here. mkdir is atomic on every POSIX filesystem, which is the whole reason it is
# the fallback rather than `[ -e ] && touch`.
#
# The cost of the fallback is that a lock is NOT released by the kernel when its
# holder dies, so it carries an explicit staleness check. A lock whose owning PID
# is gone is broken rather than waited on — an anchor that hangs for 30 minutes
# because an unrelated agent was killed is indistinguishable from a hung test, and
# the harness would report the wrong thing about the wrong node.
LOCKDIR="$TMP/sprint-anchor-$NAME.lockdir"
DEADLINE=$(( $(date +%s) + WAIT_SECS ))

while :; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo "$$" > "$LOCKDIR/pid"
        # Release on every exit path, including a signal — otherwise a Ctrl-C
        # leaves a lock that only the staleness check can clear, 30 minutes later.
        trap 'rm -rf "$LOCKDIR"' EXIT INT TERM
        break
    fi

    owner=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
        echo "serialize.sh: breaking stale lock '$NAME' (pid $owner is gone)" >&2
        rm -rf "$LOCKDIR"
        continue
    fi

    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        echo "serialize.sh: timed out after ${WAIT_SECS}s waiting for lock '$NAME'" >&2
        exit 2
    fi
    sleep 1
done

"$@"
rc=$?
rm -rf "$LOCKDIR"
trap - EXIT INT TERM
exit "$rc"
