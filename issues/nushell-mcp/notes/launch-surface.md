# The launch surface — what a host may vary, and nothing else

**Written:** 2026-08-22 · **Status:** doctrine. Serves the para-agent
deployment (roadmap step 8) before that brief exists.
**Related:** [identity-routing](identity-routing.md),
[write-conventions-v1](write-conventions-v1.md).

## The principle

**Inherit from the process; do not look up in the environment.**

Whatever the layer can learn from the running process — its own
binary, its own file location, its own OS — it takes from the process.
Ambient lookups (`^nu` on PATH, cwd-relative paths, "wherever the
config happens to be") are the things that silently mean something
different when the component moves to another host. A component that
inherits is portable by construction; one that looks up is portable
only by luck and configuration.

Worked example, and the reason this note exists:

- `nu-modules` loaded units in a child via `^nu` — a PATH lookup.
  Residue of the para-agent incubation, where nu was a **pane
  dialect**: the pane's shell *was* nu and para-agent curated the
  pane's PATH (`PARA_NU_BIN`), so `^nu` resolved to the intended
  binary. Correct under that model.
- Stand-alone, the model is different: the engine is launched by
  absolute path from `.mcp.json` and `config.nu` prepends only
  `deps/cli`, so the child's PATH may contain no `nu` at all. It
  didn't — `nu-modules inspect` failed with ``Command `nu` not
  found`` in the live session (found and fixed 2026-08-22).
- Fix: `^$nu.current-exe`. The running binary, by absolute path.

**Why this matters for re-entry.** Under para-agent, `$nu.current-exe`
*is* whatever para-agent launched the engine with — including
`PARA_NU_BIN`. The binary choice propagates **for free**, and
nushell-mcp never names, reads, or knows about `PARA_NU_BIN`. That is
the shape to keep reaching for: para-agent's mux-era concerns are
handled by para-agent *launching things*, not by nushell-mcp learning
about mux.

## The complete surface (audited from source, 2026-08-22)

Everything a host may vary. The layer reads nothing else ambient.

| What | Mechanism | Notes |
|---|---|---|
| which engine binary | the host **launches** it | inherited via `$nu.current-exe`; no env var, no PATH |
| layer layout | `--config <path>` | `config.nu` is the single owner; anchors everything to itself via `path self` |
| output cap | `NU_MCP_OUTPUT_LIMIT` | nushell's own knob; the visitor host must set it (today `.mcp.json` does) |
| where state/scratch go | `NU_MCP_JOURNAL_ROOT`, `NU_MCP_ARTIFACTS_ROOT` | [write-conventions](write-conventions-v1.md); planned |
| who the agent is | `NU_MCP_SESSION_ID`, `NU_MCP_AGENT_ID` | [identity-routing](identity-routing.md); planned |
| working directory | spawn cwd | **see hazard below** |
| external tools | `PATH` | `config.nu` prepends `deps/cli`, so the layer's pinned binaries win inside the engine |

Read from the OS, not the host: `NUMBER_OF_PROCESSORS` (core-count
fallback when `sys cpu` fails), `$nu.os-info`.

Written by the layer, not read from the host: `$env.JOBS`,
`$env.NU_PAR`, `$env.NU_LIB_DIRS`, `$env.NU_SKILL_DIR`.

**Ambient external lookups: zero.** After the fix,
`^$nu.current-exe` is the layer's only external invocation. Future
modules add tool lookups (`^rg`, `^gh`, `^git`, `xq`'s `^<cmd>`); those
are legitimately PATH-resolved, and `config.nu`'s `deps/cli` prepend is
what makes them deterministic. Keep that the only mechanism — no
module hunts for a binary itself (rg-v1, gh-v1 both say so).

## Hazards for the visitor deployment

1. **cwd decides GitHub identity.** [gh-v1](../briefs/gh-v1.md) routes
   identity from `git config github.user`, which resolves against the
   engine's **cwd** via `includeIf gitdir:`. So whoever spawns the
   engine chooses which account it acts as. Correct by design
   (workspace-routed), but it must be *deliberate*: a visitor engine
   spawned in para-agent's own package directory would resolve the
   wrong identity, or none. Co-design item: para-agent spawns visitor
   engines in the participant's workspace, not its own.
2. **Engine version skew.** If the host launches a nu other than the
   pinned `deps/nushell/nu.exe`, the modules run on an untested
   engine. `$nu.current-exe` keeps parent and child *consistent*, which
   is the important half; visibility is the other half — the host's
   `console` reports engine version so skew is legible rather than
   mysterious.
3. **Two `deps` trees.** para-agent keys executables `deps/bin/{tool}`;
   nushell-mcp uses `deps/cli`. Both may sit on PATH; the prepend means
   the layer's pinned tools win *inside the engine*. Deterministic, but
   decide it deliberately rather than discovering it.
4. **The cap must be set by the launcher.** Stand-alone that is
   `.mcp.json`; as a visitor it is para-agent's spawn. An unset
   `NU_MCP_OUTPUT_LIMIT` silently changes truncation behavior.

## The promise

nushell-mcp **names no host concept**. No `PARA_NU_BIN`, no pane, no
mux, no psmux, no visitor registry. Everything a host needs to
influence, it influences through the table above — mechanisms the
layer has for its own reasons. If a future requirement seems to need
nushell-mcp to know about para-agent, that is the signal to add a
launch-surface entry instead.
