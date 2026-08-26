/**
 * ps-linter.ts
 *
 * PowerShell static analysis and linting via PSLinter.v2.psm1
 * Provides validation for Copilot-generated PowerShell and user scripts
 */

import { spawnSync } from "child_process";
import * as path from "path";

/*
 * ===========================
 * WHEN TO USE PS-LINTER
 * ===========================
 *
 * 1. Post-Generation Validation
 *    - After generating PowerShell scripts, validate immediately
 *    - Catch syntax errors, missing requirements, dangerous patterns
 *
 * 2. Parse Error Debugging
 *    - PSDetectStructuralLexingErrors finds unbalanced braces, unterminated strings
 *    - Clear diagnostics help fix syntax issues quickly
 *
 * 3. Security Review
 *    - Detects Invoke-Expression, command injection, interpolated commands
 *    - Identifies suspicious Unicode characters (NBSP, zero-width, bidi controls)
 *
 * 4. Convention Enforcement
 *    - Header order (using → #Requires → docstring)
 *    - Function help validation (.SYNOPSIS + .DESCRIPTION)
 *    - Module manifest metadata (version, CompatiblePSEditions)
 *
 * ===========================
 * PROFILE SELECTION STRATEGY
 * ===========================
 *
 * Use 'Strict' for new code generation:
 *   - Enforces PS 7.5+ (#Requires -Version 7.5)
 *   - Security rules (dangerous invocation, interpolation)
 *   - Full validation (structure, help, manifests)
 *
 * Use 'Formatting' for style checks only:
 *   - Indentation, whitespace, bracket placement
 *   - No security or logic rules
 *   - Focus on consistency
 *
 * Use 'Repo' for repository-wide validation:
 *   - Balanced rules (errors + warnings + info)
 *   - All custom rules + select built-in rules
 *   - Default profile for general purpose
 *
 * Use 'Gallery' for PSGallery publishing:
 *   - Passes through to PSScriptAnalyzer's built-in 'PSGallery' preset
 *   - Module publication requirements
 *
 * ===========================
 * BEST PRACTICES
 * ===========================
 *
 * - Lint immediately after generation (catch errors early)
 * - Parse structural errors first (syntax before style)
 * - Review security warnings (dangerous invocation, interpolation)
 * - Apply fixes incrementally (test after each auto-fix)
 * - Use severity filtering to focus on critical issues first
 */

// ============================================================================
// Types & Interfaces
// ============================================================================

export interface PSLintArgs {
  /** Path to file or directory to lint */
  path: string;
  /** Linting profile to use */
  profile?: "Strict" | "Formatting" | "Repo" | "Gallery";
  /** Recurse into subdirectories (for directory paths) */
  recurse?: boolean;
  /** Apply auto-fixes where available */
  fix?: boolean;
  /** Filter results by severity */
  severity?: ("Error" | "Warning" | "Information" | "ParseError")[];
}

export interface PSLintResult {
  /** Name of the rule that triggered */
  ruleName: string;
  /** Severity level */
  severity: "Error" | "Warning" | "Information" | "ParseError";
  /** Script name or path */
  scriptName: string;
  /** Line number where issue occurs */
  line: number;
  /** Column number where issue occurs */
  column: number;
  /** Diagnostic message */
  message: string;
  /** Code extent (snippet of affected code) */
  extent?: string;
}

// ============================================================================
// Argument Builder
// ============================================================================

/**
 * Builds PowerShell arguments for Invoke-PSLinter
 */
function buildPSLintArgs(args: PSLintArgs): string[] {
  const psArgs: string[] = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
  ];

  // Get module path (vendored in lib/powershell/)
  const modulePath = path.join(
    __dirname,
    "..",
    "lib",
    "powershell",
    "PSLinter.v2.psm1"
  );

  // Build command string
  const cmdParts: string[] = [
    `Import-Module '${modulePath}' -Force;`,
    `Invoke-PSLinter`,
    `-Path '${args.path}'`,
  ];

  if (args.profile) {
    cmdParts.push(`-Profile ${args.profile}`);
  }

  if (args.recurse) {
    cmdParts.push("-Recurse");
  }

  if (args.fix) {
    cmdParts.push("-Fix");
  }

  if (args.severity && args.severity.length > 0) {
    const severityList = args.severity.map((s) => `'${s}'`).join(",");
    cmdParts.push(`-Severity @(${severityList})`);
  }

  // Add output as JSON for easier parsing
  cmdParts.push("| ConvertTo-Json -Depth 10");

  psArgs.push(cmdParts.join(" "));

  return psArgs;
}

