//
// Model/provider catalog resolution for sprint-harness.
//
// Project config says what a role wants. The global catalog says what this
// machine can run. This module joins the two without ever reading a secret value.

import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

export const MODEL_ALIASES = new Set(["auto", "inherit-parent"]);

// A model whose runner is "host" is spawned by whatever agent runtime is
// calling us, with its own native mechanism. The harness cannot verify that
// runtime can actually reach the model, so it never claims so — see
// dispatch.mjs. Every other runner names a command this machine must have.
export const HOST_RUNNER = "host";

export function catalogPath() {
    return process.env.SPRINT_HARNESS_MODELS ??
        resolve(homedir(), ".config/sprint-harness/models.json");
}

export function loadModelCatalog(path = catalogPath()) {
    if (!existsSync(path)) return null;
    let catalog;
    try {
        catalog = JSON.parse(readFileSync(path, "utf8"));
    } catch (e) {
        throw new Error(`sprint-harness: ${path} is not valid JSON — ${e.message}`);
    }
    validateCatalog(catalog, path);
    return { ...catalog, $path: path };
}

function validateCatalog(catalog, path) {
    const die = (msg) => { throw new Error(`sprint-harness: ${path}: ${msg}`); };
    if (!catalog || typeof catalog !== "object" || Array.isArray(catalog)) {
        die("model catalog must be an object");
    }
    if (!catalog.providers || typeof catalog.providers !== "object" || Array.isArray(catalog.providers)) {
        die("providers must be an object");
    }
    if (!catalog.models || typeof catalog.models !== "object" || Array.isArray(catalog.models)) {
        die("models must be an object");
    }

    for (const [name, provider] of Object.entries(catalog.providers)) {
        if (!provider || typeof provider !== "object" || Array.isArray(provider)) {
            die(`providers.${name} must be an object`);
        }
        if ("apiKey" in provider) {
            die(`providers.${name}.apiKey is forbidden; use apiKeyEnv`);
        }
        if ("apiKeyEnv" in provider && typeof provider.apiKeyEnv !== "string") {
            die(`providers.${name}.apiKeyEnv must be a string`);
        }
    }

    for (const [slug, model] of Object.entries(catalog.models)) {
        if (!model || typeof model !== "object" || Array.isArray(model)) {
            die(`models.${slug} must be an object`);
        }
        if (!model.provider || typeof model.provider !== "string") {
            die(`models.${slug}.provider is required`);
        }
        if (!catalog.providers[model.provider]) {
            die(`models.${slug}.provider names unknown provider ${JSON.stringify(model.provider)}`);
        }
        if ("runner" in model && typeof model.runner !== "string") {
            die(`models.${slug}.runner must be a string`);
        }
        if ("runnerModel" in model && typeof model.runnerModel !== "string") {
            die(`models.${slug}.runnerModel must be a string`);
        }
        if ("runnerModel" in model && !("runner" in model)) {
            die(`models.${slug}.runnerModel has no runner to pass it to`);
        }
        if (model.runner && model.runner !== HOST_RUNNER && !catalog.runners?.[model.runner]) {
            die(`models.${slug}.runner names unknown runner ${JSON.stringify(model.runner)}`);
        }
    }

    for (const [name, runner] of Object.entries(catalog.runners ?? {})) {
        if (!runner || typeof runner !== "object" || Array.isArray(runner)) {
            die(`runners.${name} must be an object`);
        }
        if (typeof runner.cmd !== "string" || !runner.cmd) {
            die(`runners.${name}.cmd is required`);
        }
        if (!Array.isArray(runner.args) || runner.args.some((a) => typeof a !== "string")) {
            die(`runners.${name}.args must be an array of strings`);
        }
        if ("modelFlag" in runner && typeof runner.modelFlag !== "string") {
            die(`runners.${name}.modelFlag must be a string`);
        }
        if ("reports" in runner) {
            const r = runner.reports;
            if (!r || typeof r !== "object" || Array.isArray(r)) {
                die(`runners.${name}.reports must be an object`);
            }
            if (r.format !== "jsonl") {
                die(`runners.${name}.reports.format must be "jsonl"`);
            }
            for (const k of ["event", "modelPath", "providerPath"]) {
                if (typeof r[k] !== "string" || !r[k]) {
                    die(`runners.${name}.reports.${k} is required`);
                }
            }
        }
    }
}

export function resolveModel(spec, catalog, where) {
    if (spec == null || MODEL_ALIASES.has(spec)) return null;
    if (typeof spec !== "string") {
        throw new Error(`sprint-harness: ${where} must be a model string`);
    }
    if (!catalog) {
        throw new Error(`sprint-harness: ${where} names ${JSON.stringify(spec)}, but no model catalog exists at ${catalogPath()}`);
    }
    const model = catalog.models[spec];
    if (!model) {
        throw new Error(`sprint-harness: ${where} names unknown model ${JSON.stringify(spec)} in ${catalog.$path}`);
    }
    return {
        model: spec,
        provider: model.provider,
        apiKeyEnv: catalog.providers[model.provider]?.apiKeyEnv ?? null,
        runner: model.runner ?? null,
        runnerModel: model.runnerModel ?? spec,
    };
}

export function resolveRole(cfg, role, opts = {}) {
    const spec = cfg.models?.roles?.[role];
    const catalog = Object.hasOwn(opts, "catalog") ? opts.catalog : loadModelCatalog();
    return resolveModel(spec, catalog, `models.roles.${role}`);
}

export function reviewerRoster(cfg, opts = {}) {
    const catalog = Object.hasOwn(opts, "catalog") ? opts.catalog : loadModelCatalog();
    const configured = cfg.interrogate?.reviewers ?? [];
    if (configured.length) {
        return configured.map((r, i) => ({
            label: r.label,
            ...maybeModel(r.model, catalog, `interrogate.reviewers[${i}].model`),
        }));
    }

    const role = cfg.models?.roles?.reviewer;
    const specs = role == null ? [] : Array.isArray(role) ? role : [role];
    return specs.map((model, i) => ({
        label: `Reviewer ${String.fromCharCode(65 + i)}`,
        ...maybeModel(model, catalog, `models.roles.reviewer[${i}]`),
    }));
}

function maybeModel(spec, catalog, where) {
    const resolved = resolveModel(spec, catalog, where);
    return resolved ? resolved : { model: null, provider: null, apiKeyEnv: null };
}
