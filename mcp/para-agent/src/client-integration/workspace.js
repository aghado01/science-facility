import fs from "node:fs/promises";
import path from "node:path";

import { ClientIntegrationError } from "./errors.js";
import { deepFreeze, semanticSha256 } from "./semantic-json.js";

const WORKSPACE_ID = /^[a-z][a-z0-9._-]{0,127}$/;
const WINDOWS_DEVICE_NAME = /^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$/i;

function fail(code) {
  throw new ClientIntegrationError(code);
}

function pathModule(platform) {
  if (platform === "win32") return path.win32;
  if (platform === "linux" || platform === "darwin") return path.posix;
  fail("CLIENT_CWD_INVALID", "workspace platform is unsupported");
}

function isWellFormedString(value) {
  if (typeof value !== "string" || value.includes("\0")) return false;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return false;
    }
  }
  return true;
}

function parseLogicalCwd(cwd, platform, paths) {
  if (cwd === undefined) return [];
  if (!isWellFormedString(cwd) || cwd.length === 0) {
    fail("CLIENT_CWD_INVALID", "cwd must be a non-empty well-formed logical selector when present");
  }
  if (
    paths.isAbsolute(cwd)
    || /^[A-Za-z]:/.test(cwd)
    || cwd.startsWith("/")
    || cwd.startsWith("\\")
    || cwd.startsWith("//")
    || cwd.startsWith("\\?\\")
    || cwd.startsWith("\\.\\")
  ) {
    fail("CLIENT_CWD_INVALID", "cwd must not be rooted, drive-relative, UNC, or device-qualified");
  }
  if (platform !== "win32" && cwd.includes("\\")) {
    fail("CLIENT_CWD_INVALID", "cwd contains a non-portable separator");
  }
  const components = cwd.split(platform === "win32" ? /[\\/]/ : "/");
  if (components.some((component) => component.length === 0 || component === "." || component === "..")) {
    fail("CLIENT_CWD_INVALID", "cwd contains an empty or dot segment");
  }
  if (platform === "win32" && components.some((component) => (
    component.includes(":")
      || component.endsWith(".")
      || component.endsWith(" ")
      || WINDOWS_DEVICE_NAME.test(component)
  ))) {
    fail("CLIENT_CWD_INVALID", "cwd contains a Windows-ambiguous segment");
  }
  return components;
}

function normalizePhysical(value, platform, paths) {
  let normalized = paths.normalize(value);
  if (platform === "win32") {
    if (normalized.startsWith("\\\\?\\UNC\\")) normalized = `\\\\${normalized.slice(8)}`;
    else if (normalized.startsWith("\\\\?\\")) normalized = normalized.slice(4);
    normalized = normalized.toUpperCase();
  }
  return normalized.replace(/[\\/]$/, "");
}

