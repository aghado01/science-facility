#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  QuarantineReconciliationService,
  deriveConversationKey,
} from "./quarantine-reconciliation.js";
import { isWellFormedUnicode } from "./identity.js";
import { TranscriptStore } from "./transcript.js";

const COMMON_OPTIONS = new Set(["workspace-root", "application", "handle"]);
const RECONCILE_OPTIONS = new Set([
  ...COMMON_OPTIONS,
  "exchange-id",
  "reason",
  "observed-at",
  "basis",
  "evidence-ref",
]);
const BASIS_KINDS = new Set([
  "terminal_commit_verified",
  "operator_attested_native_stop",
]);

export class QuarantineAdminError extends Error {
  constructor(code, message, details = undefined) {
    super(message);
    this.name = "QuarantineAdminError";
    this.code = code;
    if (details !== undefined) this.details = details;
  }
}

function fail(code, message, details) {
  throw new QuarantineAdminError(code, message, details);
}

function nonBlank(value, label) {
  if (typeof value !== "string" || value.trim().length === 0) {
    fail("QUARANTINE_ADMIN_ARGUMENT_INVALID", `${label} must be a non-blank string`);
  }
  return value;
}

function canonicalIdentityOption(value, label) {
  const candidate = nonBlank(value, label);
  if (candidate !== candidate.trim()) {
    fail(
      "QUARANTINE_ADMIN_ARGUMENT_INVALID",
      `${label} must not contain leading or trailing whitespace`,
    );
  }
  if (!isWellFormedUnicode(candidate)) {
    fail(
      "QUARANTINE_ADMIN_ARGUMENT_INVALID",
      `${label} must be well-formed Unicode`,
    );
  }
  return candidate;
}

// Keep transcript ownership aligned with the MCP server: a pane target such as
// `agent-foo:0.1` belongs to the durable transcript for session `agent-foo`.
function sessionOf(handle) {
  const sessionId = String(handle).split(":")[0];
  if (sessionId.length === 0) {
    fail(
      "QUARANTINE_ADMIN_ARGUMENT_INVALID",
      "--handle must begin with a non-empty transcript session name",
    );
  }
  return sessionId;
}

function parseOptions(argv, allowed) {
  const options = {};
  for (let index = 1; index < argv.length; index++) {
    const token = argv[index];
    if (typeof token !== "string" || !token.startsWith("--") || token === "--") {
      fail(
        "QUARANTINE_ADMIN_ARGUMENT_INVALID",
        `unexpected positional argument '${String(token)}'`,
      );
    }

    const separator = token.indexOf("=");
    const name = token.slice(2, separator === -1 ? undefined : separator);
    if (!allowed.has(name)) {
      fail("QUARANTINE_ADMIN_ARGUMENT_INVALID", `unsupported option '--${name}'`);
    }
    if (Object.hasOwn(options, name)) {
      fail("QUARANTINE_ADMIN_ARGUMENT_INVALID", `option '--${name}' was supplied more than once`);
    }

    let value;
    if (separator !== -1) {
      value = token.slice(separator + 1);
    } else {
      index++;
      value = argv[index];
      if (typeof value !== "string" || value.startsWith("--")) {
        fail("QUARANTINE_ADMIN_ARGUMENT_INVALID", `option '--${name}' requires a value`);
      }
    }
    options[name] = nonBlank(value, `--${name}`);
  }
  return options;
}

function requireOptions(options, names) {
  const missing = names.filter((name) => !Object.hasOwn(options, name));
  if (missing.length > 0) {
    fail(
      "QUARANTINE_ADMIN_ARGUMENT_INVALID",
      `missing required options: ${missing.map((name) => `--${name}`).join(", ")}`,
    );
  }
}

function parseArguments(argv) {
  if (!Array.isArray(argv)) {
    fail("QUARANTINE_ADMIN_ARGUMENT_INVALID", "argv must be an array");
  }
  const command = argv[0];
  if (command !== "status" && command !== "reconcile") {
    fail(
      "QUARANTINE_ADMIN_ARGUMENT_INVALID",
      "command must be 'status' or 'reconcile'",
    );
  }

  const allowed = command === "status" ? COMMON_OPTIONS : RECONCILE_OPTIONS;
  const options = parseOptions(argv, allowed);
  requireOptions(options, [...allowed]);

  const application = canonicalIdentityOption(options.application, "--application");
  const handle = canonicalIdentityOption(options.handle, "--handle");
  const conversationKey = deriveConversationKey({ application, handle });
  const workspaceRoot = path.resolve(options["workspace-root"]);
  const sessionId = sessionOf(handle);

  if (command === "status") {
    return { command, workspaceRoot, application, handle, conversationKey, sessionId };
  }

  if (!Number.isFinite(Date.parse(options["observed-at"]))) {
    fail("QUARANTINE_ADMIN_ARGUMENT_INVALID", "--observed-at must be an ISO date-time string");
  }
  if (!BASIS_KINDS.has(options.basis)) {
    fail(
      "QUARANTINE_ADMIN_ARGUMENT_INVALID",
      `--basis must be one of: ${[...BASIS_KINDS].join(", ")}`,
    );
  }

  return {
    command,
    workspaceRoot,
    application,
    handle,
    conversationKey,
    sessionId,
    exchangeId: options["exchange-id"],
    reason: options.reason,
    observedAt: options["observed-at"],
    basis: options.basis,
    evidenceRef: options["evidence-ref"],
  };
}

function assertReadOnlyStore(store) {
  if (
    !store
    || typeof store.readHeader !== "function"
    || typeof store.getRecoveryNotices !== "function"
    || typeof store.close !== "function"
  ) {
    fail(
      "QUARANTINE_ADMIN_STORE_INVALID",
      "openReadOnly() returned an incompatible transcript store",
    );
  }
  return store;
}

