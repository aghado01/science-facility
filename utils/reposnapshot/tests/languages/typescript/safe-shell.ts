/**
 * safe-shell.ts
 *
 * Gargoyle-resistant shell access for VS Code Copilot.
 *
 * REPLACES native terminal tools (run_in_terminal, getTerminalOutput, etc.)
 * with safe alternatives that:
 * 1. Send commands to interactive shell WITHOUT waiting
 * 2. Read results from console dump files (JSONL) instead of live terminal
 * 3. Use jso-engine primitives for JSONL operations
 *
 * ============================================================================
 * EXTERNAL HOST DEPENDENCY CONTRACT
 * ============================================================================
 *
 * This module does NOT import or depend on any PowerShell console capture module.
 * Instead, it depends on the JSONL dump file format produced by an external
 * console system (e.g., CyberneticConsole-Lite.psm1) that must be configured
 * by the user in their PowerShell profile.
 *
 * REQUIRED EXTERNAL SYSTEM:
 * - A PowerShell console module that captures terminal activity
 * - Must write JSONL files to: $env:COPILOT_GLOBAL_HOME/dumps/YYYY-MM-DD.jsonl
 * - Must use the ConsoleRecord schema defined below
 *
 * INSTALLATION (User's PowerShell Profile):
 * ```powershell
 * Import-Module "C:\Path\To\CyberneticConsole-Lite.psm1" -Force
 * Initialize-CyberneticConsole -Scope Global
 * ```
 *
 * DUMP FILE SCHEMA:
 * Each line must be a JSON object with these fields (see ConsoleRecord interface):
 *
 * Command records (type="cmd"):
 * {
 *   "type": "cmd",
 *   "timestamp": "2025-11-17T10:30:00.000Z",  // ISO 8601
 *   "session": "a1b2c3d4",                     // 8-char hex session ID
 *   "seq": 1,                                   // Sequence number
 *   "cmd_hash": "abc123",                       // Content hash
 *   "cwd": "C:\\Path",                          // Working directory
 *   "command": "Get-Date",                      // Command text
 *   "exit_code": 0,                             // Exit code (optional)
 *   "duration_ms": 45                           // Duration (optional)
 * }
 *
 * Output records (type="out"):
 * {
 *   "type": "out",
 *   "timestamp": "2025-11-17T10:30:00.045Z",
 *   "session": "a1b2c3d4",
 *   "seq": 2,
 *   "out_hash": "def456",
 *   "output": "Sunday, November 17, 2025...",  // Output text
 *   "compressed": false                         // Whether output is compressed
 * }
 *
 * This contract allows the console implementation to evolve independently
 * of this extension, as long as the dump file format remains compatible.
 *
 * @module safe-shell
 */

import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import { invokeCybernetics } from "./cybernetics-bridge";

// ==================== INTERFACES ====================

export interface ShellCommandArgs {
  /** Command string to execute in the interactive shell */
  command: string;
  /** Whether to append newline (default: true) */
  newLine?: boolean;
  /** Optional: specific terminal name to target */
  terminalName?: string;
}

export interface ShellCommandResult {
  /** Success flag */
  ok: boolean;
  /** Human-readable message */
  message?: string;
  /** Optional: session ID if console capture is active */
  sessionId?: string;
}

export interface ConsoleReadArgs {
  /** Path to console dump JSONL file */
  dumpPath?: string;
  /** Number of records to skip from start (pagination) */
  skip?: number;
  /** Number of records to return (default: 100) */
  take?: number;
  /** Filter by record type: 'cmd' or 'out' */
  type?: "cmd" | "out";
  /** Filter by session ID */
  sessionId?: string;
  /** Filter by sequence number */
  seq?: number;
}

export interface ConsoleRecord {
  /** Record type: 'cmd' or 'out' */
  type: "cmd" | "out";
  /** ISO 8601 timestamp */
  timestamp: string;
  /** Session ID (8-char hex) */
  session: string;
  /** Sequence number within session */
  seq: number;
  /** Content hash (string) */
  cmd_hash?: string;
  /** Output hash (for 'out' records) */
  out_hash?: string;
  /** Current working directory (for 'cmd' records) */
  cwd?: string;
  /** Command string (for 'cmd' records) */
  command?: string;
  /** Exit code (for 'cmd' records) */
  exit_code?: number;
  /** Duration in milliseconds (for 'cmd' records) */
  duration_ms?: number;
  /** Output text (for 'out' records) */
  output?: string;
  /** Whether output was compressed (for 'out' records) */
  compressed?: boolean;
}

export interface ConsoleDumpInfo {
  /** Path to today's dump file */
  dumpPath: string;
  /** Whether dump file exists */
  exists: boolean;
  /** File size in bytes (if exists) */
  size?: number;
  /** Date of dump (YYYY-MM-DD) */
  date: string;
}

