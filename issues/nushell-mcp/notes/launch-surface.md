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

**Why this matters for embedding.** `$nu.current-exe` is whatever
binary launched this engine, whoever launched it. The choice
propagates for free and the layer never reads a host's variable to
learn it. That is the shape to keep reaching for: a host's concerns
are handled by the host *launching things*, not by nushell-mcp
learning about the host.

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

## Interactions with a host (para-agent as the worked case)

**Workspace scoping is the host's guarantee, and para-agent already
makes it.** Verified in `src/index.js`: `WORKSPACE_ROOT =
PARA_WORKSPACE_ROOT ?? process.cwd()`, documented as *"Launch cwd is
that workspace by convention"*, with `spawn` defaulting to
`cwd ?? WORKSPACE_ROOT` and journals under it. A para-agent session
runs in the same workspace as the primary agent that called it, by
design. [gh-v1](../briefs/gh-v1.md) *relies* on this: GitHub identity
resolves from the engine's cwd through `includeIf gitdir:`, so
workspace-scoped spawn is what makes workspace-routed identity correct.
Not a hazard — a dependency on a guarantee that exists.

**Two nu dependencies, deliberately decoupled** (owner, 2026-08-22).
They were fused during incubation — one `deps/bin/nu` served both — and
are not any more:

| | para-agent's backend nu | the console engine |
|---|---|---|
| Status | **requirement** — `nu.js` structured exec, pane dialect | **nice-to-have**, one console option among others |
| Binary | para-agent's `deps/bin/nu` (`resolveNuBin`, `PARA_NU_BIN`) | nushell-mcp's own pinned `deps/nushell` |
| Versioned by | para-agent | nushell-mcp |

So a visitor engine is launched by **nushell-mcp's own launcher with
its own pinned engine** — not with `PARA_NU_BIN`. There is no version
skew to watch for, because nothing is shared: `$nu.current-exe`
inherits nushell-mcp's binary, and para-agent upgrades its backend nu
on its own schedule. (Earlier drafts of this note assumed the fused
model and warned about skew; that warning is retired.)

**Corollary — nushell-mcp must not assume it *is* the console.**
para-agent's console plane should be console-agnostic and
user-configurable; a Nushell console is one choice a participant may
be given. Practical consequences here: stand-alone usefulness is the
priority and integration is not a design driver; nothing in this layer
may require para-agent; and the visitor grant stays optional in both
directions.

**Settled, not hazards** (raised and closed): the `deps/cli` prepend
*is* the decision — `config.nu` owns it, so the layer's pinned tools
win inside the engine deterministically, and para-agent's `deps/bin`
coexists without contest. `NU_MCP_OUTPUT_LIMIT` being the launcher's
to set is a launch-surface entry, not a risk. Both are ordinary
co-design in unfinished work.

## The promise

nushell-mcp **names no host concept**. No `PARA_NU_BIN`, no pane, no
mux, no psmux, no visitor registry. Everything a host needs to
influence, it influences through the table above — mechanisms the
layer has for its own reasons. If a future requirement seems to need
nushell-mcp to know about para-agent, that is the signal to add a
launch-surface entry instead.
