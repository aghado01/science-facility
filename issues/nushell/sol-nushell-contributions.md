Yes—your `nushell-mcp` is already an excellent adversarial workload for upstream `nu-mcp`. The selfish strategy is to upstream engine/protocol correctness that your modules currently compensate for, while keeping your opinionated orchestration and agent porcelain downstream.

Nu’s MCP is active, not abandoned: persistent state, structured errors/output, HTTP transport, history, cancellation, and job promotion all landed recently. The upstream vision also explicitly includes a self-sufficient remote agent shell, so your direction is compatible with stated interest. [Upstream vision #17160](https://github.com/nushell/nushell/issues/17160), [structured output PR #18499](https://github.com/nushell/nushell/pull/18499).

## Strongest contribution targets

| Priority | Upstream target | Evidence and desired change |
|---|---|---|
| P0 | Stable result handles | Live rollover returned indices `95,96,97,98,99,99,99`; `$history.99` changed owners. Lowering the limit to 3 left its length at 100. The implementation uses shifting `VecDeque` positions in [history.rs](/D:/aghado01/packages/nu/nushell/crates/nu-mcp/src/history.rs:38), contradicting the promised stable index in [instructions.md](/D:/aghado01/packages/nu/nushell/crates/nu-mcp/src/instructions.md:60). Add a monotonic `result_id` and id-addressed retrieval; retain `$history` only as a moving convenience window. |
| P0, tiny | Make `$nu.is-mcp` truthful | The live 0.114.1 engine returned `false`. At current upstream HEAD, `$nu` is generated in [main.rs](/D:/aghado01/packages/nu/nushell/src/main.rs:530) before `engine_state.is_mcp` is set at [main.rs](/D:/aghado01/packages/nu/nushell/src/main.rs:583). Move the flag assignment earlier and add a config-time test. Existing tracker: [#17155](https://github.com/nushell/nushell/issues/17155). |
| P0/P1 | Preserve MCP startup environment state | Nu converts the inherited environment on one stack at [main.rs](/D:/aghado01/packages/nu/nushell/src/main.rs:398), then MCP creates a fresh stack before config at [main.rs](/D:/aghado01/packages/nu/nushell/src/main.rs:590). That explains the PATH-string workaround in your [config.nu](/D:/aghado01/science-facility/mcp/nushell-mcp/config.nu:30). Reuse or correctly merge the converted startup stack. Existing tracker: [#17154](https://github.com/nushell/nushell/issues/17154). |
| P1 | Typed, correlated promoted results | Promotion throws away the forked state, serializes the result to a string, and sends it with no mailbox tag in [evaluation.rs](/D:/aghado01/packages/nu/nushell/crates/nu-mcp/src/evaluation.rs:541). Preserve the typed `Value`, correlate delivery with `job_id`, and return a structured promotion receipt. Do **not** merge background state; your registry-ownership lesson says that isolation is correct. |
| P1 | Progressive discovery and lower token tax | Native `list_commands` returns an unbounded newline string, while `command_help` omits examples and input/output types. In this Codex client, the three Nu tools currently expose 41,440 description characters because the 266-line server guide is repeated for every tool. Shorten server instructions; move chapters to an on-demand guide/resource; return structured, paginated command metadata with examples and output schemas. PR #18499 already raised serialization-cost concerns during review. |
| P1 | Preserve binary output | Native direct external capture uses `String::from_utf8_lossy` in [evaluation.rs](/D:/aghado01/packages/nu/nushell/crates/nu-mcp/src/evaluation.rs:771). Live output `FF FE 41` became `��A`, whereas `\| complete` preserved `0x[FFFE41]`. Return a string only for valid UTF-8; otherwise retain binary or fail explicitly. |
| P1, safety | Safe HTTP defaults | HTTP binds unauthenticated arbitrary shell execution to `0.0.0.0` in [lib.rs](/D:/aghado01/packages/nu/nushell/crates/nu-mcp/src/lib.rs:140). Default to loopback and require an explicit bind address for remote exposure. Add MCP read-only/destructive/open-world tool annotations too. |
| Investigate | Concurrent evaluation commits | The evaluator forks state, releases the lock, and later replaces the entire persistent state in [evaluation.rs](/D:/aghado01/packages/nu/nushell/crates/nu-mcp/src/evaluation.rs:309). That appears capable of last-writer-wins state/history loss. My live client serialized concurrent calls, so I did not reproduce it. First contribution should be a deterministic overlapping-evaluations test, then either queue evaluations or add revision checking. |

The history bug is the most strategically important finding. Once an agent is told a handle is stable, every disclosure, paging, journal, and delayed-retrieval design rests on that promise. Your `jobs stash` design already demonstrates the correct replacement: allocate an address atomically, publish it only after storage succeeds, and fail explicitly when it is unavailable.

## What should remain in `science-facility`

I would not upstream these as native Rust MCP behavior:

- Domain `ok` lifting, outcome-table aggregation, and lifecycle/domain distinction beyond preserving the typed value.
- `$env.JOBS`, `par` budgeting, quarantine policy, `dataspection`, `xq`, and `rg`.
- `nu-git`/`nu-gh` agent porcelain. The new [agent-porcelain design](/D:/aghado01/science-facility/issues/nushell-mcp/discussion/agent-porcelain-overlay.md:9) correctly treats disclosure economy and domain views as modules, not engine semantics.
- Identity routing, journaling, retention, engine generations, and para-agent mediation from [session-host-v1](/D:/aghado01/science-facility/issues/nushell-mcp/briefs/session-host-v1.md:13).
- Automatic interpretation of arbitrary returned records. Native MCP should report whether evaluation succeeded and preserve the value; your Nu modules should decide whether `{ok:false}` is a declared domain outcome.

An eventual opt-in mechanism for projecting selected Nu `def`s into first-class MCP tools could be powerful, but I would postpone it. Automatic exposure would explode the tool catalog and token cost, while pipeline input does not map cleanly onto JSON arguments. Structured command discovery is the safer prerequisite.

## Recommended contribution sequence

1. Fix `$nu.is-mcp` and close the existing issue—a small trust-building PR.
2. Fix converted-stack/PATH persistence with cross-platform MCP startup tests.
3. Design and implement monotonic result IDs, including rollover, eviction, and limit-shrink tests.
4. Preserve typed and job-correlated promoted results.
5. Reduce instruction duplication and add structured/paginated discovery.
6. Follow with binary preservation, loopback HTTP, and the concurrency test.

Yes—with one nuance: Nushell does not explicitly mandate a fork, but unless Aipithicus has write access to `nushell/nushell`, the normal and appropriate route is a fork owned by Aipithicus. GitHub documents this as the standard “fork and pull request” workflow. [GitHub fork guidance](https://docs.github.com/en/get-started/exploring-projects-on-github/contributing-to-a-project?tool=cli)

Recommended setup:

```nu
# First create aipithicus/nushell using GitHub's Fork button.

git clone git@github.com:aipithicus/nushell.git 'D:\aipithicus\contributing\nushell'
cd 'D:\aipithicus\contributing\nushell'

# origin pushes through the Aipithicus identity; upstream is canonical/read-only.
git remote add upstream https://github.com/nushell/nushell.git
git remote -v

# Keep authorship scoped to this checkout.
git config --local user.name '<your public Aipithicus author name>'
git config --local user.email '<Aipithicus verified or noreply GitHub email>'

# Start every contribution from current upstream main.
git fetch upstream
git switch --create fix/mcp-specific-change upstream/main
```

If you use multiple GitHub SSH identities, replace `github.com` in the clone URL with your Aipithicus SSH host alias. Authentication, attribution, and PR ownership are separate:

- SSH key/host determines which account may push.
- Repository-local `user.name` and `user.email` determine commit attribution.
- The logged-in GitHub account determines the PR author.

GitHub recommends exactly this `origin`-for-fork plus `upstream`-for-original arrangement. [Configuring an upstream remote](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/configuring-a-remote-repository-for-a-fork)

Nushell’s current conventions are:

- Discuss significant, new, or user-facing designs with the core team first—through Discord, an issue, a discussion, or a draft PR. Straightforward bug fixes can generally proceed directly.
- Keep each PR to one functional change or tightly related set. Do not combine an MCP behavior change with unrelated cleanup.
- Use a descriptive PR title naming the affected command or subsystem and observable change. Conventional Commit prefixes such as `fix(mcp):` are not documented as mandatory.
- Add a minimal regression test for bug fixes plus meaningful edge cases.
- Maintainers generally squash-merge. Atomic commits are helpful, but fixup commits are acceptable; repeated force-pushing during review is discouraged.
- Leave “Allow edits by maintainers” enabled.
- Complete the template’s `Description`, `User-facing changes (Release notes)`, and optional `Additional notes`. Release notes should describe observable behavior, or say `n/a` for internal-only work. [Nushell contribution guide](https://github.com/nushell/nushell/blob/main/CONTRIBUTING.md), [current PR template](https://github.com/nushell/nushell/blob/main/.github/pull_request_template.md)

For validation, the official pre-PR command is:

```nu
use toolkit.nu
toolkit check pr
```

A faster MCP-specific development loop would be:

```nu
cargo test --package nu-mcp
cargo fmt --all -- --check
```

Before submission, the documented full checks include workspace Clippy and tests:

```nu
cargo clippy --workspace -- -D warnings -D clippy::unwrap_used
cargo test --workspace
```

On Windows, their guide notes that full tests may require Developer Mode, while their optional Git-hook installer is unavailable.

Rust-specific expectations include no nightly features, no `.unwrap()`-style panic paths for production behavior, careful error handling for user/external input, a high bar for new dependencies, and no GPL dependencies. [Nushell Rust style](https://github.com/nushell/nushell/blob/main/devdocs/rust_style.md)

I found no documented CLA, DCO, `Signed-off-by`, mandatory commit signing, or rigid commit-message requirement in the current contribution guide, PR template, developer documentation, or repository configuration.

For your MCP agenda, I’d use a sequence of narrow PRs: a contained `nu-mcp` correctness bug is ordinary bug-fix territory; broader session semantics, result schemas, or new agent-facing capabilities should begin as a discussion or draft PR. Keep the release/runtime checkout under `D:\aghado01\packages\nu\nushell` separate from this Aipithicus contribution clone.