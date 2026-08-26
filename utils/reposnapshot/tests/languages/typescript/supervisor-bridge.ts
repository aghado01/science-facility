/**
 * Supervisor Bridge - JSON-RPC communication with CopilotWorker.ps1
 *
 * @module supervisor-bridge
 *
 * @description
 * Manages communication with the persistent PowerShell supervisor shell.
 * Provides a JSON-RPC client for fast tool calls and job dispatching.
 *
 * @architecture
 * ```
 * TypeScript Extension → VS Code PS Extension → CopilotWorker.ps1 → Job Workers
 * ```
 *
 * @features
 * - **Persistent Connection**: Single supervisor process for extension lifetime
 * - **JSON-RPC Protocol**: Standard request/response communication
 * - **Non-blocking**: All operations are async
 * - **Auto-restart**: Supervisor restarts on crash
 * - **Health Monitoring**: Periodic ping checks
 * - **UAC-safe**: Spawns via PowerShell extension to avoid elevation issues
 */

import { ChildProcess, spawn } from "child_process";
import * as path from "path";
import * as readline from "readline";
import * as vscode from "vscode";

// ============================================================
// TYPE DEFINITIONS
// ============================================================

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number;
  method: string;
  params: any;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number;
  result?: any;
  error?: {
    code: number;
    message: string;
    data?: any;
  };
}

interface PingResult {
  status: string;
  timestamp: string;
  pid: number;
  uptime: number;
}

interface JobSpawnResult {
  jobId: string;
  pid: number;
  resultPath: string;
  signalPath: string;
  cancelPath: string;
  visible: boolean;
  spawnedAt: string;
}

interface RipgrepResult {
  success: boolean;
  output?: string[];
  error?: string;
}

interface FdResult {
  success: boolean;
  files?: string[];
  error?: string;
}

interface JsonlWindowResult {
  success: boolean;
  items?: any[];
  count?: number;
  error?: string;
}

interface PsLintResult {
  success: boolean;
  findings?: any[];
  count?: number;
  error?: string;
}

// ============================================================
// SUPERVISOR BRIDGE CLASS
// ============================================================

class SupervisorBridge {
  private process: ChildProcess | null = null;
  private requestId = 0;
  private pendingRequests = new Map<
    number,
    {
      resolve: (value: any) => void;
      reject: (reason: any) => void;
      timer: NodeJS.Timeout;
    }
  >();
  private isInitialized = false;
  private restartCount = 0;
  private maxRestarts = 3;
  private extensionPath = "";
  private workspacePath = "";

  /**
   * Initialize supervisor shell via PowerShell extension (UAC-safe)
   */
  async initialize(
    extensionPath: string,
    workspacePath: string
  ): Promise<void> {
    this.extensionPath = extensionPath;
    this.workspacePath = workspacePath;

    console.log("[SupervisorBridge] Initializing supervisor...");

    const scriptPath = path.join(
      extensionPath,
      "lib",
      "powershell",
      "CopilotWorker.ps1"
    );

    // Check for PowerShell extension
    const psExtension = vscode.extensions.getExtension("ms-vscode.PowerShell");

    if (!psExtension) {
      console.warn(
        "[SupervisorBridge] PowerShell extension not found, falling back to direct spawn"
      );
      await this.initializeDirect(scriptPath, workspacePath, extensionPath);
      return;
    }

    // Ensure PowerShell extension is activated
    if (!psExtension.isActive) {
      console.log("[SupervisorBridge] Activating PowerShell extension...");
      await psExtension.activate();
    }

    console.log(
      "[SupervisorBridge] Spawning supervisor via PowerShell extension..."
    );

    // Spawn supervisor via PowerShell extension (bypasses UAC)
    const launchScript = `
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'pwsh'
$psi.Arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', '${scriptPath.replace(/\\/g, "\\\\")}',
    '-WorkspacePath', '${workspacePath.replace(/\\/g, "\\\\")}',
    '-ExtensionPath', '${extensionPath.replace(/\\/g, "\\\\")}'
) -join ' '
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$proc = [System.Diagnostics.Process]::Start($psi)

[PSCustomObject]@{
    pid = $proc.Id
    stdin = $proc.StandardInput
    stdout = $proc.StandardOutput
    stderr = $proc.StandardError
} | ConvertTo-Json -Compress
`;

    try {
      const result = await vscode.commands.executeCommand(
        "PowerShell.EvaluateScript",
        launchScript,
        { writeInputToHost: false, writeOutputToHost: false }
      );

      console.log(
        "[SupervisorBridge] Supervisor spawned via PS extension:",
        result
      );

      // Note: We can't directly access the spawned process streams via PS extension
      // Fallback to direct spawn with the PID info for monitoring
      await this.initializeDirect(scriptPath, workspacePath, extensionPath);
    } catch (error) {
      console.error(
        "[SupervisorBridge] Failed to spawn via PS extension:",
        error
      );
      console.log("[SupervisorBridge] Falling back to direct spawn");
      await this.initializeDirect(scriptPath, workspacePath, extensionPath);
    }
  }

