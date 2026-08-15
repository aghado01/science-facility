import fs from "node:fs/promises";
import path from "node:path";

import { ClientIntegrationError } from "./errors.js";
import { preparePromptCarrier, PROMPT_CARRIER_FILE_PATTERN } from "./carrier.js";

const LOCK_NAME = ".para-agent-prompt-scavenge.lock";

function fail() {
  throw new ClientIntegrationError("PROMPT_CARRIER_SCAVENGE_FAILED");
}

function freeze(value, seen = new Set()) {
  if (value === null || (typeof value !== "object" && typeof value !== "function")) return value;
  if (seen.has(value)) return value;
  seen.add(value);
  for (const key of Reflect.ownKeys(value)) freeze(value[key], seen);
  return Object.freeze(value);
}

function nonNegative(value, fallback) {
  const result = value ?? fallback;
  if (!Number.isSafeInteger(result) || result < 0) fail();
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
  return identity !== null && identity.dev === stat?.dev && identity.ino === stat?.ino;
}

function sameFile(before, after) {
  for (const key of ["dev", "ino", "size", "mtimeMs"]) {
    if (before[key] !== after[key]) return false;
  }
  return true;
}

async function ownedCandidate(filePath, stat, { platform, securityOps }) {
  if (platform === "win32") {
    if (typeof securityOps?.validateScavengeCandidate !== "function") return false;
    try {
      return await securityOps.validateScavengeCandidate({ filePath, stat, platform }) === true;
    } catch {
      return false;
    }
  }
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) return false;
  if (!securityOps?.validateScavengeCandidate) return true;
  try {
    return await securityOps.validateScavengeCandidate({ filePath, stat, platform }) === true;
  } catch {
    return false;
  }
}

async function ownedLock(lockPath, stat, { platform, securityOps }) {
  if (platform === "win32") {
    if (typeof securityOps?.validateScavengeLock !== "function") return false;
    try {
      return await securityOps.validateScavengeLock({ lockPath, stat, platform }) === true;
    } catch {
      return false;
    }
  }
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) return false;
  if (!securityOps?.validateScavengeLock) return true;
  try {
    return await securityOps.validateScavengeLock({ lockPath, stat, platform }) === true;
  } catch {
    return false;
  }
}

async function releaseLock(binding, fsOps) {
  try {
    const first = await fsOps.lstat(binding.path);
    if (!identityFromStat(first) || !sameIdentity(binding.identity, first)) return false;
    const final = await fsOps.lstat(binding.path);
    if (!identityFromStat(final) || !sameIdentity(binding.identity, final)) return false;
    await fsOps.unlink(binding.path);
    return true;
  } catch (error) {
    return error?.code === "ENOENT";
  }
}

async function createLock(lockPath, fsOps) {
  let handle;
  try {
    handle = await fsOps.open(lockPath, "wx", 0o600);
  } catch (error) {
    if (error?.code === "EEXIST") return null;
    fail();
  }
  let binding;
  try {
    const initial = await handle.stat();
    const identity = identityFromStat(initial);
    if (!identity) fail();
    binding = freeze({ path: lockPath, identity });
    await handle.writeFile(`${process.pid}\n`, "utf8");
    await handle.sync();
    const final = await handle.stat();
    if (!sameIdentity(identity, final)) fail();
    await handle.close();
  } catch (error) {
    try { await handle.close(); } catch {}
    if (binding) await releaseLock(binding, fsOps);
    if (error instanceof ClientIntegrationError) throw error;
    fail();
  }
  return binding;
}

