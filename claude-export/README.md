# claude-export — Claude Code chat thread → markdown

Turns a Claude Code session transcript (`.jsonl`) into readable markdown.

There are two audiences and two entry points. If you are an agent asked to export the
conversation you are in, you only need §1.

```powershell
. "D:\aghado01\utils\jso-jackson\claude-export\claude-jso-run.ps1"
```

Dot-sourcing that one file loads everything.

---

## 1. Agent: export this conversation

```powershell
Export-ClaudeChat -OutputDir 'D:\aghado01\.discussion'
```

That is the whole call. It exports the thread you are currently running inside and returns
`{ MarkdownPath, SessionId, ProjectName, ThreadId }`. **Report the path. Do not read the file
back** — it is the conversation you just had, and pulling it into your context is the one thing
this tool exists to avoid.

**You do not need to know, look up, or pass:** the session id (taken from
`$env:CLAUDE_CODE_SESSION_ID`), the transcript's location, the project directory, its slug
encoding, the rendering format, or a working directory. All of it is either discovered or fixed.

`-OutputDir` may be omitted if `$env:JSO_EXPORT_DIR` is set. If neither is set the call throws —
it will not bury a deliverable in a temp directory. To export a *different* thread, pass
`-SessionId`. To change the filename stem from `chat`, pass `-OutputPrefix`.

### What you get

The prose conversation: user turns and assistant replies. Thinking blocks, tool calls, tool
results, subagent transcripts, synthetic records, timestamps, and session/exchange markers are all
excluded. If you need any of those, this is the wrong function — use §2.

### When it fails, it fails loudly

No silent fallbacks anywhere in the resolution path. Each of these throws with the reason:

| Condition | Meaning |
|---|---|
| `No session id` | `$env:CLAUDE_CODE_SESSION_ID` is empty. Do not guess or substitute another id — `CLAUDE_CODE_HOST_SESSION_ID` is a *different* id and is not the transcript key. Report it; an empty session id is a system-level fault, not something to work around. |
| `No transcript found for session {id}` | The id is well-formed but no file exists. Same conclusion. |
| `Malformed session id` | Not a UUID. |
| `Ambiguous session id … N transcripts found` | Should be impossible. Report it verbatim. |
| `No output directory` | Pass `-OutputDir` or set `$env:JSO_EXPORT_DIR`. |

### One limitation worth knowing

A conversation can be spread across more than one session file, and this export covers one.

- A thread that grows very long gets **continued**, leaving a `.jsonl.idx` sentinel next to the
  older file. The sentinel walk finds those automatically and merges them into one export. Nothing
  to do.
- But switching away to another chat and back **within a running Claude app mints a new session
  id**, with no sentinel and no back-link to the earlier file. That earlier portion will not be in
  the export.

So if an exported thread looks like it starts mid-conversation, this is why — it is not a bug in
the renderer. Details and current thinking: [`../issues/brief-redundant-session-ids.md`](../issues/brief-redundant-session-ids.md) §8.

---

## 2. Human: everything else

`Invoke-ClaudeThreadExport` is the full single-thread pipeline with every knob exposed. It takes
either a session id or a directory:

```powershell
# by session id
Invoke-ClaudeThreadExport -SessionId $id -MarkdownDir $out

# by directory, optionally narrowed to specific sessions
Invoke-ClaudeThreadExport -SourceDir $projectDir -SessionIds $ids -MarkdownDir $out
```

Useful parameters: `-Format` (`Structural` | `Diarized` | `Dialogue` | `House`), `-Exclude` (any
of `thinking`, `tool-calls`, `tool-results`, `subagents`, `synthetic`, `timestamps`,
`session-markers`, `exchange-markers`), `-RunThrough` (`Merged` | `Exchanges` | `Markdown`) to
stop early, `-MarkdownPath` for an exact output file, `-UserLabel`, `-MaxToolInputLength`,
`-WorkingDir`, `-OutputPrefix`.

`Get-ClaudeThreadPlan` shows how a project directory partitions into threads without exporting
anything:

```powershell
Get-ClaudeThreadPlan -SessionId $id      # the project that session belongs to
Get-ClaudeThreadPlan -SourceDir $dir
```

`Invoke-ClaudeThreadExportBatch` exports **every** thread in a project directory — 100+ files for
a busy project. Bulk tool, not an agent tool:

```powershell
Invoke-ClaudeThreadExportBatch -SessionId $id -MarkdownDir $out
Invoke-ClaudeThreadExportBatch -SourceDir $dir -MarkdownDir $out
```

`Resolve-ClaudeThreadPath -SessionId $id` just locates a transcript and returns
`{ SessionId, JsonlPath, SourceDir, ProjectName, ConfigRoot }` without exporting.

Every function has a full comment-based help block; `Get-Help <name> -Full` is authoritative.

---

## 3. How location works

Transcripts live at `{configRoot}/projects/{encodedProjectDir}/{sessionId}.jsonl`, and session
UUIDs are unique across project directories. So a session id alone is a sufficient key: probing
each project directory for `{sessionId}.jsonl` finds it exactly, and because the project slug is a
*component of the path it was found at*, the same lookup yields the directory too. That is why no
entry point needs both an id and a directory.

The config root is discovered, not assumed — `-ConfigRoot`, then `$env:CLAUDE_CONFIG_DIR`, then
`$env:CLAUDE_HOME`, then conventional locations under the OS-reported user home, each candidate
required to actually contain `projects/`. Env vars are an accelerator: they exist only inside
Claude Code sessions, so cron jobs and plain shells fall through to the probe.

### Environment variables

| Variable | Effect |
|---|---|
| `CLAUDE_CODE_SESSION_ID` | Set by Claude Code. The default for `Export-ClaudeChat -SessionId`. |
| `JSO_EXPORT_DIR` | Standing destination for single-thread deliverables. Optional. The batch runner ignores it by design. |
| `CLAUDE_CONFIG_DIR` / `CLAUDE_HOME` | Pin the Claude config root. Optional — discovery handles it. |

### Where intermediate files go

The pipeline stages through `raw/`, `merged/`, and `exchanges/` JSONL under a timestamped working
directory at `{configRoot}/tmp/claude-jso-run/{UTC yyyyMMdd_HHmmss}/`. Only the markdown lands in
your output directory. Pass `-WorkingDir` to `Invoke-ClaudeThreadExport` to put the intermediates
somewhere else.
