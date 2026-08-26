/**
 * safe-shell.d.ts
 *
 * Type definitions for safe-shell module.
 * Use for importing types without implementation.
 */

// ==================== COMMAND INTERFACES ====================

export interface ShellCommandArgs {
  /** Command string to execute in the interactive shell */
  command: string;

  /** Whether to append newline after command (default: true) */
  newLine?: boolean;

  /** Optional: specific terminal name to target (default: "Copilot") */
  terminalName?: string;
}

export interface ShellCommandResult {
  /** Whether command was dispatched successfully */
  ok: boolean;

  /** Human-readable status message */
  message?: string;

  /** Session ID if console capture is active */
  sessionId?: string;
}

// ==================== CONSOLE READ INTERFACES ====================

export interface ConsoleReadArgs {
  /** Path to console dump JSONL file (default: today's dump) */
  dumpPath?: string;

  /** Number of records to skip from start (pagination) */
  skip?: number;

  /** Number of records to return (default: 100) */
  take?: number;

  /** Filter by record type */
  type?: 'cmd' | 'out';

  /** Filter by session ID (8-char hex string) */
  sessionId?: string;

  /** Filter by sequence number within session */
  seq?: number;
}

export interface ConsoleRecord {
  /** Record type: 'cmd' for command, 'out' for output */
  type: 'cmd' | 'out';

  /** ISO 8601 timestamp with timezone */
  timestamp: string;

  /** Session ID (8-character hex string) */
  session: string;

  /** Sequence number within session (1-based) */
  seq: number;

  // ===== Command Record Fields (type: 'cmd') =====

  /** Command string (present in 'cmd' records) */
  command?: string;

  /** Command content hash (present in 'cmd' records) */
  cmd_hash?: string;

  /** Exit code (0 = success, present in 'cmd' records) */
  exit_code?: number;

  /** Execution duration in milliseconds (present in 'cmd' records) */
  duration_ms?: number;

  /** Current working directory (present in 'cmd' records) */
  cwd?: string;

  // ===== Output Record Fields (type: 'out') =====

  /** Output content hash (present in 'out' records) */
  out_hash?: string;

  /** Output text (present in 'out' records) */
  output?: string;

  /** Whether whitespace was compressed (present in 'out' records) */
  compressed?: boolean;
}

export interface ConsoleDumpInfo {
  /** Full path to today's console dump file */
  dumpPath: string;

  /** Whether the dump file exists on disk */
  exists: boolean;

  /** File size in bytes (only if exists) */
  size?: number;

  /** Date of dump in YYYY-MM-DD format */
  date: string;
}

// ==================== FUNCTION SIGNATURES ====================

/**
 * Send a command to the interactive PowerShell terminal.
 *
 * GARGOYLE-RESISTANT: Returns immediately without waiting for output.
 * Use readConsoleDump() to retrieve results from JSONL after execution.
 *
 * @param args - Command and options
 * @returns Promise with acknowledgment (not output!)
 */
export function sendToInteractiveShell(
  args: ShellCommandArgs
): Promise<ShellCommandResult>;

/**
 * Read console dump records from JSONL file.
 *
 * GARGOYLE-RESISTANT: Reads from file artifacts, not live terminal output.
 *
 * @param args - Query parameters (filters, pagination)
 * @returns Array of console records (commands and/or outputs)
 */
export function readConsoleDump(
  args?: ConsoleReadArgs
): Promise<ConsoleRecord[]>;

/**
 * Get the most recent console records.
 * Convenience wrapper around readConsoleDump.
 *
 * @param count - Number of recent records to retrieve (default: 10)
 * @returns Array of most recent console records
 */
export function getRecentConsoleRecords(
  count?: number
): Promise<ConsoleRecord[]>;

/**
 * Get the last command and its output from console dump.
 *
 * @returns Object with command and output records, or null if not found
 */
export function getLastCommand(): Promise<{
  cmd: ConsoleRecord;
  out: ConsoleRecord;
} | null>;

/**
 * Get commands with non-zero exit codes (errors).
 *
 * @param limit - Maximum number of error commands to return (default: 10)
 * @returns Array of command records that failed
 */
export function getErrorCommands(
  limit?: number
): Promise<ConsoleRecord[]>;

/**
 * Get path to today's console dump file.
 * Uses COPILOT_GLOBAL_HOME env var or falls back to workspace .copilot
 *
 * @returns Absolute path to YYYY-MM-DD.jsonl file
 */
export function getTodaysDumpPath(): string;

/**
 * Get info about today's console dump file.
 *
 * @returns Object with path, existence, size, and date
 */
export function getDumpInfo(): ConsoleDumpInfo;

// ==================== CONSTANTS ====================

/**
 * Instructions for disabling native terminal tools.
 * Add this to your copilot-instructions.md or global instructions.
 */
export const DISABLE_NATIVE_TOOLS_INSTRUCTIONS: string;

// ==================== DEFAULT EXPORT ====================

declare const safeShell: {
  sendToInteractiveShell: typeof sendToInteractiveShell;
  readConsoleDump: typeof readConsoleDump;
  getRecentConsoleRecords: typeof getRecentConsoleRecords;
  getLastCommand: typeof getLastCommand;
  getErrorCommands: typeof getErrorCommands;
  getTodaysDumpPath: typeof getTodaysDumpPath;
  getDumpInfo: typeof getDumpInfo;
  DISABLE_NATIVE_TOOLS_INSTRUCTIONS: typeof DISABLE_NATIVE_TOOLS_INSTRUCTIONS;
};

export default safeShell;
