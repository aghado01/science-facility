Yes—pinned in `brewery` as the bootstrap authority.

The intended layout is:

```text
brewery/uv/
  pin.json             # version, upstream artifacts, SHA-256 per platform
  restore-uv.ps1       # verified restoration recipe

packages/uv/           # ignored restored bootstrap executable
.venv/                 # ignored uv-managed project environment
uv.lock                # committed exact Python dependency resolution
.python-version        # committed interpreter pin
```

The same uv version is enforced in three distinct layers:

- `brewery/uv/pin.json`: exact bootstrap executable bytes.
- `pyproject.toml`: `uv==…` plus `[tool.uv] required-version`.
- `uv.lock`: exact uv package and complete environment resolution.

A contract test will ensure those versions agree.

Installation becomes one repository restore operation:

```text
restore pinned uv → install pinned Python → sync uv.lock → verify MCP → generate registrations
```

The MCP then launches through `.venv/Scripts/uv.exe`; `packages/uv` is only the bootstrap mechanism. No ambient Python, uv, activated environment, or checkout-specific hardcoded path is required after restoration.