async function recoverStaleLock(lockPath, {
  fsOps,
  platform,
  securityOps,
  currentTime,
  staleLockAgeMs,
  lockLeaseState,
}) {
  let initial;
  try {
    initial = await fsOps.lstat(lockPath);
  } catch {
    return false;
  }
  const identity = identityFromStat(initial);
  if (
    !identity
    || !Number.isFinite(initial.mtimeMs)
    || currentTime - initial.mtimeMs < staleLockAgeMs
    || !(await ownedLock(lockPath, initial, { platform, securityOps }))
  ) {
    return false;
  }
  let lease = "unknown";
  try {
    lease = await lockLeaseState({ name: LOCK_NAME, stat: initial });
  } catch {}
  if (lease !== "inactive") return false;
  try {
    const final = await fsOps.lstat(lockPath);
    if (!identityFromStat(final) || !sameIdentity(identity, final) || !sameFile(initial, final)) return false;
    await fsOps.unlink(lockPath);
    return true;
  } catch {
    return false;
  }
}

async function acquireLock(root, options) {
  const lockPath = path.join(root, LOCK_NAME);
  let binding = await createLock(lockPath, options.fsOps);
  if (binding) return binding;
  if (!(await recoverStaleLock(lockPath, options))) return null;
  binding = await createLock(lockPath, options.fsOps);
  return binding;
}

/**
 * Conservatively scavenge only individually verified stale prompt files.
 * Unknown ownership or lease state always retains the candidate.
 */
export async function scavengePromptCarriers({
  root,
  minimumAgeMs = 24 * 60 * 60 * 1_000,
  staleLockAgeMs = 5 * 60 * 1_000,
  now = () => Date.now(),
  fsOps = fs,
  securityOps = undefined,
  platform = process.platform,
  leaseState = async () => "unknown",
  lockLeaseState = async () => "unknown",
} = {}) {
  const age = nonNegative(minimumAgeMs, 24 * 60 * 60 * 1_000);
  const lockAge = nonNegative(staleLockAgeMs, 5 * 60 * 1_000);
  if (typeof now !== "function" || typeof leaseState !== "function" || typeof lockLeaseState !== "function") fail();
  const currentTime = now();
  if (!Number.isFinite(currentTime)) fail();
  const prepared = await preparePromptCarrier(
    { kind: "prompt_file", root },
    { fsOps, securityOps, platform },
  );
  const lockBinding = await acquireLock(prepared.root, {
    fsOps,
    platform,
    securityOps,
    currentTime,
    staleLockAgeMs: lockAge,
    lockLeaseState,
  });
  if (lockBinding === null) {
    return freeze({ state: "busy", scanned: 0, removed: 0, retained: 0, failed: 0 });
  }

  const result = { state: "completed", scanned: 0, removed: 0, retained: 0, failed: 0 };
  try {
    let entries;
    try {
      entries = await fsOps.readdir(prepared.root, { withFileTypes: true });
    } catch {
      fail();
    }
    for (const entry of entries) {
      if (!PROMPT_CARRIER_FILE_PATTERN.test(entry.name)) continue;
      result.scanned += 1;
      if (entry.isSymbolicLink() || !entry.isFile()) {
        result.retained += 1;
        continue;
      }
      const filePath = path.join(prepared.root, entry.name);
      let initial;
      try {
        initial = await fsOps.lstat(filePath);
      } catch {
        result.failed += 1;
        continue;
      }
      if (
        !identityFromStat(initial)
        || !Number.isFinite(initial.mtimeMs)
        || currentTime - initial.mtimeMs < age
        || !(await ownedCandidate(filePath, initial, { platform, securityOps }))
      ) {
        result.retained += 1;
        continue;
      }
      let lease;
      try {
        lease = await leaseState({ name: entry.name, stat: initial });
      } catch {
        lease = "unknown";
      }
      if (lease !== "inactive") {
        result.retained += 1;
        continue;
      }

      try {
        const final = await fsOps.lstat(filePath);
        if (!identityFromStat(final) || !sameFile(initial, final)) {
          result.retained += 1;
          continue;
        }
        await fsOps.unlink(filePath);
        result.removed += 1;
      } catch {
        result.failed += 1;
      }
    }
  } finally {
    if (!(await releaseLock(lockBinding, fsOps))) result.failed += 1;
  }
  return freeze(result);
}

export const PROMPT_CARRIER_SCAVENGE_LOCK = LOCK_NAME;