function assertWritableStore(store) {
  if (!store || typeof store.reconcileQuarantine !== "function" || typeof store.close !== "function") {
    fail(
      "QUARANTINE_ADMIN_STORE_INVALID",
      "openWritable() returned an incompatible transcript store",
    );
  }
  return store;
}

async function inspectTranscript({ workspaceRoot, sessionId, openReadOnly }) {
  const store = assertReadOnlyStore(await openReadOnly({ workspaceRoot, sessionId }));
  try {
    const header = await store.readHeader();
    const quarantines = store.getRecoveryNotices();
    if (!Array.isArray(quarantines)) {
      fail(
        "QUARANTINE_ADMIN_STORE_INVALID",
        "read-only transcript store returned invalid quarantine notices",
      );
    }
    return { header, quarantines: structuredClone(quarantines) };
  } finally {
    await store.close();
  }
}

function transcriptSummary(header) {
  if (header === null) return { exists: false };
  if (!header || typeof header !== "object" || Array.isArray(header)) {
    fail("QUARANTINE_ADMIN_STORE_INVALID", "read-only transcript store returned an invalid header");
  }
  return {
    exists: true,
    transcript_id: header.transcript_id,
    session_id: header.session?.session_id,
  };
}

async function runStatus(parsed, dependencies) {
  const inspected = await inspectTranscript({
    workspaceRoot: parsed.workspaceRoot,
    sessionId: parsed.sessionId,
    openReadOnly: dependencies.openReadOnly,
  });
  const transcript = transcriptSummary(inspected.header);
  return {
    workspace_root: parsed.workspaceRoot,
    application: parsed.application,
    handle: parsed.handle,
    conversation_key: parsed.conversationKey,
    gate: { attached: false },
    transcript,
    quarantines: inspected.quarantines.filter(
      (notice) => notice?.conversation_key === parsed.conversationKey,
    ),
  };
}

async function runReconcile(parsed, dependencies) {
  if (dependencies.env?.PARA_AGENT_ENABLE_QUARANTINE_ADMIN !== "1") {
    fail(
      "QUARANTINE_ADMIN_DISABLED",
      "offline reconciliation is disabled; set PARA_AGENT_ENABLE_QUARANTINE_ADMIN=1 to opt in",
    );
  }
  const preflight = await inspectTranscript({
    workspaceRoot: parsed.workspaceRoot,
    sessionId: parsed.sessionId,
    openReadOnly: dependencies.openReadOnly,
  });
  if (preflight.header === null) {
    fail(
      "QUARANTINE_ADMIN_TRANSCRIPT_NOT_FOUND",
      `no transcript exists for handle '${parsed.handle}'`,
    );
  }
  transcriptSummary(preflight.header);

  const store = assertWritableStore(await dependencies.openWritable({
    workspaceRoot: parsed.workspaceRoot,
    sessionId: parsed.sessionId,
  }));
  try {
    const service = dependencies.createService({
      gate: null,
      storeForHandle: async (handle) => {
        if (handle !== parsed.handle) {
          fail(
            "QUARANTINE_ADMIN_TARGET_MISMATCH",
            "reconciliation service requested a different transcript handle",
          );
        }
        return store;
      },
    });
    if (!service || typeof service.reconcile !== "function") {
      fail(
        "QUARANTINE_ADMIN_SERVICE_INVALID",
        "createService() returned an incompatible reconciliation service",
      );
    }

    const result = await service.reconcile({
      application: parsed.application,
      handle: parsed.handle,
      exchangeId: parsed.exchangeId,
      expected: {
        reason: parsed.reason,
        observedAt: parsed.observedAt,
      },
      basis: {
        kind: parsed.basis,
        evidenceRef: parsed.evidenceRef,
      },
    });
    return {
      workspace_root: parsed.workspaceRoot,
      application: parsed.application,
      handle: parsed.handle,
      conversation_key: result.conversationKey,
      exchange_id: result.exchangeId,
      durable: result.durable,
      gate: result.gate,
    };
  } finally {
    await store.close();
  }
}

function errorPayload(error) {
  return {
    code: typeof error?.code === "string" ? error.code : "QUARANTINE_ADMIN_FAILED",
    name: typeof error?.name === "string" ? error.name : "Error",
    message: typeof error?.message === "string" ? error.message : String(error),
    ...(error?.details !== undefined ? { details: error.details } : {}),
    ...(error?.durableReceipt !== undefined ? { durable_receipt: error.durableReceipt } : {}),
  };
}

function writeJson(stream, value) {
  if (!stream || typeof stream.write !== "function") {
    throw new TypeError("JSON output stream must implement write()");
  }
  stream.write(`${JSON.stringify(value)}\n`);
}

/**
 * Testable CLI entry point. It returns a process-style exit code and never calls
 * process.exit(); the direct-entry wrapper owns process.exitCode.
 */
export async function main(argv = process.argv.slice(2), {
  stdout = process.stdout,
  stderr = process.stderr,
  env = process.env,
  openReadOnly = (options) => TranscriptStore.openReadOnly(options),
  openWritable = (options) => TranscriptStore.openWritable(options),
  createService = (options) => new QuarantineReconciliationService(options),
} = {}) {
  try {
    const parsed = parseArguments(argv);
    const result = parsed.command === "status"
      ? await runStatus(parsed, { openReadOnly })
      : await runReconcile(parsed, { env, openReadOnly, openWritable, createService });
    writeJson(stdout, { ok: true, command: parsed.command, result });
    return 0;
  } catch (error) {
    writeJson(stderr, { ok: false, error: errorPayload(error) });
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main();
}
