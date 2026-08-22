"""MCP server for executing PowerShell in a configured runtime."""

import os
import shutil
import subprocess
from pathlib import Path

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.server import Settings as FastMCPSettings


POWERSHELL_EXECUTABLE_ENV_VAR = "MCP_POWERSHELL_EXECUTABLE"
POWERSHELL_PROFILE_ENV_VAR = "MCP_POWERSHELL_PROFILE"
MCP_ROOT = Path(__file__).resolve().parent
DEFAULT_POWERSHELL_EXECUTABLE = (
    MCP_ROOT / "deps" / "bin" / "pwsh" / "pwsh.exe"
)
DEFAULT_POWERSHELL_PROFILE = (
    MCP_ROOT / "scripts" / "pwsh" / "profile-pwsh.ps1"
)


# MCP 1.29 defines Settings before the forward-referenced FastMCP type is
# complete. Rebuilding here gives pydantic-settings the resolved lifespan type.
FastMCPSettings.model_rebuild()


# Initialize the MCP server
mcp = FastMCP("pwsh_exec")


def _resolve_powershell_executable() -> str:
    configured = os.environ.get(POWERSHELL_EXECUTABLE_ENV_VAR)
    if configured and configured.strip():
        candidate = Path(configured.strip())
        if candidate.is_file():
            return str(candidate.resolve())
        return configured.strip()
    return str(DEFAULT_POWERSHELL_EXECUTABLE)


def _resolve_powershell_profile() -> str | None:
    configured = os.environ.get(POWERSHELL_PROFILE_ENV_VAR)
    if configured is not None:
        if not configured.strip():
            return None
        candidate = Path(configured.strip())
        if candidate.is_file():
            return str(candidate.resolve())
        return configured.strip()
    if DEFAULT_POWERSHELL_PROFILE.is_file():
        return str(DEFAULT_POWERSHELL_PROFILE)
    return None


def _build_powershell_code(code: str) -> str:
    commands = [
        "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); "
        "$OutputEncoding = [Console]::OutputEncoding; "
        f"if ($env:{POWERSHELL_PROFILE_ENV_VAR} -and $env:{POWERSHELL_PROFILE_ENV_VAR}.Trim()) {{ "
        f"$__mcpPowerShellProfile = (Resolve-Path -LiteralPath $env:{POWERSHELL_PROFILE_ENV_VAR} -ErrorAction Stop).ProviderPath; "
        "$null = . $__mcpPowerShellProfile; "
        "Remove-Variable __mcpPowerShellProfile -ErrorAction SilentlyContinue; "
        "}; "
    ]

    commands.append(code)
    return "".join(commands)


def _run_powershell(code: str) -> str:
    powershell_executable = _resolve_powershell_executable()
    powershell_profile = _resolve_powershell_profile()
    powershell_code = _build_powershell_code(code)

    child_env = os.environ.copy()
    if powershell_profile:
        child_env[POWERSHELL_PROFILE_ENV_VAR] = powershell_profile
    else:
        child_env.pop(POWERSHELL_PROFILE_ENV_VAR, None)

    # Run the PowerShell command
    process = subprocess.Popen(
        [powershell_executable, "-NoProfile", "-Command", powershell_code],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=child_env,
    )

    # Get the output and error messages
    output, error = process.communicate()

    if process.returncode != 0:
        return f"Error: {error}"

    return output


# Define the command to run PowerShell code
@mcp.tool()
def run_powershell(code: str) -> str:
    """Runs PowerShell code and returns the output."""
    return _run_powershell(code)


if __name__ == "__main__":
    # Run the MCP server
    mcp.run()
