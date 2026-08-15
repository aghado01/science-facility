import { createHash, randomBytes as nodeRandomBytes } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { TextDecoder } from "node:util";

import { ClientIntegrationError } from "./errors.js";

const UTF8_FATAL = new TextDecoder("utf-8", { fatal: true });
const CARRIER_NAME = /^pa-prompt-[a-f0-9]{32}\.tmp$/;
const RETRYABLE_DELETE_CODES = new Set(["EBUSY", "EPERM", "EACCES"]);
const FILE_BINDINGS = new WeakMap();

function fail(code, { phase = "pre_acceptance", retryable, safeDetails } = {}) {
  throw new ClientIntegrationError(code, { phase, retryable, safeDetails });
}

function freeze(value, seen = new Set()) {
  if (value === null || (typeof value !== "object" && typeof value !== "function")) return value;
  if (seen.has(value)) return value;
  seen.add(value);
  for (const key of Reflect.ownKeys(value)) freeze(value[key], seen);
  return Object.freeze(value);
}

function samePath(left, right, platform) {
  const a = path.resolve(left);
  const b = path.resolve(right);
  return platform === "win32" ? a.toLowerCase() === b.toLowerCase() : a === b;
}

function wellFormed(value) {
  if (typeof value !== "string") return false;
  if (typeof value.isWellFormed === "function") return value.isWellFormed();
  for (let index = 0; index < value.length; index += 1) {
    const current = value.charCodeAt(index);
    if (current >= 0xd800 && current <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
      index += 1;
    } else if (current >= 0xdc00 && current <= 0xdfff) return false;
  }
  return true;
}

function exactUtf8(value) {
  let bytes;
  if (typeof value === "string") {
    if (!wellFormed(value)) fail("PROMPT_ENCODING_FAILED", { phase: "accepted" });
    bytes = Buffer.from(value, "utf8");
  } else if (Buffer.isBuffer(value)) {
    bytes = Buffer.from(value);
  } else {
    fail("PROMPT_ENCODING_FAILED", { phase: "accepted" });
  }
  try {
    const decoded = UTF8_FATAL.decode(bytes);
    if (!Buffer.from(decoded, "utf8").equals(bytes)) fail("PROMPT_ENCODING_FAILED", { phase: "accepted" });
  } catch (error) {
    if (error instanceof ClientIntegrationError) throw error;
    fail("PROMPT_ENCODING_FAILED", { phase: "accepted" });
  }
  return bytes;
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function positiveInteger(value, fallback, code = "PROMPT_CARRIER_ROOT_UNSAFE", phase = "pre_acceptance") {
  const result = value ?? fallback;
  if (!Number.isSafeInteger(result) || result <= 0) fail(code, { phase });
  return result;
}

function identityFromStat(stat) {
  if (
    !stat
    || typeof stat.isFile !== "function"
    || !stat.isFile()
    || stat.isSymbolicLink()
    || stat.nlink !== 1
    || !(typeof stat.dev === "number" || typeof stat.dev === "bigint")
    || !(typeof stat.ino === "number" || typeof stat.ino === "bigint")
  ) {
    return null;
  }
  return freeze({ dev: stat.dev, ino: stat.ino });
}

function sameIdentity(identity, stat) {
  return identity !== null
    && identity.dev === stat?.dev
    && identity.ino === stat?.ino;
}

async function inspectPathComponents(root, fsOps, phase) {
  const parsed = path.parse(root);
  const remainder = root.slice(parsed.root.length).split(path.sep).filter(Boolean);
  let current = parsed.root;
  for (const component of remainder) {
    current = path.join(current, component);
    const stat = await fsOps.lstat(current);
    if (stat.isSymbolicLink()) fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
  }
}

async function validateRoot(root, {
  fsOps,
  securityOps,
  platform,
  phase = "pre_acceptance",
}) {
  if (typeof root !== "string" || root.length === 0 || root.includes("\0") || !path.isAbsolute(root)) {
    fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
  }
  const resolved = path.resolve(root);
  let stat;
  try {
    await inspectPathComponents(resolved, fsOps, phase);
    stat = await fsOps.lstat(resolved);
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
    const real = await fsOps.realpath(resolved);
    if (!samePath(real, resolved, platform)) fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
  } catch (error) {
    if (error instanceof ClientIntegrationError) throw error;
    fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
  }

  if (platform === "win32") {
    if (typeof securityOps?.validateRoot !== "function") fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
    let approved = false;
    try {
      approved = await securityOps.validateRoot({ root: resolved, stat, platform });
    } catch {}
    if (approved !== true) fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
  } else {
    if ((stat.mode & 0o077) !== 0) fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
    if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
      fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
    }
    if (securityOps?.validateRoot) {
      let approved = false;
      try {
        approved = await securityOps.validateRoot({ root: resolved, stat, platform });
      } catch {}
      if (approved !== true) fail("PROMPT_CARRIER_ROOT_UNSAFE", { phase });
    }
  }
  return { root: resolved, stat };
}

