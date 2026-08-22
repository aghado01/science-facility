# Write conventions v1 — where nushell-mcp puts files

**Status:** filed 2026-08-21 · **Applies to:** the session host, every
Nu module that writes, tests. **Precedents:** codex-scientiae
`artifacts/README.md` (disposable output: module-scoped, chronological,
never OS temp); para-agent `.para-agent/{journals,transcripts}`
(workspace-local durable state, `PARA_WORKSPACE_ROOT` + env override).
**Not this brief:** retention *policy values* (host.json), the journal
record format (Console Journal Contract v1).

Treat this file as the convention. Amend; do not fork.

## Two classes of write, never confused

| Class | Examples | Regenerable? | Root |
|---|---|---|---|
| **State** | journal streams, body files, annotations, engine generation notes, v2 daemon socket/pids | **No** — history is evidence | `<workspace>/.nushell-mcp/` |
| **Scratch** | test runs, `jobs spill` exports, build intermediates, caches | Yes — deleting costs only time | `<workspace>/artifacts/nushell-mcp/` |

The test: *would deleting it lose something an agent or person might
later ask for?* Yes → state. No → scratch. History is never scratch.
A spill is scratch because the journal keeps the canonical copy.

`deps/`, `brewery/`, `build/` are the package's own layout (AGENTS.md
in para-agent, mirrored here) and are not governed by this brief.

## Locality

1. **Workspace root** resolves in this order: explicit config
   `workspace_root` → `NU_MCP_WORKSPACE_ROOT` → the launching client's
   cwd. Same rule as para-agent's `PARA_WORKSPACE_ROOT`.
2. **State** lives in a dotdir at the workspace root: `.nushell-mcp/`.
   Globally gitignored (`**/.nushell-mcp/**`), exactly as
   `**/.para-agent/**` is today. Workspace-local because a session's
   history belongs with the work it was about.
3. **Scratch** goes to `<workspace>/artifacts/nushell-mcp/` when the
   workspace already has an `artifacts/` tree (codex-scientiae rule:
   first segment is the module, `nushell-mcp`), else to
   `.nushell-mcp/artifacts/`. Labeled in `console` output so nobody
   guesses.
4. **No workspace** (launched with no project context): user-level
   `~/.nushell-mcp/` for state, `~/.nushell-mcp/artifacts/` for
   scratch. **Never** `%TEMP%`/`$TMPDIR` — the codex rule, adopted
   verbatim. Tests that need a temp dir are handed one under
   `artifacts/nushell-mcp/test-runs/<stamp>/` and must not allocate
   their own.

## Chronology

- Every run-scoped directory carries an ISO-ordered stamp as its
  **prefix**: `YYYYMMDD_HHmmss[_NN]` (`_NN` only on same-second
  collision). Directory listings sort into timelines with no tooling.
- Journal streams: `.nushell-mcp/journals/streams/<YYYYMMDD_HHmmss>_nu-<agent>-<session8>/`
  — stamp = session start, then the identity. Resume by session id is
  a glob on the suffix; the host also keeps `streams/index.jsonl`
  (`{stream, session_id, agent_id, started, last_seen}`) so `list`
  does not scan directories.
- Inside a stream, order is the journal's `seq`. Never rely on mtime
  anywhere.
- Scratch runs: `artifacts/nushell-mcp/test-runs/<stamp>_<lane>/`,
  `artifacts/nushell-mcp/spills/<stamp>_<tag>.nuon`.

## Overridability (one precedence, everywhere)

```
caller argument  >  environment  >  host.json  >  convention default
```

| Setting | Env | Default |
|---|---|---|
| workspace root | `NU_MCP_WORKSPACE_ROOT` | client cwd |
| journal root | `NU_MCP_JOURNAL_ROOT` | `<workspace>/.nushell-mcp/journals` |
| scratch root | `NU_MCP_ARTIFACTS_ROOT` | `<workspace>/artifacts/nushell-mcp` or `.nushell-mcp/artifacts` |

Relative paths resolve against the workspace root, then the package
root (para-agent `resolvePath` rule). Every effective path is reported
by `console`; an override that does not exist is created, never
silently replaced by a default.

**Co-design hook:** when para-agent deploys nushell-mcp as a visitor,
it routes `NU_MCP_JOURNAL_ROOT` to its own journal root so engine
streams sit beside pane streams under one `streams/` — the same
caller-routing as identity. Standalone, the default above applies.
Neither side hard-codes the other's dotdir.

## Ownership and deletion

- The host deletes only under roots it owns and only by retention
  policy (`host.json`): state by count/age, scratch freely. It never
  walks up, never touches a sibling module's `artifacts/<other>/`.
- Each root the host creates gets a `README.md` (the one tracked-style
  file, as in `artifacts/` and `deps/`) saying what writes there and
  what may delete it. Absent README → the host did not create it →
  never delete it.
- Nothing is *delivered* from scratch. A payload something else should
  consume is written by the agent to a path it names (`jobs spill
  --to`), not discovered under `artifacts/`.

## Tests

- workspace resolution order (config, env, cwd) with each override
- state vs scratch roots land where the table says, incl. the
  `artifacts/` detection and the no-workspace fallback
- stamps sort chronologically; `_NN` on collision; never mtime
- stream dir name carries stamp + identity; `index.jsonl` updated
- retention never deletes outside owned roots; README marker respected
- `%TEMP%` is never written by any test or tool (assert on the env)

## Non-goals (v1)

- A global artifact registry across projects
- Content-addressed storage, dedup across streams
- Syncing `.nushell-mcp/` anywhere; encryption at rest
- Sharing one dotdir between nushell-mcp and para-agent (routing via
  `NU_MCP_JOURNAL_ROOT` instead)
