#!/usr/bin/env bash
#
# Sprint pre-flight. Run this BEFORE branching for a new batch.
#
#     core/preflight.sh
#
# PROJECT-AGNOSTIC: every check is driven by harness.config.json, and a check
# whose config is absent is SKIPPED rather than guessed at.
#
# Read-only. It fetches, it reports, and it exits non-zero if anything is off —
# it never checks out, pulls, resets or pushes.
#
# The rule it enforces: a batch starts from a base that is provably current.
# Starting a sprint from a stale or diverged base is how a batch ends up
# rebuilding something that already landed, or conflicting with work it never saw.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "error: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2

CFG=""
for c in "${SPRINT_HARNESS_CONFIG:-}" "$ROOT/.claude/harness.config.json" "$ROOT/harness.config.json"; do
    [ -n "$c" ] && [ -f "$c" ] && { CFG="$c"; break; }
done
[ -n "$CFG" ] || { echo "error: no harness.config.json found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

q() { jq -r "$1 // empty" "$CFG" 2>/dev/null; }

PROJECT=$(q '.project.name')
WORKTREE=$(q '.project.worktree')
MAIN=$(q '.project.mainBranch'); MAIN=${MAIN:-main}
REMOTE=$(q '.project.remote');   REMOTE=${REMOTE:-origin}
QUEUE=$(q '.queue.path');        QUEUE=${QUEUE:-.claude/work/QUEUE.json}
MAP=$(q '.map.path')
MAP_CHECK=$(q '.map.checkCmd')
MAP_COMMITTED=$(jq -r 'if .map.requireCommitted == false then "false" else "true" end' "$CFG")
STACK=$(jq -r 'if .git.stackBranches == false then "false" else "true" end' "$CFG")
GUARD_MARKER=$(q '.git.prePushGuard.marker')
GUARD_INSTALLER=$(q '.git.prePushGuard.installer')

fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
note() { printf '    %s\n' "$1"; }

echo "Sprint pre-flight — $PROJECT"
echo "════════════════════════════════════════"

# ── 1. right worktree ────────────────────────────────────────────────────────
if [ -n "$WORKTREE" ]; then
    if [ "$(basename "$ROOT")" = "$WORKTREE" ]; then
        ok "worktree: $WORKTREE"
    else
        bad "worktree: $(basename "$ROOT") — sprints run from $WORKTREE"
        note "Sprint state resolves file citations against the WORKING TREE, so a"
        note "different worktree can produce a different collision graph."
    fi
fi

# ── 2. clean tree ────────────────────────────────────────────────────────────
if [ -z "$(git status --porcelain)" ]; then
    ok "working tree clean"
else
    bad "working tree DIRTY — commit or stash before branching"
    git status --short | sed 's/^/      /'
fi

# ── 3. main in sync with the remote ──────────────────────────────────────────
echo "  … fetching $REMOTE"
if git fetch --quiet "$REMOTE" 2>/dev/null; then
    local_main=$(git rev-parse "$MAIN" 2>/dev/null || echo "")
    remote_main=$(git rev-parse "$REMOTE/$MAIN" 2>/dev/null || echo "")
    if [ -z "$local_main" ] || [ -z "$remote_main" ]; then
        bad "could not resolve $MAIN / $REMOTE/$MAIN"
    elif [ "$local_main" = "$remote_main" ]; then
        ok "$MAIN == $REMOTE/$MAIN  (${local_main:0:8})"
    else
        ahead=$(git rev-list --count "$REMOTE/$MAIN..$MAIN" 2>/dev/null || echo "?")
        behind=$(git rev-list --count "$MAIN..$REMOTE/$MAIN" 2>/dev/null || echo "?")
        bad "$MAIN DIVERGED from $REMOTE/$MAIN — ahead $ahead, behind $behind"
        [ "$behind" != "0" ] && note "behind: git checkout $MAIN && git pull --ff-only"
        [ "$ahead" != "0" ]  && note "ahead: $ahead local commit(s) never pushed"
    fi
else
    bad "could not reach $REMOTE — cannot prove $MAIN is current"
fi

# ── 4. what to branch FROM ───────────────────────────────────────────────────
#
# ⛔ DO NOT ADD BACK a bare "on main — ready to branch" line. That existed in the
# original and was wrong twice in two days: it told a clean checkout that main
# was a valid base while unpushed work sat on local branches, so the next batch
# got planned against a queue and a lockfile the day had already moved past.
#
# THE RULE: when pushing is gated on a human verifying a running app, there can
# be several unpushed branches between pushes. Each new branch STACKS on the most
# recent one. main is only a valid base when NOTHING is unpushed.
if [ "$STACK" = "true" ]; then
    branch=$(git rev-parse --abbrev-ref HEAD)
    mapfile -t excluded < <(jq -r '.git.excludeFromStacking[]? // empty' "$CFG" 2>/dev/null)

    # ⚠ THE EXCLUSION IS APPLIED IN THE LOOP, NOT BY grep, AND THIS IS NOT STYLE.
    #
    # Do not "simplify" this back to the original:
    #
    #     | grep -v -x -e "$MAIN" $(printf -- '-e %s ' $excluded) 2>/dev/null
    #
    # When git.excludeFromStacking is EMPTY — the DEFAULT, and what every new
    # install has — that expands to a DANGLING `-e`. grep exits 2 with "option
    # requires an argument", the 2>/dev/null swallows the message, `unpushed`
    # comes back empty, and this block prints "nothing unpushed — main is a
    # valid base" while unpushed branches sit right there. It FAILS OPEN, which
    # defeats the entire scar this section exists for: the next batch then gets
    # planned against a queue and a lockfile the day has already moved past.
    #
    # Two things made it survive: the exclusion list is normally empty, so the
    # bug is in the DEFAULT path, not an edge case; and it reproduces only under
    # bash. zsh does not word-split an unquoted command substitution, so
    # checking the pipeline by hand in an interactive zsh shell shows a pass.
    # Verify a shell script under its own shebang.
    #
    # Found 2026-08-14 on a repo with four unpushed commits that pre-flight
    # declared a valid base.
    if ! git rev-parse --verify --quiet "$REMOTE/$MAIN" >/dev/null; then
        # Fail CLOSED. Without the remote ref every branch would compare against
        # nothing, every comparison would be skipped, and the empty result would
        # read exactly like "nothing unpushed".
        bad "$REMOTE/$MAIN does not exist — cannot prove what is unpushed"
        note "fetch it, or correct project.remote / project.mainBranch"
    else
        unpushed=$(
            git for-each-ref --format='%(refname:short)' refs/heads/ |
            while IFS= read -r b; do
                [ -n "$b" ] || continue
                [ "$b" = "$MAIN" ] && continue
                if [ "${#excluded[@]}" -gt 0 ]; then
                    for ex in "${excluded[@]}"; do
                        [ "$b" = "$ex" ] && continue 2
                    done
                fi
                ahead=$(git rev-list --count "$REMOTE/$MAIN..$b" 2>/dev/null) || continue
                [ "${ahead:-0}" -gt 0 ] || continue
                printf '%s %s\n' "$(git log -1 --format=%ct "$b")" "$b"
            done | sort -rn | awk '{print $2}'
        )

        if [ -z "$unpushed" ]; then
            ok "nothing unpushed — $MAIN is a valid base"
            [ "$branch" = "$MAIN" ] || note "on '$branch'; branch the next batch from $MAIN."
        else
            stack_base=$(printf '%s\n' "$unpushed" | head -1)
            count=$(printf '%s\n' "$unpushed" | wc -l | tr -d ' ')

            # ⚠ BEING ON THE STACK BASE IS THE SUCCESS STATE, NOT A FAULT.
            #
            # This block used to call bad() unconditionally whenever anything was
            # unpushed. `branch` is computed above and was consulted ONLY in the
            # nothing-unpushed path, so the one state the advice below exists to
            # produce — standing on the newest unpushed branch — was reported ✗
            # and pre-flight exited 1.
            #
            # That is worse than noise. The rule is "do not start a batch on a red
            # pre-flight", so a red on the success case teaches the operator to run
            # batches through a failing gate, and a genuine fault then looks exactly
            # like the one they have learned to ignore. A check that cries wolf on
            # the state it just recommended destroys the check.
            #
            # Found 2026-08-14 on brian-chastain batch 1, which was dispatched
            # through a red pre-flight whose only complaint was the base it was
            # correctly using.
            # COMPARE BY COMMIT, NOT ONLY BY NAME. Two branches can point at the
            # same commit — a freshly stacked branch and the base it was cut from
            # do exactly that until the first commit lands on it. `git log -1
            # --format=%ct` is then identical for both, so which one sorts first
            # is arbitrary, and a name-only comparison reports the correct base as
            # "not the newest": scar #17's cry-wolf shape, reached one step later.
            #
            # Standing on either is equivalent for the only thing this check cares
            # about — what the NEXT commit will be based on.
            #
            # Found 2026-08-14 on allrail-ops-next while backporting the #17 fix,
            # which is why it exists downstream and not here.
            if [ "$branch" = "$stack_base" ] \
               || [ "$(git rev-parse "$branch" 2>/dev/null)" = "$(git rev-parse "$stack_base" 2>/dev/null)" ]; then
                ok "on the stacking base '$branch' (+$(git rev-list --count "$REMOTE/$MAIN..$branch") ahead of $REMOTE/$MAIN)"
                if [ "$count" -gt 1 ]; then
                    note "$count branch(es) unpushed; '$branch' is the most recent, so this is the right base."
                fi
                note "Build this batch here. Do NOT branch from $MAIN until these land."
            else
                bad "UNPUSHED WORK EXISTS ($count branch(es)) — do NOT branch from $MAIN"
                printf '%s\n' "$unpushed" | while read -r b; do
                    note "  $b  (+$(git rev-list --count "$REMOTE/$MAIN..$b") ahead of $REMOTE/$MAIN)"
                done
                note "STACK on the most recent instead:"
                note "    git checkout -b <next-branch> $stack_base"
                note "Branching from $MAIN here silently drops every one of those commits"
                note "from your base — including the queue and any lockfile."
                if [ "$branch" != "$MAIN" ]; then
                    note "You are on '$branch', which is not the newest unpushed branch."
                fi
            fi
        fi
    fi
fi

# ── 5. push guard installed ──────────────────────────────────────────────────
if [ -n "$GUARD_MARKER" ]; then
    hook="$(git rev-parse --git-common-dir)/hooks/pre-push"
    if [ -x "$hook" ] && grep -q "$GUARD_MARKER" "$hook" 2>/dev/null; then
        ok "pre-push guard installed"
    else
        bad "pre-push guard MISSING${GUARD_INSTALLER:+ — run $GUARD_INSTALLER}"
        note "The PreToolUse hook stops AGENTS. This one guards the human, since a"
        note "habit is not a control."
    fi
else
    # SAY THAT THE CHECK DID NOT RUN. git.prePushGuard is null by default, and
    # this block printed NOTHING AT ALL — so a project that never configured the
    # guard produced pre-flight output identical to one where the guard was
    # present and passing. Silence read as ✓. That is scar #8's shape applied to
    # a check rather than a guard: an absent check must be visible as absent.
    note "· pre-push guard: NOT CHECKED (git.prePushGuard is not configured)"
    note "  Agents are still blocked by the PreToolUse hook; the human is not."
fi

# ── 6. queue state ───────────────────────────────────────────────────────────
if [ -f "$QUEUE" ]; then
    node -e '
        const q = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const open = q.items.filter(i => i.status === "open");
        const disp = open.filter(i => i.dispatchable !== false && i.scope !== "unscoped");
        const byScope = {};
        for (const i of open) byScope[i.scope] = (byScope[i.scope] ?? 0) + 1;
        console.log(`  \x1b[32m✓\x1b[0m queue: ${open.length} open, ${disp.length} dispatchable`);
        console.log(`    scopes: ${JSON.stringify(byScope)}`);
        const merged = q.items.filter(i => i.status === "merged").length;
        if (merged) console.log(`    ${merged} already merged in earlier batches`);
    ' "$QUEUE" 2>/dev/null || bad "queue present but unreadable: $QUEUE"
else
    bad "no $QUEUE — generate it with your extractor first"
fi

# ── 7. the map is fresh, and is COMMITTED ────────────────────────────────────
#
# The committed check matters more than it looks. Builders run in git worktrees,
# which materialize only TRACKED files:
#
#   - An UNCOMMITTED map means every builder plans from the previous commit's
#     evidence while you are reading the new one.
#   - A path cited in an item's evidence is UNREACHABLE to a builder unless it is
#     committed. In the original project, docs/ was gitignored, so an item whose
#     evidence said "the recommendation is in docs/audits/AUDIT_UIUX.md" pointed
#     at a file no builder could open — and a builder would then invent an answer
#     and report success.
if [ -n "$MAP" ]; then
    if [ ! -f "$MAP" ]; then
        bad "no $MAP — the queue is generated from it"
    else
        if [ -n "$MAP_CHECK" ]; then
            if eval "$MAP_CHECK" >/dev/null 2>&1; then
                ok "derived map artifacts current"
            else
                bad "derived map artifact is STALE — run: $MAP_CHECK"
            fi
        fi
        if [ "$MAP_COMMITTED" = "true" ]; then
            map_dir=$(dirname "$MAP")
            if ! git ls-files --error-unmatch "$MAP" >/dev/null 2>&1; then
                bad "$MAP is UNTRACKED — builder worktrees will not see it"
                note "git add $map_dir && commit; worktrees materialize only tracked files"
            elif [ -n "$(git status --porcelain -- "$map_dir" 2>/dev/null)" ]; then
                bad "$map_dir has UNCOMMITTED changes — builders would plan from the committed map"
                note "$(git status --short -- "$map_dir" | head -5)"
            else
                ok "map tracked and committed — rides the merge like code"
            fi
        fi
    fi
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "Ready. Pick a batch:  node core/plan-batch.mjs --auto 8"
else
    echo "NOT ready — fix the ✗ items above before branching."
fi
exit "$fail"
