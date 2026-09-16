//
// Turn a catalog model slug into something a caller can actually run.
//
// models.mjs answers "what does this project want, and does this machine know
// that name". This module answers the next question, which is the one that
// was missing: "and can anything here actually REACH it".
//
// It never spawns and never talks to a provider. Reachability is decided from
// facts on this machine — a command on PATH, an environment variable's
// presence — so a caller can report a degraded roster before spending a token,
// and so this file stays testable with no network and no keys.

import { accessSync, constants, statSync } from "node:fs";
import { delimiter, join } from "node:path";
import { HOST_RUNNER, loadModelCatalog, resolveModel, reviewerRoster } from "./models.mjs";

// Why a model is reachable, most direct first. A caller should prefer the
// earliest one it can honour.
export const VIA_HOST = "host";       // the calling runtime spawns it natively
export const VIA_RUNNER = "runner";   // a command on this machine can drive it
export const VIA_API_KEY = "apiKey";  // the provider key is present
export const UNREACHABLE = "unreachable";

export function runnerFor(spec, catalog, where = "model", env = process.env) {
    const resolved = resolveModel(spec, catalog, where);
    if (!resolved) {
        // "auto" / "inherit-parent" pin nothing on purpose. The host picks,
        // so it is reachable by definition and carries no argv.
        return { spec: spec ?? null, model: null, provider: null, via: VIA_HOST,
                 argv: null, runner: HOST_RUNNER, why: "no model pinned" };
    }

    const base = {
        spec, model: resolved.model, provider: resolved.provider,
        runner: resolved.runner ?? HOST_RUNNER, argv: null,
    };

    if (base.runner === HOST_RUNNER) {
        return { ...base, via: VIA_HOST,
                 why: "runner is the calling runtime; this module cannot verify it" };
    }

    const runner = catalog.runners?.[base.runner];
    if (!runner) {
        // loadModelCatalog() refuses this, so reaching here means the caller
        // built a catalog by hand. Say which name is dangling rather than
        // dying on a property of undefined three lines down.
        throw new Error(`sprint-harness: ${where} names runner ` +
            `${JSON.stringify(base.runner)}, which the catalog does not define`);
    }
    const cmd = onPath(runner.cmd, env);
    if (cmd) {
        const argv = [cmd, ...runner.args];
        if (runner.modelFlag) argv.push(runner.modelFlag, resolved.runnerModel);
        return { ...base, via: VIA_RUNNER, argv, reports: runner.reports ?? null,
                 why: `${runner.cmd} on PATH drives ${resolved.runnerModel}` };
    }

    if (resolved.apiKeyEnv && env[resolved.apiKeyEnv]) {
        return { ...base, via: VIA_API_KEY,
                 why: `${runner.cmd} is not on PATH, but ${resolved.apiKeyEnv} is set` };
    }

    const missing = resolved.apiKeyEnv ? ` and ${resolved.apiKeyEnv} is unset` : "";
    return { ...base, via: UNREACHABLE,
             why: `${runner.cmd} is not on PATH${missing}` };
}

// The whole reviewer roster, each entry carrying how it can be reached. The
// caller spawns the reachable ones and reports the rest; it must NOT swap a
// reachable model in for an unreachable one, because a roster's value is the
// vendors in it, not its length.
export function rosterDispatch(cfg, opts = {}) {
    const catalog = Object.hasOwn(opts, "catalog") ? opts.catalog : loadModelCatalog();
    const env = opts.env ?? process.env;
    const reviewers = reviewerRoster(cfg, { catalog }).map((r, i) => ({
        label: r.label,
        ...runnerFor(r.model, catalog, `reviewer[${i}]`, env),
    }));

    // A KEY IS NOT A DISPATCHER. This harness ships no API client, so
    // VIA_API_KEY names a path nothing here can walk. Counting it as reachable
    // let a roster with no runner installed report three healthy vendors and
    // an empty unreachable list — the same overstatement this module exists to
    // stop, arriving one layer further in.
    const runnable = reviewers.filter((r) => r.via === VIA_HOST || r.via === VIA_RUNNER);
    const vendors = new Set(runnable.map((r) => r.provider).filter(Boolean));
    return {
        reviewers,
        unreachable: reviewers.filter((r) => r.via === UNREACHABLE),
        // Reported apart from both: the credential is there, the caller just
        // needs its own API client to use it. Actionable, but not reachable.
        keyOnly: reviewers.filter((r) => r.via === VIA_API_KEY),
        vendors: [...vendors].sort(),
        // Reachable means "something here can drive it", never "the provider
        // is up". A runner that exists can still fail at spawn time, and the
        // caller must report that as a degraded roster rather than retrying
        // into a substitution. Probing liveness costs a real call, so this
        // module does not.
        liveness: "unprobed",
        // The premise of a multi-model review is vendor diversity. One vendor
        // is a fact the caller has to surface, not a detail.
        crossVendor: vendors.size > 1,
    };
}

function onPath(cmd, env) {
    if (cmd.includes("/")) return executable(cmd) ? cmd : null;
    for (const dir of (env.PATH ?? "").split(delimiter)) {
        if (!dir) continue;
        const full = join(dir, cmd);
        if (executable(full)) return full;
    }
    return null;
}

function executable(p) {
    // The execute bit is the point. Checking only that a regular file exists
    // reports a non-executable file on PATH as a reachable runner, and the
    // failure then surfaces as EACCES at spawn — after the roster was already
    // reported as healthy, which is the one thing this module exists to avoid.
    try {
        if (!statSync(p).isFile()) return false;
        accessSync(p, constants.X_OK);
        return true;
    } catch {
        return false;
    }
}

// What a runner ACTUALLY ran, read back out of its own output.
//
// Asking for a model is not the same as getting one. `pi --provider xai` is
// accepted, ignored, and answers from openai-codex/gpt-5.5 — so a roster can
// claim three vendors, run two, and say nothing. That is a worse failure than
// the roster being short, because it is invisible. Where a runner reports what
// it ran, the caller MUST compare it against what it asked for.
//
// Returns null when the runner does not report; that is a known blind spot to
// surface, not a pass.
export function ranAs(stdout, reports) {
    if (!reports) return null;
    let last = null;
    for (const line of String(stdout).split("\n")) {
        const t = line.trim();
        if (!t || t[0] !== "{") continue;
        let obj;
        try {
            obj = JSON.parse(t);
        } catch {
            continue;   // a runner may interleave non-JSON lines
        }
        if (obj.type === reports.event) last = obj;
    }
    if (!last) return null;
    return {
        provider: dig(last, reports.providerPath),
        model: dig(last, reports.modelPath),
        cost: reports.costPath ? dig(last, reports.costPath) : null,
    };
}

function dig(obj, path) {
    return path.split(".").reduce((o, k) => (o == null ? o : o[k]), obj) ?? null;
}
