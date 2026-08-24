# brewery/

Dependency recipes for the `nushell-mcp` package. A recipe specifies **how to acquire, verify, and materialize** a pinned dependency into `deps/`.

Recipes are tracked in Git; the materializations they produce under `deps/` (except `README.md`) are gitignored.

## Layout

| Recipe | Target / Shelf | Pin Specification | Restore Script |
|---|---|---|---|
| `brewery/nushell/` | `deps/nushell/` | `pin.json` | `restore-nushell.ps1` |

## nushell

The pinned Nushell runtime engine and bundled official plugins.

### `pin.json`
Declares the pinned Nushell version (`0.114.1`), official GitHub release URL, and platform artifact metadata (archive URL, SHA-256 hash, and executable name) across platforms (`windows-x64`, `windows-arm64`, `linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`).

### `restore-nushell.ps1`
Cross-platform bootstrap script that:
1. Detects the host operating system and CPU architecture.
2. Resolves the corresponding artifact entry in `pin.json`.
3. Downloads the release archive from GitHub to a temporary scratch directory.
4. Verifies the archive SHA-256 checksum against the pin.
5. Extracts the distribution and verifies the restored `nu` executable version.
6. Stages the engine and plugins into `deps/nushell/`.
7. Emits a `deps/nushell/restore-receipt.json` stamp.
8. Runs a smoke test against the test battery (`tests/skills-corpus-v1.nu`).

#### Usage

```powershell
# Restore if missing or hash mismatch (idempotent):
./mcp/nushell-mcp/brewery/nushell/restore-nushell.ps1

# Force re-download and restore:
./mcp/nushell-mcp/brewery/nushell/restore-nushell.ps1 -Force

# Skip smoke tests:
./mcp/nushell-mcp/brewery/nushell/restore-nushell.ps1 -SkipTests
```
