The instinct is right — identity routed by the working directory, with `.gitconfig` `includeIf` as the single source of truth, fits the caller-routed identity doctrine exactly (here the "caller" is the workspace). But one mechanical detail in the sketch needs checking: I don't believe `gh` honors a `GH_USER` environment variable. Let me verify against the installed `gh` before designing around it.

The `includeIf` side is solid — `gitdir/i:D:/aghado01/` and `gitdir/i:D:/aipithicus/` each set `user.name`, `user.email`, `github.user`. That's the single source of truth you want, and it already works. Here's my counsel on the wrapper, with one correction that matters:

**`GH_USER` isn't something `gh` reads.** To my knowledge gh's environment surface is `GH_TOKEN`/`GITHUB_TOKEN`, `GH_HOST`, `GH_REPO`, `GH_CONFIG_DIR`, editor/pager/debug knobs — no user-selection variable. Setting `GH_USER` would be silently ignored and `gh` would run as whatever account is *active* in `hosts.yml`, which is exactly the global, race-prone switch you're trying to avoid. (I couldn't verify against the binary — `gh` isn't installed here or vendored in `deps/cli` — so treat this as "verify at implementation," but I'm fairly confident.)

**The stateless mechanism is the token, not the user.** Since gh 2.40 (multi-account), every logged-in account's token is retrievable: `gh auth token --user <name> --hostname github.com`. And `GH_TOKEN` in the environment overrides stored auth per process. So the wrapper becomes:

```nu
export def --wrapped main [...args] {
    let user = (^git config github.user | complete | get stdout | str trim)
    if ($user | is-empty) { return (^gh ...$args) }
    let token = (^gh auth token --user $user --hostname github.com | complete)
    if $token.exit_code != 0 { error make {msg: $"gh: no stored auth for '($user)' — run: gh auth login"} }
    with-env { GH_TOKEN: ($token.stdout | str trim) } { ^gh ...$args }
}
```

Per-invocation, per-process identity. Two terminals in two workspaces never fight over `gh auth switch`, and an agent's `gh pr list` is the right user by construction. The alternative — `GH_CONFIG_DIR` per identity — also works statelessly but means two separate config trees; the token route keeps one `gh auth login` per account and nothing else.

**Three design points for the module proper:**

1. **Token hygiene is a hard rule.** The token lives only inside `with-env` for that one process. It must never be a return value, never appear in `$history`, and — once the host journals exist — never in a `cmd` line (the journal records the agent's input, `gh pr list`, not the env; that's already safe, but the wrapper must not echo it on error either).
2. **Outside a repo there's no identity, and that's correct.** `includeIf gitdir:` only matches when there *is* a gitdir, so `github.user` is empty on a bare desktop and the wrapper passes through to gh's active account. Document it rather than inventing a fallback.
3. **It's the same shape as the rg module.** `--wrapped`, zero curation, `^gh` as the escape hatch, return path through `xq` — and gh's `--json` output gets the same return-path detection rg has (JSON → rows, else text mode). Identity injection is *environment*, not argument rewriting, so it doesn't violate the zero-curation rule.

The generalization is worth naming: **workspace-routed identity for external tools** — git config is the registry, `includeIf` is the router, and each tool module asks `git config <tool>.user` then injects whatever *that tool's* stateless credential mechanism is. `gh` is the first instance; `glab` would be the second.

Want me to file it as `gh-v1` — the wrapper, the hygiene rule, the "verify at implementation" flags (gh ≥ 2.40, `auth token --user`), and a `deps/cli` entry for the binary?