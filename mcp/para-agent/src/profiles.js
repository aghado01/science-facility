/**
 * Nushell Profile Resolution & Configuration Manager
 */

import path from "node:path";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = path.resolve(__dirname, "..");
const PROFILES_DIR = path.join(PACKAGE_ROOT, "profiles");

export const AVAILABLE_PROFILES = ["backend", "para-agent", "primary-agent"];

/**
 * Returns CLI flags and environment overlays for a named Nushell profile.
 *
 * @param {string} profileName - 'backend' | 'para-agent' | 'primary-agent'
 * @param {object} opts
 * @param {string} [opts.workspaceRoot] - Workspace root directory
 */
export function getNuProfileConfig(profileName = "para-agent", { workspaceRoot = process.cwd() } = {}) {
  const selected = AVAILABLE_PROFILES.includes(profileName) ? profileName : "para-agent";
  const profileDir = path.join(PROFILES_DIR, selected);
  const envFile = path.join(profileDir, "env.nu");
  const configFile = path.join(profileDir, "config.nu");

  const args = [];
  if (existsSync(envFile)) {
    args.push("--env-config", envFile);
  }
  if (existsSync(configFile)) {
    args.push("--config", configFile);
  }

  const env = {
    PARA_PKG_ROOT: PACKAGE_ROOT,
    PARA_WORKSPACE_ROOT: workspaceRoot,
  };

  return {
    name: selected,
    profileDir,
    args,
    env,
  };
}