// ============================================================================
// Output Parser
// ============================================================================

/**
 * Parses PSScriptAnalyzer DiagnosticRecord output
 */
function parsePSLintOutput(stdout: string): PSLintResult[] {
  if (!stdout || stdout.trim().length === 0) {
    return [];
  }

  try {
    const rawOutput = JSON.parse(stdout);

    // Handle both single object and array responses
    const records = Array.isArray(rawOutput) ? rawOutput : [rawOutput];

    return records.map((record: any) => ({
      ruleName: record.RuleName || "Unknown",
      severity: record.Severity || "Warning",
      scriptName: record.ScriptName || record.ScriptPath || "",
      line: record.Line || record.Extent?.StartLineNumber || 0,
      column: record.Column || record.Extent?.StartColumnNumber || 0,
      message: record.Message || "",
      extent: record.Extent?.Text || undefined,
    }));
  } catch (parseError) {
    // If JSON parsing fails, try to extract diagnostics from text output
    console.error("Failed to parse PSLinter output as JSON:", parseError);

    // Return empty array if parsing fails completely
    return [];
  }
}

// ============================================================================
// Main Function
// ============================================================================

/**
 * Lint PowerShell scripts using PSLinter.v2
 *
 * @param args Linting configuration
 * @returns Array of diagnostic results
 * @throws Error if linting process fails
 */
export function lintPowerShell(args: PSLintArgs): PSLintResult[] {
  const psArgs = buildPSLintArgs(args);

  const result = spawnSync("pwsh", psArgs, {
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024, // 10MB buffer for large results
  });

  if (result.error) {
    throw new Error(`Failed to spawn PowerShell: ${result.error.message}`);
  }

  if (result.status !== 0) {
    // Non-zero exit could mean lint issues found or actual error
    // Check stderr for actual errors
    if (result.stderr && result.stderr.trim().length > 0) {
      throw new Error(`PSLinter error: ${result.stderr}`);
    }
  }

  return parsePSLintOutput(result.stdout);
}

// ============================================================================
// Output Formatter
// ============================================================================

/**
 * Format lint results for display in VS Code chat
 */
export function formatLintResults(results: PSLintResult[]): string {
  if (results.length === 0) {
    return "✅ No linting issues found!";
  }

  // Group by severity
  const errors = results.filter((r) => r.severity === "Error");
  const warnings = results.filter((r) => r.severity === "Warning");
  const info = results.filter(
    (r) => r.severity === "Information" || r.severity === "ParseError"
  );

  let output = `🔍 Found ${results.length} issue${
    results.length > 1 ? "s" : ""
  }:\n\n`;

  // Format errors
  if (errors.length > 0) {
    output += `**❌ Errors (${errors.length}):**\n`;
    errors.forEach((e) => {
      output += `- Line ${e.line}:${e.column} [${e.ruleName}] ${e.message}\n`;
      if (e.extent) {
        output += `  \`${e.extent.trim()}\`\n`;
      }
    });
    output += "\n";
  }

  // Format warnings
  if (warnings.length > 0) {
    output += `**⚠️  Warnings (${warnings.length}):**\n`;
    warnings.forEach((w) => {
      output += `- Line ${w.line}:${w.column} [${w.ruleName}] ${w.message}\n`;
    });
    output += "\n";
  }

  // Format info
  if (info.length > 0) {
    output += `**ℹ️  Information (${info.length}):**\n`;
    info.forEach((i) => {
      output += `- Line ${i.line}:${i.column} [${i.ruleName}] ${i.message}\n`;
    });
  }

  return output.trim();
}
