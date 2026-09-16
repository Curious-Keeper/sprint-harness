# Model and provider configuration

The toolchain separates project intent from local availability.

## Project-local roles

A consumer project records model intent in `.claude/harness.config.json`:

```json
{
  "models": {
    "roles": {
      "builder": "inherit-parent",
      "verifier": "inherit-parent",
      "reviewer": ["claude-opus-5", "gpt-5.6", "grok-4.6-fast"],
      "planner": "auto",
      "scope": "auto",
      "summarizer": "auto"
    }
  },
  "interrogate": {
    "reviewers": [
      { "label": "Reviewer A", "model": "claude-opus-5" },
      { "label": "Reviewer B", "model": "gpt-5.6" }
    ]
  }
}
```

`agents.builder` and `agents.verifier` still name the agent contracts to run. `models.roles.builder` and `models.roles.verifier` name only model selection.

The schema validates shape only. Model slugs rot quickly, and a newly available model must not need a schema release. `auto` and `inherit-parent` are ordinary string values by convention: `auto` lets the runner choose, and `inherit-parent` uses the current session model.

## Global catalog

Local provider availability belongs outside the repo, at:

```text
~/.config/sprint-harness/models.json
```

Do not put secrets in this file. Reference environment variables instead:

```json
{
  "providers": {
    "anthropic": { "apiKeyEnv": "ANTHROPIC_API_KEY" },
    "openai": { "apiKeyEnv": "OPENAI_API_KEY" },
    "xai": { "apiKeyEnv": "XAI_API_KEY" }
  },
  "models": {
    "claude-opus-5": { "provider": "anthropic" },
    "gpt-5.6": { "provider": "openai" },
    "grok-4.6-fast": { "provider": "xai" }
  }
}
```

The global catalog says what this machine can run. The project config says what roles this project wants.

## Runners

Knowing a model's name is not the same as being able to reach it. Most agent
runtimes spawn only their own vendor's models — Claude Code's `Agent` tool
takes `sonnet | opus | haiku | fable` and nothing else — so a roster naming GPT
or Grok resolves cleanly and then has nothing to run it with. A `runner` is the
command that closes that gap:

```json
{
  "runners": {
    "pi": {
      "cmd": "pi",
      "args": ["-p", "--no-tools", "--no-session", "--mode", "json"],
      "modelFlag": "--model",
      "reports": {
        "format": "jsonl",
        "event": "turn_end",
        "modelPath": "message.model",
        "providerPath": "message.provider",
        "costPath": "message.usage.cost.total"
      }
    }
  },
  "models": {
    "claude-opus-5": { "provider": "anthropic", "runner": "host" },
    "grok-4.6-fast": { "provider": "xai", "runner": "pi", "runnerModel": "xai/grok-4.6" }
  }
}
```

`runner: "host"` means the calling runtime spawns it natively; the catalog
cannot verify that runtime and never claims to. Any other name must appear in
`runners`.

`runnerModel` exists because the two names drift apart. The catalog slug is
what the **project** asked for and stays stable across vendor renames;
`runnerModel` is what the **runner** calls it today. Keep them separate, and
put the read-only flags in `args` — a reviewer that can edit files is not a
reviewer.

### Reachability

`lib/dispatch.mjs` answers "can anything here reach this", from facts on the
machine only. It never spawns and never contacts a provider, so a degraded
roster is reported before a token is spent:

| `via` | Meaning |
|---|---|
| `host` | the calling runtime spawns it |
| `runner` | the runner's command is on PATH **and executable** |
| `apiKey` | no runner, but the provider key is set |
| `unreachable` | neither |

The runner is checked first; `apiKey` is only reached when the runner's command
is missing. **A key is not a dispatcher** — this kit ships no API client, so an
`apiKey` reviewer is reported separately and never counted toward
`crossVendor`. Counting it once let a machine with no runner installed claim
three healthy vendors when two could not run.

Reachable means "something here can drive it", never "the provider is up". A
runner that exists can still fail at spawn time; that is a degradation to
report, not a reason to substitute another vendor into the roster.

### Checking what actually ran

Asking a runner for a model is not the same as getting one. `pi --provider xai`
is accepted, silently ignored, and answers from `openai-codex`. A roster can
therefore claim three vendors, run two, and say nothing — worse than a short
roster, because it is invisible.

Where a runner declares `reports`, `dispatch.ranAs(stdout, reports)` reads the
provider, model and cost back out of the runner's own output so the caller can
compare them against what it asked for. It returns `null` rather than guessing
when the runner reports nothing; that is a blind spot to name, not a pass.

Set `SPRINT_HARNESS_MODELS` to point at another catalog during tests or local experiments. A concrete model slug in project config must appear in the catalog. The aliases `auto` and `inherit-parent` do not require a catalog entry, because they leave model choice to the host session.

Check the active project with:

```sh
node .claude/harness-core/models.mjs status
```

The status command prints the model slug, provider, and environment variable name for each configured role, and for each reviewer its `via`, the `argv` that would run it, and why. It reports which vendors are reachable and whether the roster is cross-vendor at all. It exits non-zero when a role's environment variable is missing, when a reviewer is unreachable, or when one resolves to a key with no dispatcher. It never prints secret values.