function normalizeConsoleRecord(record: unknown): ConsoleRecord | null {
  if (!record || typeof record !== "object") {
    return null;
  }

  const candidate = record as Record<string, unknown>;
  if (candidate.type !== "cmd" && candidate.type !== "out") {
    return null;
  }

  if (typeof candidate.timestamp !== "string") {
    return null;
  }

  if (typeof candidate.session !== "string") {
    return null;
  }

  if (typeof candidate.seq !== "number") {
    return null;
  }

  return candidate as ConsoleRecord;
}

function normalizeConsoleRecords(records: unknown): ConsoleRecord[] {
  const items = Array.isArray(records) ? records : [records];
  return items
    .map((record) => normalizeConsoleRecord(record))
    .filter((record): record is ConsoleRecord => record !== null);
}

function readConsoleDumpFallback(args: ConsoleReadArgs = {}): ConsoleRecord[] {
  const dumpPath = args.dumpPath || getTodaysDumpPath();
  if (!fs.existsSync(dumpPath)) {
    return [];
  }

  const records = fs
    .readFileSync(dumpPath, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim())
    .map((line) => {
      try {
        return JSON.parse(line) as unknown;
      } catch {
        return null;
      }
    })
    .filter((record): record is unknown => record !== null);

  let filtered = normalizeConsoleRecords(records);

  if (args.type) {
    filtered = filtered.filter((record) => record.type === args.type);
  }

  if (args.sessionId) {
    filtered = filtered.filter((record) => record.session === args.sessionId);
  }

  if (args.seq !== undefined) {
    filtered = filtered.filter((record) => record.seq === args.seq);
  }

  const skip = args.skip ?? 0;
  const take = args.take ?? 100;
  return filtered.slice(skip, skip + take);
}

// ==================== CORE FUNCTIONS ====================

/**
 * Get path to today's console dump file.
 * Uses COPILOT_GLOBAL_HOME env var or falls back to workspace .copilot
 */
export function getTodaysDumpPath(): string {
  const cyberneticPath = invokeCybernetics<string>(
    "CyberneticConsole.psm1",
    "Get-CyberneticDumpPath"
  );

  if (typeof cyberneticPath === "string" && cyberneticPath.length > 0) {
    return cyberneticPath;
  }

  const today = new Date().toISOString().split("T")[0]; // YYYY-MM-DD
  const globalHome = process.env.COPILOT_GLOBAL_HOME;

  if (globalHome) {
    return path.join(globalHome, "dumps", `${today}.jsonl`);
  }

  // Fallback: look for .copilot in workspace root
  const workspaceFolders = vscode.workspace.workspaceFolders;
  if (workspaceFolders && workspaceFolders.length > 0) {
    const wsRoot = workspaceFolders[0].uri.fsPath;
    return path.join(wsRoot, ".copilot", "dumps", `${today}.jsonl`);
  }

  throw new Error(
    "Cannot determine console dump path: COPILOT_GLOBAL_HOME not set and no workspace open"
  );
}

/**
 * Get info about today's console dump file.
 */
export function getDumpInfo(): ConsoleDumpInfo {
  const cyberneticInfo = invokeCybernetics<Record<string, unknown>>(
    "CyberneticConsole.psm1",
    "Get-CyberneticDumpInfo"
  );

  if (cyberneticInfo) {
    return {
      dumpPath: String(
        cyberneticInfo.DumpPath ?? cyberneticInfo.dumpPath ?? getTodaysDumpPath()
      ),
      exists: Boolean(cyberneticInfo.Exists ?? cyberneticInfo.exists),
      size:
        typeof (cyberneticInfo.Size ?? cyberneticInfo.size) === "number"
          ? Number(cyberneticInfo.Size ?? cyberneticInfo.size)
          : undefined,
      date: String(
        cyberneticInfo.Date ??
          cyberneticInfo.date ??
          new Date().toISOString().split("T")[0]
      ),
    };
  }

  const dumpPath = getTodaysDumpPath();
  const date = new Date().toISOString().split("T")[0];

  const exists = fs.existsSync(dumpPath);
  const size = exists ? fs.statSync(dumpPath).size : undefined;

  return { dumpPath, exists, size, date };
}

/**
 * Send a command to the interactive PowerShell terminal.
 * Returns immediately without waiting for output.
 * Use readConsoleDump() to retrieve results from JSONL after execution.
 *
 * @param args - Command and options
 * @returns Promise with acknowledgment (not output!)
 */