function isContained(root, candidate, paths) {
  const relative = paths.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${paths.sep}`) && relative !== ".." && !paths.isAbsolute(relative));
}

function defaultReparseInspection({ stats, platform }) {
  if (typeof stats.isSymbolicLink === "function" && stats.isSymbolicLink()) return "reparse";
  if (typeof stats.isReparsePoint === "function") return stats.isReparsePoint() ? "reparse" : "passed";
  if (typeof stats.isReparsePoint === "boolean") return stats.isReparsePoint ? "reparse" : "passed";
  if (typeof stats.reparsePoint === "boolean") return stats.reparsePoint ? "reparse" : "passed";
  return platform === "win32" ? "unknown" : "passed";
}

async function inspectPhysicalDirectory({
  physicalPath,
  platform,
  fsOps,
  inspectReparse,
  rootDevice,
}) {
  let stats;
  try {
    stats = await fsOps.lstat(physicalPath);
  } catch {
    fail("CLIENT_CWD_MISSING", "cwd component does not exist");
  }
  let inspection;
  try {
    inspection = await inspectReparse({ physicalPath, stats, platform });
  } catch (error) {
    if (error instanceof ClientIntegrationError) throw error;
    fail("CLIENT_CWD_REPARSE", "cwd reparse status could not be proven safe");
  }
  if (inspection === true) inspection = "reparse";
  if (inspection === false) inspection = "passed";
  if (inspection?.state) inspection = inspection.state;
  if (inspection !== "passed") {
    fail("CLIENT_CWD_REPARSE", "cwd traverses a reparse point or has unknown reparse status");
  }
  if (!stats || typeof stats.isDirectory !== "function" || !stats.isDirectory()) {
    fail("CLIENT_CWD_NOT_DIRECTORY", "cwd component is not a physical directory");
  }
  if (rootDevice !== undefined && stats.dev !== undefined && stats.dev !== rootDevice) {
    fail("CLIENT_CWD_REPARSE", "cwd crosses a physical filesystem boundary");
  }
  return stats;
}

export async function resolveWorkspace({
  workspace,
  cwd,
  platform = process.platform,
  fsOps = fs,
  inspectReparse = defaultReparseInspection,
} = {}) {
  if (
    workspace === null
    || typeof workspace !== "object"
    || Array.isArray(workspace)
    || !WORKSPACE_ID.test(workspace.id ?? "")
    || !isWellFormedString(workspace.root)
    || workspace.root.length === 0
  ) {
    fail("CLIENT_WORKSPACE_UNKNOWN", "workspace binding is invalid or unavailable");
  }
  if (!fsOps || typeof fsOps.lstat !== "function" || typeof fsOps.realpath !== "function") {
    fail("CLIENT_CWD_REPARSE", "workspace filesystem proof operations are unavailable");
  }
  if (typeof inspectReparse !== "function") {
    fail("CLIENT_CWD_REPARSE", "workspace reparse proof is unavailable");
  }

  const paths = pathModule(platform);
  if (!paths.isAbsolute(workspace.root)) {
    fail("CLIENT_WORKSPACE_UNKNOWN", "workspace root must be a configured absolute path");
  }
  const components = parseLogicalCwd(cwd, platform, paths);
  const configuredRoot = paths.resolve(workspace.root);
  const rootStats = await inspectPhysicalDirectory({
    physicalPath: configuredRoot,
    platform,
    fsOps,
    inspectReparse,
  });

  let canonicalRoot;
  try {
    canonicalRoot = await fsOps.realpath(configuredRoot);
  } catch {
    fail("CLIENT_CWD_MISSING", "workspace root cannot be resolved");
  }
  if (normalizePhysical(configuredRoot, platform, paths) !== normalizePhysical(canonicalRoot, platform, paths)) {
    fail("CLIENT_CWD_REPARSE", "workspace root resolves through a reparse point");
  }

  let current = canonicalRoot;
  for (const component of components) {
    const candidate = paths.join(current, component);
    await inspectPhysicalDirectory({
      physicalPath: candidate,
      platform,
      fsOps,
      inspectReparse,
      rootDevice: rootStats.dev,
    });
    let canonicalCandidate;
    try {
      canonicalCandidate = await fsOps.realpath(candidate);
    } catch {
      fail("CLIENT_CWD_MISSING", "cwd component cannot be resolved");
    }
    if (normalizePhysical(candidate, platform, paths) !== normalizePhysical(canonicalCandidate, platform, paths)) {
      fail("CLIENT_CWD_REPARSE", "cwd component resolves through a reparse point");
    }
    if (!isContained(canonicalRoot, canonicalCandidate, paths)) {
      fail("CLIENT_CWD_ESCAPE", "cwd resolves outside the configured workspace");
    }
    current = canonicalCandidate;
  }

  if (!isContained(canonicalRoot, current, paths)) {
    fail("CLIENT_CWD_ESCAPE", "cwd resolves outside the configured workspace");
  }
  const identityComponents = platform === "win32"
    ? components.map((component) => component.replace(/[a-z]/g, (letter) => letter.toUpperCase()))
    : components;
  const workingDirectoryId = `wd1_${semanticSha256({
    workspace_id: workspace.id,
    logical_components: identityComponents,
  })}`;

  return deepFreeze({
    private: { cwd: current },
    descriptor: {
      workspace: {
        id: workspace.id,
        working_directory_id: workingDirectoryId,
      },
    },
    readiness_facts: {
      workspace: { working_directory_id: workingDirectoryId },
    },
  });
}

export { defaultReparseInspection };