async function validateCreatedFile(binding, { fsOps, securityOps, platform }) {
  let stat;
  try {
    stat = await fsOps.lstat(binding.path);
  } catch {
    fail("PROMPT_CARRIER_VERIFY_FAILED", { phase: "accepted" });
  }
  if (!identityFromStat(stat) || !sameIdentity(binding.identity, stat)) {
    fail("PROMPT_CARRIER_VERIFY_FAILED", { phase: "accepted" });
  }
  if (platform === "win32") {
    if (typeof securityOps?.validateFile !== "function") {
      fail("PROMPT_CARRIER_VERIFY_FAILED", { phase: "accepted" });
    }
    let approved = false;
    try {
      approved = await securityOps.validateFile({ filePath: binding.path, stat, platform });
    } catch {}
    if (approved !== true) fail("PROMPT_CARRIER_VERIFY_FAILED", { phase: "accepted" });
  } else {
    if ((stat.mode & 0o077) !== 0) fail("PROMPT_CARRIER_VERIFY_FAILED", { phase: "accepted" });
    if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
      fail("PROMPT_CARRIER_VERIFY_FAILED", { phase: "accepted" });
    }
    if (securityOps?.validateFile) {
      let approved = false;
      try {
        approved = await securityOps.validateFile({ filePath: binding.path, stat, platform });
      } catch {}
      if (approved !== true) fail("PROMPT_CARRIER_VERIFY_FAILED", { phase: "accepted" });
    }
  }
}

/** Validate exchange-independent carrier resources before durable acceptance. */
export async function preparePromptCarrier(recipe, {
  fsOps = fs,
  securityOps = undefined,
  platform = process.platform,
} = {}) {
  if (!recipe || typeof recipe !== "object" || Array.isArray(recipe)) {
    fail("PROMPT_CARRIER_UNSUPPORTED");
  }
  if (recipe.kind === "stdin_utf8") {
    if (Object.keys(recipe).some((key) => key !== "kind")) fail("PROMPT_CARRIER_UNSUPPORTED");
    return freeze({ kind: "stdin_utf8" });
  }
  if (recipe.kind !== "prompt_file" || Object.keys(recipe).some((key) => !new Set(["kind", "root"]).has(key))) {
    fail("PROMPT_CARRIER_UNSUPPORTED");
  }
  const validated = await validateRoot(recipe.root, { fsOps, securityOps, platform });
  return freeze({
    kind: "prompt_file",
    root: validated.root,
    platform,
  });
}

function stdinHandle(bytes) {
  const retained = Buffer.from(bytes);
  return freeze({
    kind: "stdin_utf8",
    bytes: retained.length,
    sha256: digest(retained),
    readBytes: () => Buffer.from(retained),
  });
}

