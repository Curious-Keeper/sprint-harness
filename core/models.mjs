#!/usr/bin/env node
//
// Model catalog diagnostics. Prints resolved model roles without printing secret
// values. This is a read-only check for the project config plus the host catalog.

import { loadConfig } from "./lib/config.mjs";
import { catalogPath, loadModelCatalog, MODEL_ALIASES, resolveModel, reviewerRoster } from "./lib/models.mjs";

const argv = process.argv.slice(2);
const cmd = argv[0] ?? "status";
const json = argv.includes("--json");

if (!new Set(["status", "help", "--help", "-h"]).has(cmd)) {
    console.error(`usage: node .claude/harness-core/models.mjs status [--json]`);
    process.exit(2);
}
if (["help", "--help", "-h"].includes(cmd)) {
    console.log("usage: node .claude/harness-core/models.mjs status [--json]");
    process.exit(0);
}

try {
    const status = modelStatus();
    if (json) {
        console.log(JSON.stringify(status, null, 2));
    } else {
        printStatus(status);
    }
    process.exit(status.ok ? 0 : 1);
} catch (e) {
    console.error(e.message);
    process.exit(2);
}

export function modelStatus(env = process.env) {
    const cfg = loadConfig();
    const catalog = loadModelCatalog();
    const roles = effectiveRoles(cfg, catalog, env);
    const reviewers = reviewerRoster(cfg, { catalog }).map((r) => ({
        label: r.label,
        ...statusForResolved(r, env),
    }));
    const missingEnv = [...roles, ...reviewers].filter((r) => r.env === "missing");
    return {
        ok: missingEnv.length === 0,
        catalog: { path: catalogPath(), present: catalog !== null },
        roles,
        reviewers,
    };
}

function effectiveRoles(cfg, catalog, env) {
    const out = [];
    const seen = new Set();
    const add = (role, spec, source) => {
        seen.add(role);
        out.push(statusForSpec(role, spec ?? null, source, catalog, env));
    };

    add("builder", cfg.models.roles.builder, "models.roles.builder");
    add("verifier", cfg.verify.model ?? cfg.models.roles.verifier,
        cfg.verify.model ? "verify.model" : "models.roles.verifier");
    for (const [role, spec] of Object.entries(cfg.models.roles)) {
        if (!seen.has(role) && role !== "reviewer") add(role, spec, `models.roles.${role}`);
    }
    return out;
}

function statusForSpec(role, spec, source, catalog, env) {
    if (Array.isArray(spec)) {
        return { role, source, spec, model: null, provider: null, apiKeyEnv: null, env: "not-required" };
    }
    if (spec == null || MODEL_ALIASES.has(spec)) {
        return { role, source, spec, model: null, provider: null, apiKeyEnv: null, env: "not-required" };
    }
    const resolved = resolveModel(spec, catalog, source);
    return { role, source, spec, ...statusForResolved(resolved, env) };
}

function statusForResolved(resolved, env) {
    const apiKeyEnv = resolved.apiKeyEnv ?? null;
    return {
        model: resolved.model ?? null,
        provider: resolved.provider ?? null,
        apiKeyEnv,
        env: apiKeyEnv ? (env[apiKeyEnv] ? "set" : "missing") : "not-required",
    };
}

function printStatus(status) {
    console.log(`model catalog: ${status.catalog.present ? "present" : "absent"} (${status.catalog.path})`);
    console.log("roles:");
    for (const r of status.roles) {
        console.log(`  ${r.role}: ${label(r)}`);
    }
    console.log("reviewers:");
    if (!status.reviewers.length) {
        console.log("  none configured");
    }
    for (const r of status.reviewers) {
        console.log(`  ${r.label}: ${label(r)}`);
    }
    if (!status.ok) {
        console.log("missing environment variables:");
        for (const r of [...status.roles, ...status.reviewers].filter((x) => x.env === "missing")) {
            console.log(`  ${r.apiKeyEnv} for ${r.role ?? r.label} (${r.model})`);
        }
    }
}

function label(r) {
    if (!r.model) return `${r.spec ?? "inherit-parent"} (host chooses)`;
    const env = r.apiKeyEnv ? `${r.apiKeyEnv} ${r.env}` : "no apiKeyEnv";
    return `${r.model} via ${r.provider} (${env})`;
}
