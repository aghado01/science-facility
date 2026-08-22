# Identity routing — one shape, several bindings

**Written:** 2026-08-22 · **Status:** doctrine note. Instances:
[session-host-v1](../briefs/session-host-v1.md) (console identity),
[gh-v1](../briefs/gh-v1.md) (GitHub identity). para-agent's visitor
registry is the governance half of the console instance.

## The shape

Identity is **resolved from context by a pure router and injected per
process**. Registries are external and declarative; routing never
mutates global state; unknown context is labeled, not refused;
governance (*may* X) is a separate concern from routing (*which* X).

| Part | Console (session host) | GitHub (`gh` module) |
|---|---|---|
| Registry | `host.json` identity map; para-agent visitor registry | `.gitconfig` + per-identity include files |
| Context key | the caller (client name, env, launch args) | the working directory (gitdir) |
| Router | host config mapping | `includeIf gitdir:` → `github.user` |
| Injection | `NU_MCP_SESSION_ID` / `NU_MCP_AGENT_ID` at engine spawn; stream name | `GH_TOKEN` in `with-env` for one `^gh` |
| Unknown context | default identity + `note` (label, don't gate) | empty `github.user` → passthrough to gh's active account |
| Governance | visitor registry (para-agent) | `gh auth login` having happened |
| Global mutation | never | never (no `gh auth switch`) |
| Secret hygiene | ids are not secrets; tokens never journaled | token only inside `with-env`; never returned, never in `$history` |

## Shared shape, not shared code

The console router is TypeScript in the host; the gh router is Nu in
the engine. They do not call each other — the same stance as the
journal contract (format-based coupling). What they share is one
closed record, the **identity receipt**:

```
{scope: string, id: string, source: string, via: list<string>}
```

- `gh identity` → `{scope: github, id: aghado01, source:
  "C:/…/.gitconfig-aghado01", via: [GH_TOKEN]}`
- host `console` → `{scope: console, id: claude, source: host.json,
  via: [NU_MCP_AGENT_ID]}`

`source` is what makes "single source of truth" inspectable rather
than trusted: the receipt names the file (and, where cheap, the line)
that decided.

## Refused

- Using `github.user` as the console agent identity because it is
  conveniently there. A human's GitHub account and an agent's session
  identity are different scopes with different registries. Shared
  shape; distinct identities.
- Any router that switches a global (gh's active account, a shared
  engine's `$env`). Identity is a property of the invocation.
- A router that refuses on unknown context. Label and proceed
  (para-agent's posture, adopted layer-wide).

## Third binding, when it comes

para-agent participants → visitor grant: registry = visitor-MCP
registry; context = the participant; injection = whatever para-agent
passes at spawn (roots + ids). Same table, one more column.