async function openUnique(root, { fsOps, randomBytes, createAttempts }) {
  for (let attempt = 0; attempt < createAttempts; attempt += 1) {
    const opaque = randomBytes(16);
    if (!Buffer.isBuffer(opaque) || opaque.length !== 16) {
      fail("PROMPT_CARRIER_CREATE_FAILED", { phase: "accepted" });
    }
    const name = `pa-prompt-${opaque.toString("hex")}.tmp`;
    if (!CARRIER_NAME.test(name)) fail("PROMPT_CARRIER_CREATE_FAILED", { phase: "accepted" });
    const filePath = path.join(root, name);
    let handle;
    try {
      handle = await fsOps.open(filePath, "wx", 0o600);
    } catch (error) {
      if (error?.code === "EEXIST") continue;
      fail("PROMPT_CARRIER_CREATE_FAILED", { phase: "accepted" });
    }
    try {
      const identity = identityFromStat(await handle.stat());
      if (!identity) throw new Error("identity unavailable");
      return {
        binding: freeze({ root, name, path: filePath, identity }),
        handle,
      };
    } catch {
      try { await handle.close(); } catch {}
      fail("PROMPT_CARRIER_CLEANUP_PENDING", {
        phase: "accepted",
        safeDetails: { reason: "identity_unavailable" },
      });
    }
  }
  fail("PROMPT_CARRIER_CREATE_FAILED", { phase: "accepted" });
}

async function completeWrite(handle, bytes) {
  let offset = 0;
  while (offset < bytes.length) {
    const result = await handle.write(bytes, offset, bytes.length - offset, offset);
    if (!result || !Number.isSafeInteger(result.bytesWritten) || result.bytesWritten <= 0) {
      throw new Error("write made no progress");
    }
    offset += result.bytesWritten;
  }
}

function validBinding(binding, platform) {
  return binding
    && CARRIER_NAME.test(binding.name)
    && samePath(path.dirname(binding.path), binding.root, platform)
    && samePath(binding.path, path.join(binding.root, binding.name), platform)
    && binding.identity;
}

async function removeBoundFile(binding, {
  fsOps,
  platform,
  maxAttempts,
  retryDelayMs,
  sleep,
}) {
  if (!validBinding(binding, platform)) return { state: "pending", reason: "unsafe_handle" };
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      const first = await fsOps.lstat(binding.path);
      if (!identityFromStat(first) || !sameIdentity(binding.identity, first)) {
        return { state: "pending", reason: "unsafe_entry" };
      }
      const final = await fsOps.lstat(binding.path);
      if (!identityFromStat(final) || !sameIdentity(binding.identity, final)) {
        return { state: "pending", reason: "unsafe_entry" };
      }
      await fsOps.unlink(binding.path);
      return { state: "cleaned", attempts: attempt };
    } catch (error) {
      if (error?.code === "ENOENT") return { state: "cleaned", attempts: attempt };
      const retryable = RETRYABLE_DELETE_CODES.has(error?.code) && platform === "win32";
      if (retryable && attempt < maxAttempts) {
        await sleep(retryDelayMs);
        continue;
      }
      return { state: "pending", reason: retryable ? "locked" : "delete_failed" };
    }
  }
  return { state: "pending", reason: "locked" };
}

function cleanupConfiguration({
  maxAttempts = 4,
  retryDelayMs = 25,
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
}, phase) {
  const attempts = positiveInteger(maxAttempts, 4, "PROMPT_CARRIER_CLEANUP_PENDING", phase);
  if (!Number.isSafeInteger(retryDelayMs) || retryDelayMs < 0 || typeof sleep !== "function") {
    fail("PROMPT_CARRIER_CLEANUP_PENDING", { phase });
  }
  return { maxAttempts: attempts, retryDelayMs, sleep };
}

async function cleanupAfterMaterializationFailure(binding, options, reason) {
  const configuration = cleanupConfiguration(options, "accepted");
  const result = await removeBoundFile(binding, { ...options, ...configuration });
  if (result.state !== "cleaned") {
    fail("PROMPT_CARRIER_CLEANUP_PENDING", {
      phase: "accepted",
      safeDetails: { reason: result.reason ?? reason },
    });
  }
}

