# brewery/

Dependency recipes for the `nushell-mcp` package. A recipe specifies **how to acquire, verify, and materialize** a pinned dependency into `deps/`.

Recipes are tracked in Git; the materializations they produce under `deps/` (except `README.md`) are gitignored.

## Layout

| Recipe | Target / Shelf | Pin Specification | Restore Script |
|---|---|---|---|
| `brewery/nushell/` | `deps/nushell/` | `pin.json` | `restore-nushell.ps1`, `install-latest.sh` |

## nushell

The pinned Nushell runtime engine and bundled official plugins.

### `pin.json`
Declares the pinned Nushell version (`0.114.1`), official GitHub release URL, and platform artifact metadata (archive URL, SHA-256 hash, and executable name) across platforms (`windows-x64`, `windows-arm64`, `linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`).

### `restore-nushell.ps1`
PowerShell bootstrap script that resolves against `pin.json`, downloads the verified platform asset, extracts the binary and plugins to `deps/nushell/`, and runs smoke tests.

#### Usage (PowerShell)

```powershell
# Restore if missing or hash mismatch (idempotent):
./mcp/nushell-mcp/brewery/nushell/restore-nushell.ps1

# Force re-download and restore:
./mcp/nushell-mcp/brewery/nushell/restore-nushell.ps1 -Force

# Skip smoke tests:
./mcp/nushell-mcp/brewery/nushell/restore-nushell.ps1 -SkipTests
```

### `install-latest.sh`
Bash script that queries GitHub release inventory for `nushell/nushell`, identifies the latest OS-appropriate portable release archive (MSVC zip on Windows, GNU tar.gz on Linux, Darwin tar.gz on macOS), verifies SHA-256 integrity, extracts `nu` and bundled plugins, stages them into `deps/nushell/`, and writes `restore-receipt.json`.

#### Usage (Bash)

```bash
# Query latest release and install if newer/missing:
./mcp/nushell-mcp/brewery/nushell/install-latest.sh

# Force reinstall:
./mcp/nushell-mcp/brewery/nushell/install-latest.sh --force

# Dry-run inspection (identify platform & matching asset without downloading):
./mcp/nushell-mcp/brewery/nushell/install-latest.sh --dry-run

# Install specific release tag:
./mcp/nushell-mcp/brewery/nushell/install-latest.sh --version 0.114.1
```

