# Codex chat export

Exports a locally persisted Codex task into:

1. A canonical exchange-envelope JSONL intermediate representation.
2. Markdown with tunable structural, house, diarized, or dialogue formatting.

This directory is independent of `claude-export`. It reuses only the generic
`jso-jackson.ps1` primitives.

## Agent-facing export

Inside a Codex task:

```powershell
& "D:\aghado01\science-facility\utils\chat-export\codex-export\Export-CodexChat.ps1"
```

The wrapper reads the exact task identifier from `$env:CODEX_THREAD_ID`.
It never guesses from modification times. By default, Markdown is written to
`$env:JSO_EXPORT_DIR`, or `D:\aghado01\.discussion` when that variable is unset.
The exchanges JSONL and its `.jidx` remain in the returned working directory.

The wrapper returns:

```text
MarkdownPath
ExchangesPath
ThreadId
RolloutPath
WorkingDir
RunStamp
RunDir
NormalizeWhitespace
OutputEncoding
Stats
```

Agents should report those paths without reading the exported conversation back
into model context.

## Markdown controls

The default is a clean model-feeding export:

```powershell
& "$PWD\Export-CodexChat.ps1" `
    -Format Structural `
    -Exclude thinking,commentary,tool-calls,tool-results,subagents,synthetic,timestamps,session-markers,exchange-markers
```

Pass an empty exclusion list to retain every supported component:

```powershell
& "$PWD\Export-CodexChat.ps1" -Format House -Exclude @()
```

Final Markdown normalization defaults to enabled. For forensic comparison,
bypass only that postprocessor with the boolean option below. Choose another
output prefix so the unnormalized view does not overwrite the normalized file:

```powershell
& "$PWD\Export-CodexChat.ps1" `
    -OutputPrefix Codex-pre-normalization `
    -NormalizeWhitespace:$false
```

The opt-out does not bypass parsing or Markdown rendering and does not alter the
canonical exchanges JSONL.

Markdown files default to BOM-less UTF-8. Pass `-OutputEncoding Utf16LE` for an
`FF FE` BOM followed by the rendered .NET UTF-16 code units verbatim. This
changes only the Markdown writer; snapshot and exchange JSONL remain UTF-8.

For a strict normalized/pre-normalization pair from one frozen source and one
renderer invocation, use the shared research wrapper instead of invoking this
script twice:

```powershell
& "D:\aghado01\science-facility\utils\chat-export\Export-ChatWhitespacePair.ps1" `
    -Provider Codex `
    -OutputEncoding Utf16LE
```

Supported formats:

- `Structural`
- `House`
- `Diarized`
- `Dialogue`

Supported exclusion tokens:

- `thinking`
- `commentary`
- `tool-calls`
- `tool-results`
- `subagents`
- `synthetic`
- `timestamps`
- `session-markers`
- `exchange-markers`

Exclusions affect Markdown only. Exchange envelopes retain the normalized
records.

## Library endpoints

```powershell
. "D:\aghado01\science-facility\utils\chat-export\codex-export\codex-jso-run.ps1"

# Stop at the exchange-envelope IR.
Invoke-CodexThreadExport `
    -ThreadId $env:CODEX_THREAD_ID `
    -WorkingDir D:\portable\codex-export-runs `
    -RunThrough Exchanges

# Produce both exchange IR and Markdown.
Invoke-CodexThreadExport `
    -ThreadId $env:CODEX_THREAD_ID `
    -MarkdownDir D:\aghado01\.discussion `
    -Format Structural `
    -NormalizeWhitespace:$false `
    -OutputEncoding Utf16LE
```

## Exchange-envelope IR

Each JSONL line is one human-initiated exchange:

```text
_xid
_xidx
_thread_id
_turn_id
_source_thread
_session_uuid
_session_depth
_exchange_start
_exchange_end
_turn_count
_model
_effort
_user_label
_status
records[]
```

Atomic record types currently emitted:

- `prompt`
- `thinking`
- `response` with `phase: commentary | final_answer`
- `tool_call` with a matched `response` when present
- `subagent` activity marker

The parser consumes `response_item` records as the canonical content lane and
does not duplicate corresponding `event_msg` UI events. Rollback records remove
rolled-back turns from the exported IR.

## Storage and active tasks

Codex rollouts are resolved from:

```text
%CODEX_HOME%\sessions\YYYY\MM\DD\rollout-*-<thread-id>.jsonl
%CODEX_HOME%\archived_sessions\rollout-*-<thread-id>.jsonl
```

When `CODEX_HOME` is unset, `%USERPROFILE%\.codex` is used. Active rollouts are
snapshotted with read/write/delete sharing and an incomplete final JSON line is
dropped if the snapshot races a write.

The export is a snapshot. If invoked during an active response, the current
exchange may correctly have `_status: "in_progress"` and will contain only
content persisted before the snapshot.

## Portable runstamp layout

`WorkingDir` is always the relocatable root, never the directory for one
particular invocation. Every invocation selects a UTC `RunStamp` in
`yyyyMMdd_HHmmss` form and writes its internal artifacts beneath:

```text
WorkingDir\
└── RunStamp\
    ├── raw\
    │   ├── rollout-<thread-id>.jsonl
    │   └── rollout-<thread-id>.jidx
    ├── exchanges\
    │   ├── <prefix>-<thread-id>.jsonl
    │   └── <prefix>-<thread-id>.jidx
    └── output\
        └── <prefix>-<thread-id>.md
```

Passing `-WorkingDir` only relocates this structure. It does not suppress the
runstamp layer. Pass `-RunStamp` to coordinate stages around an existing run;
the value is validated against the canonical UTC format. When omitted, the
runner calls the shared `Get-JobTimestamp`.

The default root is:

```text
%CODEX_HOME%\tmp\codex-jso-run
```

An explicit `MarkdownPath`, `MarkdownDir`, or `$env:JSO_EXPORT_DIR` may place
the final deliverable outside the run directory. Raw and exchange IR artifacts
remain scoped to the runstamp.
