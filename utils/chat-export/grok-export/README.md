# Grok chat export

Exports a locally persisted Grok session into:

1. A canonical exchange-envelope JSONL intermediate representation.
2. Markdown with tunable structural, house, diarized, or dialogue formatting.

This directory holds the Grok session locator, `chat_history.jsonl` parser, and
the agent-facing entry point. Snapshot, exchange-envelope I/O, Markdown
rendering, and run/path resolution live in `../shared` so a later Claude or
Codex pass can reuse them without another renderer clone.

## Agent-facing export

Inside a Grok session:

```powershell
& "D:\aghado01\science-facility\utils\chat-export\grok-export\Export-GrokChat.ps1"
```

The wrapper reads the exact session identifier from `$env:GROK_SESSION_ID`.
It never guesses from modification times. By default, Markdown is written to
`$env:JSO_EXPORT_DIR`, or `D:\aghado01\.discussion` when that variable is unset.
The exchanges JSONL and its `.jidx` remain in the returned working directory.

The wrapper returns:

```text
MarkdownPath
ExchangesPath
SessionId
ThreadId
HistoryPath
SessionDir
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
& "$PWD\Export-GrokChat.ps1" `
    -Format Structural `
    -Exclude thinking,commentary,tool-calls,tool-results,subagents,synthetic,timestamps,session-markers,exchange-markers
```

Pass an empty exclusion list to retain every supported component:

```powershell
& "$PWD\Export-GrokChat.ps1" -Format House -Exclude @()
```

Final Markdown normalization defaults to enabled. For forensic comparison,
bypass only that postprocessor with the boolean option below. Choose another
output prefix so the unnormalized view does not overwrite the normalized file:

```powershell
& "$PWD\Export-GrokChat.ps1" `
    -OutputPrefix Grok-pre-normalization `
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
    -Provider Grok `
    -OutputEncoding Utf16LE
```

Supported formats:

- `Structural`
- `House`
- `Diarized`
- `Dialogue`

Supported exclusion tokens:

- `thinking`
- `commentary` (accepted; Grok IR does not currently emit commentary)
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
. "D:\aghado01\science-facility\utils\chat-export\grok-export\grok-jso-run.ps1"

# Stop at the exchange-envelope IR.
Invoke-GrokThreadExport `
    -SessionId $env:GROK_SESSION_ID `
    -WorkingDir D:\portable\grok-export-runs `
    -RunThrough Exchanges

# Produce both exchange IR and Markdown.
Invoke-GrokThreadExport `
    -SessionId $env:GROK_SESSION_ID `
    -MarkdownDir D:\aghado01\.discussion `
    -Format Structural `
    -NormalizeWhitespace:$false `
    -OutputEncoding Utf16LE

# Render a frozen exchange JSONL with the shared Markdown renderer.
ConvertTo-ChatMarkdown `
    -ExchangesJsonlPath $exchangesPath `
    -Provider grok `
    -AssistantLabel Grok `
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
_turn_count
_model
_effort
_user_label
_status
records[]
```

Atomic record types currently emitted:

- `prompt` (inner text of `<user_query>` when present)
- `synthetic` (injected `user_info` / `system_reminder` / `synthetic_reason`)
- `thinking` from `reasoning.summary`
- `response` with `phase: final_answer`
- `tool_call` with a matched `response` when present
- `subagent` activity marker for `spawn_subagent` / `task`

The parser consumes `chat_history.jsonl` as the canonical content lane and does
not duplicate the ACP `updates.jsonl` UI stream. `type=system` records are
skipped. Leading injected context before the first `prompt_index` is held and
attached to the first human exchange as `synthetic`.

## Storage and active sessions

Grok sessions are resolved from:

```text
%GROK_HOME%\sessions\<encoded-cwd>\<session-id>\chat_history.jsonl
```

When `GROK_HOME` is unset, `%USERPROFILE%\.grok` is used. Resolution searches
for a directory named exactly `<session-id>` that contains `chat_history.jsonl`.
Zero or multiple hits throw; there is no newest-mtime fallback.

Active histories are snapshotted with read/write/delete sharing and an
incomplete final JSON line is dropped if the snapshot races a write.

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
    │   ├── chat_history-<session-id>.jsonl
    │   └── chat_history-<session-id>.jidx
    ├── exchanges\
    │   ├── <prefix>-<session-id>.jsonl
    │   └── <prefix>-<session-id>.jidx
    └── output\
        └── <prefix>-<session-id>.md
```

Passing `-WorkingDir` only relocates this structure. It does not suppress the
runstamp layer. Pass `-RunStamp` to coordinate stages around an existing run;
the value is validated against the canonical UTC format. When omitted, the
runner calls the shared `Get-JobTimestamp`.

The default root is:

```text
%GROK_HOME%\chat-export
```

When `GROK_HOME` is unset, that is `%USERPROFILE%\.grok\chat-export`.

An explicit `MarkdownPath`, `MarkdownDir`, or `$env:JSO_EXPORT_DIR` may place
the final deliverable outside the run directory. Raw and exchange IR artifacts
remain scoped to the runstamp.
