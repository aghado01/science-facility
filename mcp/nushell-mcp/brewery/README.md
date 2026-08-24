# brewery/

Dependency recipes for the `nushell-mcp` package. A recipe specifies **how to acquire, verify, and materialize** a pinned dependency into `deps/`.

Recipes are tracked in Git; the materializations they produce under `deps/` (except `README.md`) are gitignored.

## Layout

| Recipe | Target / Shelf | Pin Specification | Restore / Upgrade Scripts |
|---|---|---|---|
| `brewery/nushell/` | `deps/nushell/` | `pin.json` | `restore-nushell.ps1`, `upgrade-nushell.sh`, `upgrade-nushell.ps1` |

## nushell

The pinned Nushell runtime engine and bundled official plugins.

### `pin.json`
Declares the pinned Nushell version, official GitHub release URL, and platform artifact metadata (archive URL, SHA-256 hash, and executable name) across standard platforms (`windows-x64`, `windows-arm64`, `linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`).

### `restore-nushell.ps1`
PowerShell bootstrap script that resolves against `pin.json`, downloads the verified platform asset, extracts the binary and plugins to `deps/nushell/`, and runs smoke tests.

```powershell
# Restore if missing or hash mismatch (idempotent):
./mcp/nushell-mcp/brewery/nushell/restore-nushell.ps1

# Force re-download and restore:
./mcp/nushell-mcp/brewery/nushell/restore-nushell.ps1 -Force

# Skip smoke tests:
./mcp/nushell-mcp/brewery/nushell/restore-nushell.ps1 -SkipTests
```

### `upgrade-nushell.sh` / `upgrade-nushell.ps1`
Upgrade scripts (Bash / PowerShell) that:
1. Query GitHub release inventory for `nushell/nushell` (latest or `--version <tag>`).
2. Identify the OS-appropriate portable archive (MSVC zip on Windows, GNU tar.gz on Linux, Darwin tar.gz on macOS).
3. Verify archive SHA-256 against release `SHA256SUMS`.
4. **Programmatically update `pin.json`** with all standard platform artifact URLs and checksums.
5. Deploy the complete release (engine binary + bundled plugins + tools) into `deps/nushell/`.
6. Write `restore-receipt.json` and execute smoke tests.

#### Usage (Bash)

```bash
# Upgrade to latest release and update pin.json:
./mcp/nushell-mcp/brewery/nushell/upgrade-nushell.sh

# Preview upgrade without downloading or updating pin:
./mcp/nushell-mcp/brewery/nushell/upgrade-nushell.sh --dry-run

# Upgrade to a specific release tag:
./mcp/nushell-mcp/brewery/nushell/upgrade-nushell.sh --version 0.115.1
```

#### Usage (PowerShell)

```powershell
# Upgrade to latest release and update pin.json:
./mcp/nushell-mcp/brewery/nushell/upgrade-nushell.ps1

# Preview upgrade:
./mcp/nushell-mcp/brewery/nushell/upgrade-nushell.ps1 -DryRun

# Upgrade to a specific release tag:
./mcp/nushell-mcp/brewery/nushell/upgrade-nushell.ps1 -Version 0.115.1
```


