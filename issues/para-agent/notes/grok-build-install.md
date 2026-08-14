**Yes.** Here are the **canonical environment variables** for Grok Build (from the official docs at [docs.x.ai/build/settings/reference](https://docs.x.ai/build/settings/reference)):

### Paths & Auth

| Variable      | Default   | Description                                                      |
| ------------- | --------- | ---------------------------------------------------------------- |
| `GROK_HOME`   | `~/.grok` | Root directory for config, auth, sessions, skills, plugins, logs |
| `XAI_API_KEY` | —         | API key for headless / CI / non-browser auth                     |

### Models & Updates

| Variable                   | Default                         | Description                                                 |
| -------------------------- | ------------------------------- | ----------------------------------------------------------- |
| `GROK_DEFAULT_MODEL`       | catalog / config                | Default model for new sessions                              |
| `GROK_WEB_SEARCH_MODEL`    | built-in                        | Model used by the `web_search` tool                         |
| `GROK_MODELS_BASE_URL`     | —                               | Custom inference base URL (model list from `{base}/models`) |
| `GROK_MODELS_LIST_URL`     | `{GROK_MODELS_BASE_URL}/models` | Override the model list endpoint                            |
| `GROK_XAI_API_BASE_URL`    | `https://api.x.ai/v1`           | xAI API base URL when using API-key auth                    |
| `GROK_DISABLE_AUTOUPDATER` | unset                           | Set to disable auto-updates (useful in CI/containers)       |

### Tools, Sandbox & Features

| Variable                       | Default      | Description                                                            |
| ------------------------------ | ------------ | ---------------------------------------------------------------------- |
| `GROK_SANDBOX`                 | `off`        | Sandbox profile (`off`, `workspace`, `read-only`, `strict`, or custom) |
| `GROK_SANDBOX_AUTO_ALLOW_BASH` | `0`          | Auto-allow bash inside sandbox                                         |
| `GROK_RESPECT_GITIGNORE`       | config       | Force gitignore filtering (`1`/`0`)                                    |
| `GROK_WEB_FETCH`               | `0`          | Enable the `web_fetch` tool                                            |
| `GROK_WEB_FETCH_PROXY`         | —            | Proxy for `web_fetch`                                                  |
| `GROK_MEMORY`                  | `0`          | Enable cross-session memory                                            |
| `GROK_SUBAGENTS`               | `0`          | Enable subagents                                                       |
| `GROK_AGENT`                   | `grok-build` | Agent name / profile / path                                            |
| `GROK_WRITE_FILE`              | `1`          | Set to `0` to disable write tool (read-only)                           |
| `GROK_TOOL_SEARCH`             | `1`          | On-demand MCP tool discovery                                           |
| `GROK_LSP_TOOLS`               | `0`          | Enable LSP code-intel tools                                            |

### Installer-only (used by `install.sh` / `install.ps1`)

| Variable              | Description                           |
| --------------------- | ------------------------------------- |
| `GROK_BIN_DIR`        | Custom directory for the binaries     |
| `GROK_VERSION`        | Pin a specific version during install |
| `GROK_CHANNEL`        | `stable` / `alpha` / `enterprise`     |
| `GROK_DEPLOYMENT_KEY` | Enterprise deployment key             |
| `GROK_PROXY_URL`      | Proxy for the installer               |

### Other notable ones

- `GROK_CODE_XAI_API_KEY` — legacy fallback for the API key
- Standard proxy vars: `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`
- Logging: `GROK_LOG_FILE`, `RUST_LOG`
- Many UI-related vars (`GROK_THEME`, `GROK_SHOW_THINKING_BLOCKS`, etc.)

**Most commonly used in practice:**

```bash
export XAI_API_KEY="xai-..."
export GROK_HOME="/custom/path"          # optional
export GROK_BIN_DIR="/custom/bin/path"   # for install only
```

Environment variables override values from `config.toml`. You can inspect the effective configuration with:

```bash
grok inspect
```
