# Grok 1.0.4 Wave 0 Evidence

- **Evidence date:** 2026-08-14
- **Executable:** `1.0.4 (d846eb93d9)`
- **Decision:** W0-B no-go; W0-C model pilot not run

## Outcome

- Static CLI/configuration evidence was captured without a model call.
- The intended unsandboxed scratch context discovered four stdio MCP server
  definitions even though `grok mcp list --json` returned `[]`.
- No documented per-invocation switch was found that prevents MCP discovery,
  registration, and startup.
- The deny policy can block a model-requested MCP call; it does not prove server
  definitions are withheld or configured processes are never initialized.
- A sterile cwd alone is therefore insufficient. No authenticated turn, session
  artifact, model cost, or repository census mutation was incurred.

## Evidence and proof limits

| Probe | Observed | It proves | It does not prove |
|---|---|---|---|
| `grok --version` | `1.0.4 (d846eb93d9)` | Executable build reached by this process | Auth, stream compatibility, or native application identity |
| `grok --help` | Headless, policy, carrier, and disable flags parse | Local 1.0.4 command surface | Enforcement or runtime behavior |
| `grok inspect --json` at repository cwd | One project `.mcp.json` stdio server; project untrusted | Configuration discovery for that context | Auth, capability enforcement, or no server startup |
| `grok mcp list --json` at repository cwd | Empty array | Narrow list command returned no entries | Absence of discovered/exposed/started MCP servers |
| Sandboxed scratch `inspect` | Zero MCP servers | Only that restricted process view | Intended unsandboxed launch state |
| Exact unsandboxed exclusive-scratch `inspect` | Four stdio definitions: `pwsh_exec`, `fetch`, `filesystem`, `git` | The intended context still inherits external MCP configuration | Whether each server has already started |
| Same-context `mcp list --json` | Empty array | Corroborates only the narrow list view | MCP isolation; it directly disagrees with aggregate discovery |

The exact-context `inspect` result is authoritative for the gate. The sandboxed
zero-server result was context-dependent, likely because of filesystem/ACL or
configuration-home visibility. Current evidence cannot distinguish the cause.

Raw `inspect` output contains host paths and source metadata. Readiness must
parse it privately and retain only an allowlisted projection.

## Local 1.0.4 protocol facts

- Headless native output is selected with `--output-format streaming-json`; help
  describes NDJSON ACP session updates.
- `--prompt-file <PATH>` with `--verbatim` is the selected non-content-in-argv
  carrier candidate.
- Positional prompt, `--single`, and `--prompt-json` are rejected for managed use
  because prompt content enters argv.
- `agent stdio` is a separate ACP control surface and is deferred.
- Per-turn flags exist for `--disable-web-search`, `--no-subagents`,
  `--no-memory`, `--no-plan`, `--max-turns`, `--permission-mode`, `--sandbox`,
  `--tools`, `--deny`, and `--no-auto-update`.
- No `--no-mcp` or equivalent no-load/no-start switch was exposed.
- `--tools` is documented for built-ins. Empty-allowlist semantics for a literal
  zero-length argv element were not established for 1.0.4.
- Static version/help/inspect probes wrote semantic results to stdout and no
  stderr. Runtime stdout/stderr topology remains unverified.
- A missing prompt-file test failed before model invocation and included the
  carrier path in its native diagnostic. Public para-agent errors must map this
  to a fixed sanitized message.

Official xAI documentation confirms that deny rules win for tool-call policy and
that permissions and sandboxing are separate controls. It also documents MCP
configuration discovery from compatibility locations, but does not state that a
deny rule suppresses registration or server initialization:

- [Permissions](https://docs.x.ai/build/features/permissions)
- [MCP servers](https://docs.x.ai/build/features/mcp-servers)
- [CLI reference](https://docs.x.ai/build/cli/reference)
- [Headless and scripting](https://docs.x.ai/build/cli/headless-scripting)
- [Enterprise controls](https://docs.x.ai/build/enterprise)

## Candidate pilot argv — not authorized

No safe exact argv exists until a documented clean-config or no-MCP-load control
is available. After that control is verified, the candidate vector is:

```text
grok.exe
--cwd <exclusive-sterile-cwd>
<documented-clean-config-or-no-MCP-load-control>
--output-format streaming-json
--verbatim
--no-memory
--no-subagents
--disable-web-search
--no-plan
--max-turns 1
--permission-mode dontAsk
--sandbox read-only
--tools <zero-length-argv-element>
--deny MCPTool
--deny Bash
--deny Edit
--deny Read
--deny Grep
--deny WebFetch
--deny WebSearch
--no-auto-update
--prompt-file <exclusive-private-prompt-file>
```

The empty tools value must be an actual zero-length argv element supplied by a
direct spawn API. Shell quoting is not accepted as evidence of argv shape.

## Conditions to reopen W0-C

- Documented clean scope prevents fallback to user, project, compatibility,
  plugin, marketplace, and remote MCP configuration.
- Exact unsandboxed process environment and child cwd report Grok `1.0.4`, zero
  MCP servers, hooks, plugins, and marketplaces, and no unexplained warnings.
- `mcp list --json` is empty as corroboration, not primary proof.
- Built-in empty-allowlist semantics are documented for 1.0.4.
- Separate stdout/stderr capture, bounded timeout/kill, prompt cleanup, and full
  before/after censuses are ready.
- The census includes tracked, untracked, and ignored repository files, excludes
  `.git`, records path/type/size/hash, and never follows reparse points.

Windows `--sandbox read-only` remains defense-in-depth. It is not a safety basis
until enforcement is independently witnessed.

## Fixture and evidence matrix

| Evidence item | Wave 0 state | Required action |
|---|---|---|
| Executable/build identity | Captured: 1.0.4 | Exact version gate |
| Help/flag surface | Captured | Golden argv parsing |
| Inspect safe projection | Shape captured; raw output unsafe | Strict private parser and allowlist |
| MCP isolation | Failed/no-go | Prove clean no-load scope |
| Built-in non-execution | Policy flags identified | Prove empty allowlist plus denies |
| Authentication | Unknown | Dedicated readiness evidence |
| Configuration | Partial | Exact-context strict parser |
| Capability availability/enforcement | Unknown | Live constrained witness |
| Windows sandbox enforcement | Unknown | Separate Windows gate |
| Prompt-file consumption and cleanup | Unverified | Exact Unicode and cleanup tests |
| Runtime NDJSON event schemas | Unverified | Capture version-labelled fixture |
| Stdout/stderr runtime separation | Unverified | Capture both channels separately |
| Terminal success/failure predicates | Unverified | Correlate events and exit code |
| Session/turn/native IDs | Unverified | Preserve only stream-observed IDs |
| Application/model identity | Unverified | Omit unless receiver-native stream exposes it |
| Reply chunk/reconstruction semantics | Unverified | Ordering, delta/cumulative, duplicate, Unicode tests |
| Session artifact topology | Unverified | Report expected external artifact after safe pilot |
| Repository mutation | No model call; not applicable | Full census around later pilot |

## Current client disposition

| Client | Installed | Evidence disposition |
|---|---:|---|
| Grok | `1.0.4 (d846eb93d9)` | Static CLI/config evidence only; live and isolation unverified |
| Claude | `2.1.232` | Existing evidenced profile is `2.1.226`; refresh or genuine pin required before W2 live compatibility |
| Codex | `0.147.0` | Matches the current verified fixture; recheck at migration |
| AGY | `1.1.13` | Intentionally fail closed/unverified |

## Commands and mutations

Static command families exercised:

- `grok --version`, `version --help`, and `version --json`.
- Root, `inspect`, `mcp`, `agent`, `doctor`, `models`, `login`, and `sessions`
  help surfaces.
- `inspect --json` and `mcp list --json` at repository and scratch contexts.
- One missing prompt-file parser/failure check that stopped before model contact.

No model call, client configuration mutation, plugin/MCP mutation, global-client
edit, or commit was performed by the evidence lane.
