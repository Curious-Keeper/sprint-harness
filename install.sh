#!/usr/bin/env bash
#
# Install sprint-harness into a target project.
#
#     ./install.sh /path/to/project [--stack node-web|go-service|blank]
#
# Copies core/ (never edit it in place — pull updates by re-running this),
# drops templates you must fill in, and wires the push-guard hook into
# .claude/settings.json.
#
# IDEMPOTENT for core/. REFUSES to overwrite anything you have already filled in
# — templates and config are yours once they exist, and silently replacing a
# filled-in agent contract would delete the invariants that are the whole point.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET="${1:-}"
STACK="blank"

shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --stack) STACK="${2:-blank}"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "usage: ./install.sh /path/to/project [--stack node-web|go-service|blank]" >&2
    exit 2
fi
[ -d "$TARGET" ] || { echo "error: $TARGET is not a directory" >&2; exit 2; }
git -C "$TARGET" rev-parse --show-toplevel >/dev/null 2>&1 \
    || { echo "error: $TARGET is not a git repository" >&2; exit 2; }

ROOT=$(git -C "$TARGET" rev-parse --show-toplevel)
echo "installing sprint-harness into $ROOT"

mkdir -p "$ROOT/.claude/"{work,agents,hooks,skills/sprint}

# ── core: always overwritten, never edited in place ──────────────────────────
rm -rf "$ROOT/.claude/harness-core"
cp -r "$HERE/core" "$ROOT/.claude/harness-core"
chmod +x "$ROOT/.claude/harness-core"/*.sh
echo "  ✓ .claude/harness-core/   (overwritten — do not edit; re-run to update)"

# The hook and the gate are referenced by path from settings.json and from
# anchors, so give them stable homes outside the versioned core dir.
cp "$HERE/core/deny-push.sh"            "$ROOT/.claude/hooks/deny-push.sh"
cp "$HERE/core/paired-artifact-gate.sh" "$ROOT/.claude/work/paired-artifact-gate.sh"
chmod +x "$ROOT/.claude/hooks/deny-push.sh" "$ROOT/.claude/work/paired-artifact-gate.sh"
echo "  ✓ .claude/hooks/deny-push.sh"
echo "  ✓ .claude/work/paired-artifact-gate.sh"

# ── templates: never clobber ────────────────────────────────────────────────
place() {
    local src="$1" dst="$2"
    if [ -e "$dst" ]; then
        echo "  – ${dst#"$ROOT"/}  (exists, left alone)"
    else
        cp "$src" "$dst"
        echo "  ✓ ${dst#"$ROOT"/}  ← FILL THIS IN"
    fi
}

place "$HERE/templates/sprint-builder.md"  "$ROOT/.claude/agents/sprint-builder.md"
place "$HERE/templates/sprint-verifier.md" "$ROOT/.claude/agents/sprint-verifier.md"
place "$HERE/templates/SKILL.md"           "$ROOT/.claude/skills/sprint/SKILL.md"
place "$HERE/templates/extract-queue.mjs"  "$ROOT/.claude/work/extract-queue.mjs"

CFG_SRC="$HERE/examples/${STACK}.harness.config.json"
[ -f "$CFG_SRC" ] || CFG_SRC="$HERE/examples/node-web.harness.config.json"
place "$CFG_SRC" "$ROOT/.claude/harness.config.json"

place "$HERE/harness.config.schema.json" "$ROOT/.claude/harness.config.schema.json"

# The template imports core via ../../core/lib/... — repoint it at the installed
# copy so it works without edits.
if [ -f "$ROOT/.claude/work/extract-queue.mjs" ]; then
    sed -i.bak 's|"../../core/lib/|"../harness-core/lib/|g' "$ROOT/.claude/work/extract-queue.mjs" \
        && rm -f "$ROOT/.claude/work/extract-queue.mjs.bak"
fi

# ── settings.json: the push guard ───────────────────────────────────────────
#
# The inline command DENIES BY DEFAULT if the script cannot be located. A guard
# that fails open is the same as no guard, and a missing guard is the most
# dangerous state possible because everything keeps working.
SETTINGS="$ROOT/.claude/settings.json"
HOOK_CMD='D="${CLAUDE_PROJECT_DIR:-$PWD}"; S="$D/.claude/hooks/deny-push.sh"; [ -x "$S" ] || S="$PWD/.claude/hooks/deny-push.sh"; if [ -x "$S" ]; then exec "$S"; fi; cat >/dev/null; printf '"'"'%s'"'"' '"'"'{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"push-guard: deny-push.sh could not be located, so this command was not inspected. Denying by default - a guard that fails open is the same as no guard."}}'"'"''

if command -v jq >/dev/null 2>&1; then
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    if jq -e '.hooks.PreToolUse[]?.hooks[]?.statusMessage == "push guard"' "$SETTINGS" >/dev/null 2>&1; then
        echo "  – .claude/settings.json  (push guard already wired)"
    else
        tmp=$(mktemp)
        jq --arg cmd "$HOOK_CMD" '
            .hooks //= {} |
            .hooks.PreToolUse //= [] |
            .hooks.PreToolUse += [{
                matcher: "Bash",
                hooks: [{ type: "command", command: $cmd, timeout: 10, statusMessage: "push guard" }]
            }]
        ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
        echo "  ✓ .claude/settings.json  (push guard wired)"
    fi
else
    echo "  ! jq not found — wire the push guard into .claude/settings.json by hand"
    echo "    (see core/deny-push.sh header for the exact snippet)"
fi

# ── tracked-ness check ───────────────────────────────────────────────────────
#
# Builders run in git worktrees, which materialize ONLY TRACKED FILES. Many
# projects gitignore `.claude/` — and then a builder's worktree contains no
# harness at all: an anchor that invokes `.claude/work/paired-artifact-gate.sh`
# is not merely failing, the file does not exist. This is scar #5 one layer out,
# and it is silent, so it is checked mechanically here rather than documented.
IGNORED=""
for p in ".claude/harness-core/plan-batch.mjs" ".claude/work/paired-artifact-gate.sh" \
         ".claude/agents/sprint-builder.md" ".claude/harness.config.json"; do
    if git -C "$ROOT" check-ignore -q "$p" 2>/dev/null; then IGNORED="$IGNORED  $p"$'\n'; fi
done

if [ -n "$IGNORED" ]; then
    cat <<EOF

  ⛔  STOP — these installed paths are GITIGNORED:

$IGNORED
  Builders run in git worktrees, which materialize ONLY TRACKED FILES. With
  .claude/ ignored, a builder's worktree contains no harness: any anchor that
  invokes a script under .claude/ finds nothing there, and the map is unreadable
  to the agent planning from it.

  Fix before anything else — un-ignore the harness, e.g. in .gitignore:

      .claude/*
      !.claude/harness-core/
      !.claude/agents/
      !.claude/skills/
      !.claude/work/
      !.claude/hooks/
      !.claude/harness.config.json
      !.claude/settings.json

  Keep ignoring anything local: .claude/settings.local.json, caches, scratch.
EOF
fi

cat <<EOF

Installed. FIRST: commit the harness.

    git add .claude && git commit -m "chore: install sprint harness"

Not optional and not cosmetic — see the note above. Anything an anchor invokes,
and the map itself, must be TRACKED or it does not exist in a builder's worktree.

Then four things, in order — none of them optional either:

  1. .claude/harness.config.json
     Set project.name, mainBranch, and the ANCHORS. Ask: what does a tree
     containing ONLY tracked files lack? That is your \`setup\`.

  2. .claude/agents/sprint-builder.md  +  sprint-verifier.md
     Fill {{REPO_INVARIANTS}}. The bar for an entry: it has already caused a
     real bug HERE. A padded list trains agents to skim the section.

  3. Build your MAP (start from templates/MAP.skeleton.json), then adapt
     .claude/work/extract-queue.mjs to walk it. That is the ~40 lines you write.
     COMMIT THE MAP — builder worktrees materialize only tracked files.

  4. .claude/harness-core/preflight.sh

Read docs/SCARS.md before changing anything in core/. Every guard in there is
scar tissue from a failure that produced a report which looked correct.
EOF