/** Materialize exact adapter-produced UTF-8 only after durable acceptance. */
export async function materializePromptCarrier(prepared, payload, {
  fsOps = fs,
  securityOps = undefined,
  platform = process.platform,
  randomBytes = nodeRandomBytes,
  createAttempts = 4,
  cleanupOptions = {},
} = {}) {
  const bytes = exactUtf8(payload);
  if (prepared?.kind === "stdin_utf8") return stdinHandle(bytes);
  if (prepared?.kind !== "prompt_file" || typeof prepared.root !== "string") {
    fail("PROMPT_CARRIER_MATERIALIZATION_FAILED", { phase: "accepted" });
  }
  await validateRoot(prepared.root, { fsOps, securityOps, platform, phase: "accepted" });
  const attempts = positiveInteger(createAttempts, 4, "PROMPT_CARRIER_CREATE_FAILED", "accepted");
  const { binding, handle } = await openUnique(prepared.root, {
    fsOps,
    randomBytes,
    createAttempts: attempts,
  });
  let closed = false;
  let failureCode;
  try {
    await completeWrite(handle, bytes);
    await handle.sync();
    await handle.close();
    closed = true;
  } catch {
    failureCode = "PROMPT_CARRIER_WRITE_FAILED";
  }
  if (!closed) {
    try { await handle.close(); } catch {}
  }

  if (failureCode === undefined) {
    try {
      if (platform !== "win32" && typeof fsOps.chmod === "function") await fsOps.chmod(binding.path, 0o600);
      await validateCreatedFile(binding, { fsOps, securityOps, platform });
      const observed = await fsOps.readFile(binding.path);
      if (!Buffer.isBuffer(observed) || !observed.equals(bytes) || digest(observed) !== digest(bytes)) {
        throw new Error("digest mismatch");
      }
    } catch {
      failureCode = "PROMPT_CARRIER_VERIFY_FAILED";
    }
  }

  if (failureCode !== undefined) {
    await cleanupAfterMaterializationFailure(binding, {
      fsOps,
      platform,
      ...cleanupOptions,
    }, failureCode === "PROMPT_CARRIER_WRITE_FAILED" ? "write_failed" : "verify_failed");
    fail(failureCode, { phase: "accepted" });
  }

  const carrier = {
    kind: "prompt_file",
    path: binding.path,
    bytes: bytes.length,
    sha256: digest(bytes),
  };
  carrier.cleanup = () => cleanupPromptCarrier(carrier, {
    fsOps,
    platform,
    ...cleanupOptions,
  });
  FILE_BINDINGS.set(carrier, binding);
  return freeze(carrier);
}

function pendingWarning(reason, phase = "post_commit") {
  return freeze({
    state: "pending",
    warning: new ClientIntegrationError("PROMPT_CARRIER_CLEANUP_PENDING", {
      phase,
      safeDetails: { reason },
    }).toJSON(),
  });
}

/** Delete only a live carrier handle whose root, name, and file identity still match. */
export async function cleanupPromptCarrier(carrier, {
  fsOps = fs,
  platform = process.platform,
  maxAttempts = 4,
  retryDelayMs = 25,
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
} = {}) {
  if (carrier?.kind === "stdin_utf8") return freeze({ state: "not_applicable" });
  const binding = carrier && typeof carrier === "object" ? FILE_BINDINGS.get(carrier) : undefined;
  if (carrier?.kind !== "prompt_file" || !binding) return pendingWarning("unsafe_handle");
  const configuration = cleanupConfiguration({ maxAttempts, retryDelayMs, sleep }, "post_commit");
  const result = await removeBoundFile(binding, {
    fsOps,
    platform,
    ...configuration,
  });
  if (result.state !== "cleaned") return pendingWarning(result.reason);
  return freeze({ state: "cleaned", attempts: result.attempts });
}

export const PROMPT_CARRIER_FILE_PATTERN = CARRIER_NAME;
