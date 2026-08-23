# `gh` module v1 — workspace-routed GitHub identity

**Status:** filed, not started · **Filed:** 2026-08-22 · **Home:**
`mcp/nushell-mcp/modules/gh`, Nu-native. **Depends on:** [xq-v1](xq-v1.md) (ordinary terminal `xq`, not
`process capture`); the shape in
[notes/identity-routing.md](../notes/identity-routing.md).
**Prerequisite:** `gh` ≥ 2.40 (multi-account: `auth token --user`) on
the child's PATH — vendor into `deps/cli` like ripgrep.
**Not this brief:** a GitHub API client, curated subcommands, `git`
itself (git already honors `includeIf` natively).

Treat this file as the v1 spec. Amend; do not fork.

## Problem

Two GitHub accounts, two directory trees (`D:\aghado01\`,
`D:\aipithicus\`). `.gitconfig` already routes git's identity by
directory via `includeIf gitdir:` — `user.name`, `user.email`, and a
custom `github.user` per tree (verified 2026-08-22: `git config
github.user` → `aghado01` from `.gitconfig-aghado01`). `gh` does not
read that; it runs as whichever account is *active* in its
`hosts.yml`, switched globally with `gh auth switch`. Global state,
shared by every terminal and agent — the wrong shape.

Goal: whenever anyone (human or agent) runs `gh …` inside a tree, it
runs as that tree's account, with no manual switch, no preflight, and
no global mutation. Git config stays the single source of truth.

## Mechanism (verify at implementation — `gh` is not on this host)

`gh` has no user-selection environment variable (`GH_USER` is not a
thing it reads). The stateless selector is the **token**: since 2.40,
`gh auth token --user <name> --hostname github.com` returns the stored
token for any logged-in account, and `GH_TOKEN` in the environment
overrides stored auth **per process**.

```nu
export def --wrapped main [...args] {
    let user = (^git config github.user | complete | get stdout | str trim)
    if ($user | is-empty) { return (xq gh ...$args) }          # no identity here: passthrough
    let tok = (^gh auth token --user $user --hostname github.com | complete)
    if $tok.exit_code != 0 {
        return {ok: false, error: $"gh: no stored auth for '($user)' on github.com — run: gh auth login"}
    }
    with-env { GH_TOKEN: ($tok.stdout | str trim) } { xq gh ...$args }
}
```

- `--wrapped`, zero curation: argv forwarded verbatim; `^gh` is the
  escape hatch; `-h`/`--help` forward (known `--wrapped` behavior).
  Identity injection is **environment**, not argument rewriting, so
  it does not violate the zero-curation rule.
- **Outside a repo there is no identity, and that is correct.**
  `includeIf gitdir:` matches only when a gitdir exists, so
  `github.user` is empty on a bare desktop → passthrough to gh's
  active account. Documented, not papered over.
- One extra `gh` process per call (`auth token`), ~50–100 ms.
  Accepted in v1; no session-level token cache (a cached token in
  `$env` outlives the invocation, which is the thing we are avoiding).
- Alternative considered: `GH_CONFIG_DIR` per identity. Also stateless,
  but two config trees to maintain. Token route keeps one `gh auth
  login` per account and nothing else. Revisit only if `auth token
  --user` turns out to be unavailable.

## Token hygiene (hard rule)

The token exists only inside `with-env` for that one child process.
It is never a return value, never in `$history`, never in an error
message, never in a journal `cmd` (the journal records the agent's
input — `gh pr list` — not the environment). Missing auth is `{ok: false, error: …}` naming the *user*, never the
token, never a throw. Test it. Module-scope `use xq *`.

## Return path

v1: inject `GH_TOKEN` and invoke **ordinary `xq`**. The result **is**
the xq envelope. Do not parse JSON or grow an rg-like `mode` field —
xq does not do that, and gh v1 is identity routing, not a GitHub API
client. `use xq *` at module scope.

## `gh identity` — the identity receipt

```
gh identity
→ {scope: "github", id: string?, source: string?, via: list<string>}
```

`id` from `git config github.user`; `source` from `git config
--show-origin github.user` (the include file that decided); `via:
[GH_TOKEN]` when an id resolved, `[]` when passthrough. Closed shape
shared with the host's `console` identity receipt (identity-routing
note). Never throws; no identity → `id: null`, `source: null`.

## Tree

```
mcp/nushell-mcp/modules/gh/
  mod.nu              # main (--wrapped), gh identity
mcp/nushell-mcp/skills/nushell/references/tools.md
  + gh: workspace-routed identity, the receipt, hygiene, ^gh escape
mcp/nushell-mcp/deps/README.md
  + gh.exe (≥ 2.40)
config.nu             # use gh *   (after xq)
```

## Tests (child `nu -n`; fake `gh` on PATH for the unit cases)

- `gh identity` inside `D:\aghado01\…` → `id: aghado01`, `source`
  names `.gitconfig-aghado01`, `via: [GH_TOKEN]`; in a temp dir with
  no repo → `id: null`, `via: []`, no error
- identity resolved: child sees `GH_TOKEN` set to the fake token;
  argv forwarded verbatim; `^gh` untouched
- no identity: child sees **no** `GH_TOKEN`; passthrough
- missing auth for the resolved user: error names the user; the fake
  token value appears nowhere in the error, the result, or
  `$history`
- `--json` output → `mode: json` rows; plain output → `mode: text`
- `-h` forwards to the child, not Nushell help

## Exit gate

In `D:\aghado01\science-facility`: `gh identity` → aghado01 receipt;
`gh auth status` (through the wrapper) reports the aghado01 account
regardless of which account is active in `hosts.yml`; `gh repo view
--json name` → `mode: json` row. In `D:\aipithicus\…`: same three, as
aipithicus. No `gh auth switch` was run at any point.

## Non-goals (v1)

- Curated subcommands, aliases, or a GitHub API wrapper
- Token caching across invocations
- Enterprise hosts (`GH_HOST` ≠ github.com) — pass `--hostname`
  through when it matters; v2 reads `github.host` from git config
- Replacing git's own `includeIf` handling for `git`
- `glab` / other forges — second binding of the same shape, own brief

---

## Follow-up report

_Chip or implementer: append outcome, tests run, deviations from this spec._
