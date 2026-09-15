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

Set `SPRINT_HARNESS_MODELS` to point at another catalog during tests or local experiments. A concrete model slug in project config must appear in the catalog. The aliases `auto` and `inherit-parent` do not require a catalog entry, because they leave model choice to the host session.

Check the active project with:

```sh
node .claude/harness-core/models.mjs status
```

The status command prints the model slug, provider, and environment variable name for each configured role. It reports whether each environment variable is set. It never prints secret values.