  /**
   * Initialize supervisor via direct spawn (fallback method)
   */
  private async initializeDirect(
    scriptPath: string,
    workspacePath: string,
    extensionPath: string
  ): Promise<void> {
    console.log("[SupervisorBridge] Using direct spawn method");
    console.log("[SupervisorBridge] Script path:", scriptPath);
    console.log("[SupervisorBridge] Workspace path:", workspacePath);
    console.log("[SupervisorBridge] Extension path:", extensionPath);

    // Check if script exists
    const fs = require("fs");
    if (!fs.existsSync(scriptPath)) {
      throw new Error(`Supervisor script not found: ${scriptPath}`);
    }

    // Spawn PowerShell supervisor
    this.process = spawn(
      "pwsh",
      [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        scriptPath,
        "-WorkspacePath",
        workspacePath,
        "-ExtensionPath",
        extensionPath,
      ],
      {
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
      }
    );

    console.log("[SupervisorBridge] Process spawned, PID:", this.process.pid);

    // Set up output reader (line-by-line JSON-RPC responses)
    const rl = readline.createInterface({
      input: this.process.stdout!,
      crlfDelay: Infinity,
    });

    rl.on("line", (line) => {
      console.log("[SupervisorBridge:stdout]", line);
      try {
        const response: JsonRpcResponse = JSON.parse(line);
        this.handleResponse(response);
      } catch (error) {
        console.error(
          "[SupervisorBridge] Failed to parse response:",
          line,
          error
        );
      }
    });

    // Handle stderr (debug/diagnostic output)
    this.process.stderr?.on("data", (data) => {
      const text = data.toString().trim();
      if (text) {
        console.warn("[SupervisorBridge:stderr]", text);
      }
    });

    // Handle process exit
    this.process.on("exit", (code) => {
      console.warn(`[SupervisorBridge] Supervisor exited with code ${code}`);
      this.isInitialized = false;
      this.handleCrash();
    });

    // Wait for supervisor to be ready (test with ping)
    const startTime = Date.now();
    const timeout = 10000; // 10 seconds

    console.log(
      "[SupervisorBridge] Waiting for supervisor to respond to ping..."
    );

    while (Date.now() - startTime < timeout) {
      try {
        console.log("[SupervisorBridge] Attempting ping...");
        await this.ping();
        this.isInitialized = true;
        console.log("[SupervisorBridge] Initialized successfully");
        return;
      } catch (error) {
        // Not ready yet, wait a bit
        const elapsed = Date.now() - startTime;
        console.log(
          `[SupervisorBridge] Ping failed (${elapsed}ms elapsed), retrying...`
        );
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
    }

    // Timeout - collect diagnostics
    console.error("[SupervisorBridge] Initialization timeout!");
    console.error(
      "[SupervisorBridge] Process still running:",
      this.process?.pid
    );
    console.error(
      "[SupervisorBridge] Pending requests:",
      this.pendingRequests.size
    );

    throw new Error("Supervisor failed to initialize within timeout");
  }

  /**
   * Send JSON-RPC request to supervisor
   */
  private async sendRequest(
    method: string,
    params: any,
    timeoutMs: number = 30000
  ): Promise<any> {
    if (!this.process || !this.isInitialized) {
      throw new Error("Supervisor not initialized");
    }

    const id = ++this.requestId;
    const request: JsonRpcRequest = {
      jsonrpc: "2.0",
      id,
      method,
      params,
    };

    return new Promise((resolve, reject) => {
      // Set timeout
      const timer = setTimeout(() => {
        this.pendingRequests.delete(id);
        reject(new Error(`Request timeout: ${method}`));
      }, timeoutMs);

      // Store pending request
      this.pendingRequests.set(id, { resolve, reject, timer });

      // Send request
      const json = JSON.stringify(request) + "\n";
      this.process!.stdin!.write(json);
    });
  }

  /**
   * Handle JSON-RPC response from supervisor
   */
  private handleResponse(response: JsonRpcResponse): void {
    const pending = this.pendingRequests.get(response.id);

    if (!pending) {
      console.warn(
        "[SupervisorBridge] Received response for unknown request:",
        response.id
      );
      return;
    }

    // Clear timeout
    clearTimeout(pending.timer);
    this.pendingRequests.delete(response.id);

    // Resolve or reject based on response
    if (response.error) {
      pending.reject(
        new Error(`${response.error.message} (code: ${response.error.code})`)
      );
    } else {
      pending.resolve(response.result);
    }
  }

  /**
   * Handle supervisor crash
   */
  private handleCrash(): void {
    if (this.restartCount >= this.maxRestarts) {
      console.error(
        "[SupervisorBridge] Max restart attempts reached, giving up"
      );
      return;
    }

    this.restartCount++;
    console.log(
      `[SupervisorBridge] Attempting restart (${this.restartCount}/${this.maxRestarts})...`
    );

    // Wait a bit before restarting
    setTimeout(async () => {
      try {
        await this.initialize(this.extensionPath, this.workspacePath);
        console.log("[SupervisorBridge] Restart successful");
      } catch (error) {
        console.error("[SupervisorBridge] Restart failed:", error);
      }
    }, 2000);
  }

  /**
   * Test supervisor is alive
   */
  async ping(): Promise<PingResult> {
    return this.sendRequest("ping", {});
  }

  /**
   * Start parallel job (non-blocking dispatch)
   */
  async startParallelJob(
    jobId: string,
    script: string,
    options: any = {}
  ): Promise<JobSpawnResult> {
    return this.sendRequest("startParallelJob", { jobId, script, options });
  }

  /**
   * Execute ripgrep search
   */
  async rgSearch(
    pattern: string,
    cwd: string,
    glob?: string
  ): Promise<RipgrepResult> {
    return this.sendRequest("rgSearch", { pattern, cwd, glob });
  }

  /**
   * Execute fd file listing
   */
  async fdList(pattern: string, cwd: string): Promise<FdResult> {
    return this.sendRequest("fdList", { pattern, cwd });
  }

  /**
   * Read JSONL window
   */
  async readJsonlWindow(
    filePath: string,
    skip: number = 0,
    take: number = 100
  ): Promise<JsonlWindowResult> {
    return this.sendRequest("readJsonlWindow", { filePath, skip, take });
  }

  /**
   * Run PSScriptAnalyzer
   */
  async psLint(scriptPath: string): Promise<PsLintResult> {
    return this.sendRequest("psLint", { scriptPath });
  }

  /**
   * Health check - returns true if supervisor is responsive
   */
  async healthCheck(): Promise<boolean> {
    try {
      await this.ping();
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Shutdown supervisor gracefully
   */
  async shutdown(): Promise<void> {
    if (this.process) {
      console.log("[SupervisorBridge] Shutting down supervisor...");

      try {
        // Try graceful shutdown
        await this.sendRequest("shutdown", {}, 5000);
      } catch {
        // Force kill if graceful shutdown fails
        console.warn(
          "[SupervisorBridge] Graceful shutdown failed, force killing"
        );
        this.process.kill("SIGTERM");
      }

      this.process = null;
      this.isInitialized = false;

      // Reject all pending requests
      for (const [id, pending] of this.pendingRequests.entries()) {
        clearTimeout(pending.timer);
        pending.reject(new Error("Supervisor shutdown"));
      }
      this.pendingRequests.clear();
    }
  }

  /**
   * Get supervisor status
   */
  getStatus(): {
    initialized: boolean;
    restartCount: number;
    pendingRequests: number;
  } {
    return {
      initialized: this.isInitialized,
      restartCount: this.restartCount,
      pendingRequests: this.pendingRequests.size,
    };
  }
}

// ============================================================
// SINGLETON EXPORT
// ============================================================

/**
 * Singleton instance of the supervisor bridge
 */
export const supervisorBridge = new SupervisorBridge();