export async function sendToInteractiveShell(
  args: ShellCommandArgs
): Promise<ShellCommandResult> {
  const newLine = args.newLine ?? true;
  const targetName = args.terminalName || "Copilot";

  // Find or create the Copilot PowerShell terminal
  let term = vscode.window.terminals.find(
    (t) =>
      t.name.includes(targetName) ||
      t.name.includes("PowerShell (CP)") ||
      t.name.includes("Powershell (Copilot)")
  );

  if (!term) {
    // Create a new terminal with the Copilot profile
    term = vscode.window.createTerminal({
      name: "Copilot PS",
      shellPath: process.env.PORTABLE_ROOT
        ? path.join(
            process.env.PORTABLE_ROOT,
            "Apps",
            "PowerShell",
            "7CP",
            "pwsh.exe"
          )
        : "pwsh",
    });
  }

  // Show terminal without stealing focus
  term.show(false);

  // Send command (fire and forget!)
  term.sendText(args.command, newLine);

  // Try to get session ID from environment
  const sessionId = process.env.VSCODE_SESSION_ID;

  return {
    ok: true,
    message: `Command dispatched to interactive shell (${term.name})`,
    sessionId,
  };
}

/**
 * Read console dump records using jso-engine primitives.
 *Reads from file artifacts, not live terminal output.
 * @param args - Query parameters
 * @returns Array of console records
 */
export async function readConsoleDump(
  args: ConsoleReadArgs = {}
): Promise<ConsoleRecord[]> {
  const cyberneticRecords = invokeCybernetics<unknown>(
    "CyberneticConsole.psm1",
    "Read-CyberneticConsoleDump",
    {
      DumpPath: args.dumpPath,
      Skip: args.skip ?? 0,
      Take: args.take ?? 100,
      Type: args.type,
      SessionId: args.sessionId,
      Seq: args.seq,
    },
    { forceArray: true }
  );

  if (cyberneticRecords) {
    return normalizeConsoleRecords(cyberneticRecords);
  }

  return readConsoleDumpFallback(args);
}

/**
 * Get the most recent console records.
 * Convenience wrapper around readConsoleDump.
 *
 * @param count - Number of recent records to retrieve (default: 10)
 * @returns Array of most recent console records
 */
export async function getRecentConsoleRecords(
  count: number = 10
): Promise<ConsoleRecord[]> {
  const info = getDumpInfo();
  if (!info.exists) {
    return [];
  }

  // Read all records and take last N
  // (More efficient would be to read file backwards, but this is simpler)
  const allRecords = await readConsoleDump({ take: 1000 });
  return allRecords.slice(-count);
}

/**
 * Get the last command and its output from console dump.
 *
 * @returns Object with command and output records, or null if not found
 */
export async function getLastCommand(): Promise<{
  cmd: ConsoleRecord;
  out: ConsoleRecord;
} | null> {
  const records = await getRecentConsoleRecords(20);

  // Find last cmd record
  const cmdRecords = records.filter((r) => r.type === "cmd");
  if (cmdRecords.length === 0) {
    return null;
  }

  const lastCmd = cmdRecords[cmdRecords.length - 1];

  // Find corresponding output
  const outRecord = records.find(
    (r) =>
      r.type === "out" && r.seq === lastCmd.seq && r.session === lastCmd.session
  );

  if (!outRecord) {
    return null;
  }

  return { cmd: lastCmd, out: outRecord };
}

/**
 * Get commands with non-zero exit codes (errors).
 *
 * @param limit - Maximum number of error commands to return
 * @returns Array of command records that failed
 */
export async function getErrorCommands(
  limit: number = 10
): Promise<ConsoleRecord[]> {
  const records = await readConsoleDump({ type: "cmd", take: 500 });
  return records.filter((r) => r.exit_code && r.exit_code !== 0).slice(-limit);
}

// ==================== HELPER: DISABLE NATIVE TOOLS ====================

/**
 * Instructions for disabling native terminal tools.
 *
 * Add this to your copilot-instructions.md or global instructions:
 */
export const DISABLE_NATIVE_TOOLS_INSTRUCTIONS = `
## Terminal Tool Usage (CRITICAL)

**PROBLEM:** Native terminal tools (\`run_in_terminal\`, \`getTerminalOutput\`)
hang indefinitely when awaiting command output, creating timeouts and blocking.

**SOLUTION:** Use fire-and-forget dispatch + read from JSONL dumps instead.

**USE THESE TOOLS:**
- \`sendToInteractiveShell\` - Dispatch command, returns immediately (no await on output)
- \`readConsoleDump\` - Read command history from \`.copilot/dumps/YYYY-MM-DD.jsonl\`
- \`getLastCommand\` - Get most recent command + output pair
- \`getErrorCommands\` - Find commands with non-zero exit codes

**PATTERN:**
1. \`await sendToInteractiveShell({ command: "Get-Process" })\` → returns instantly
2. Wait 1-2 seconds for command to execute in terminal
3. \`await getLastCommand()\` → reads result from dump file, not terminal

**WHY IT WORKS:** Commands write to JSONL as they execute. Reading files never blocks.
`;

// ==================== EXPORTS ====================

export default {
  // Core functions
  sendToInteractiveShell,
  readConsoleDump,
  getRecentConsoleRecords,
  getLastCommand,
  getErrorCommands,
  getTodaysDumpPath,
  getDumpInfo,

  // Instructions
  DISABLE_NATIVE_TOOLS_INSTRUCTIONS,
};
