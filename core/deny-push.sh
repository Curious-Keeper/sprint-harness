#!/usr/bin/env bash
#
# PreToolUse(Bash) hook: HARD-DENY every git push from any AI agent.
#
# PROJECT-AGNOSTIC. The denial reason comes from harness.config.json
# (git.denyPushReason) so the message can name YOUR actual gate; the matching
# logic never changes.
#
# WHY THIS IS A HOOK AND NOT A LINE IN A PROMPT. On the project this was
# extracted from, an agent walked around an instruction-level blocklist: the
# approval log read correct and enforced nothing — 13 verdicts, 0 denials, and
# the quarantined command ran anyway, because the agent wrote its own client and
# concluded "the quarantine is a launcher". An instruction is a suggestion to a
# model. A PreToolUse deny is a gate the model never gets to argue with.
#
# Fails CLOSED: any unreadable payload, missing jq, or unexpected shape denies.
# A hook that errors open is the same as no hook.
#
# Install (in .claude/settings.json):
#   "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ {
#       "type": "command",
#       "command": "D=\"${CLAUDE_PROJECT_DIR:-$PWD}\"; S=\"$D/.claude/hooks/deny-push.sh\"; [ -x \"$S\" ] || S=\"$PWD/.claude/hooks/deny-push.sh\"; if [ -x \"$S\" ]; then exec \"$S\"; fi; cat >/dev/null; printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"push-guard: deny-push.sh could not be located, so this command was not inspected. Denying by default.\"}}'",
#       "timeout": 10, "statusMessage": "push guard" } ] } ] }
#
# Note the fallback in that one-liner: if the script cannot be FOUND, the inline
# command denies anyway. A guard that silently disappears is the most dangerous
# state this can be in, because everything keeps working.
#
# Test:
#   echo '{"tool_input":{"command":"git push"}}'   | .claude/hooks/deny-push.sh
#   echo '{"tool_input":{"command":"git status"}}' | .claude/hooks/deny-push.sh

set -uo pipefail

deny() {
    jq -cn --arg reason "$1" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $reason
        }
    }'
    exit 0
}

payload=$(cat 2>/dev/null || true)

if ! command -v jq >/dev/null 2>&1; then
    deny "push-guard: jq is unavailable, so this command could not be inspected. Denying by default."
fi

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# No command field: not a Bash invocation this guard understands. Allow — other
# tools are not the thing being gated, and denying everything would be useless.
[ -n "$cmd" ] || exit 0

# ── the project's own reason, if it configured one ───────────────────────────
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
CFG=""
for c in "${SPRINT_HARNESS_CONFIG:-}" "$ROOT/.claude/harness.config.json" "$ROOT/harness.config.json"; do
    [ -n "$c" ] && [ -f "$c" ] && { CFG="$c"; break; }
done

REASON=""
ENABLED="true"
if [ -n "$CFG" ]; then
    REASON=$(jq -r '.git.denyPushReason // empty' "$CFG" 2>/dev/null || true)
    ENABLED=$(jq -r 'if .git.denyPush == false then "false" else "true" end' "$CFG" 2>/dev/null || echo "true")
fi
[ "$ENABLED" = "false" ] && exit 0

DEFAULT_REASON="BLOCKED: git push is denied for AI agents on this project.

Staging and committing are allowed; publishing is not, in any form — no --force,
no --force-with-lease, no 'git -C <path> push', no push inside a chained command.

A push is the one action that leaves the human's reach. A green anchor set is not
evidence a change is right; only a rebuilt, hands-on-verified running app is.

If a push is genuinely required, say so and STOP. Do not work around this."

# Normalise so 'git\npush' and 'git    push' read the same as 'git push'.
flat=$(printf '%s' "$cmd" | tr '\n\t' '  ')

# `git <anything that is not a command separator> push` — catches:
#   git push                      git push --force            git push -f
#   git -C /path push             git --git-dir=x push        git push --force-with-lease
#   cd web && git push origin     foo; git push; bar          $(git push)
# The [^;&|] class stops the match running across a separator, so
# `git status && echo push` is NOT caught while `git status && git push` is.
#
# KNOWN AND DELIBERATE OVER-BLOCK: `echo git push` is denied too. Distinguishing
# a literal from an invocation would mean parsing shell, and this guard fails
# closed by design. Over-blocking a harmless echo costs nothing; under-blocking
# one chained push costs everything. selftest.sh asserts this behaviour so that
# nobody "fixes" it into a hole later.
if printf '%s' "$flat" | grep -Eq '(^|[[:space:];&|(`])git([[:space:]]+[^;&|]*)?[[:space:]]+push([[:space:];&|)]|$)'; then
    deny "${REASON:-$DEFAULT_REASON}"
fi

# Also refuse the obvious indirections. An agent that cannot run `git push`
# should not reach for a helper that pushes on its behalf.
if printf '%s' "$flat" | grep -Eq '(^|[[:space:];&|(`])gh[[:space:]]+(pr[[:space:]]+(create|merge)|repo[[:space:]]+sync)'; then
    deny "BLOCKED: 'gh pr create' / 'gh pr merge' / 'gh repo sync' publish to the remote, which is the same boundary as git push.

Prepare the branch and the PR body locally and hand them over. A human opens and merges."
fi

exit 0
