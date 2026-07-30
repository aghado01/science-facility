# claude-export — Claude Code chat thread → markdown

Turns a Claude Code session transcript (`.jsonl`) into readable markdown.

There are two audiences and two entry points. If you are an agent asked to export the
conversation you are in, you only need §1.

---

## 1. Agent: export this conversation

Call the script directly. Do **not** dot-source anything first — it loads what it needs:

```powershell
& "D:\aghado01\utils\jso-jackson\claude-export\Export-ClaudeChat.ps1" `
    -SessionId $env:CLAUDE_CODE_SESSION_ID
```

That is the whole call. It returns `{ MarkdownPath, SessionId, ProjectName, ThreadId }`.
**Report the path. Do not read the file back** — it is the conversation you just had, and pulling
it into your context is the one thing this tool exists to avoid.

**You never need to look up or pass:** the transcript's location, the project directory, or its
slug encoding. The session id resolves to its own `.jsonl` path and the project directory is a
component of that path, so supplying either would be redundant.

### Defaults, and when to override them

All three parameters have everyday defaults. Override one only when the user's request calls for
it — otherwise pass just `-SessionId`.

| Parameter | Default | Override when |
|---|---|---|
| `-SessionId` | `$env:CLAUDE_CODE_SESSION_ID` — the thread you are in | the user names a *different* thread |
| `-MarkdownDir` | `$env:JSO_EXPORT_DIR` if set, else `D:\aghado01\.discussion` | the user names a destination |
| `-Exclude` | the reading profile below | the user asks to keep something |
| `-OutputPrefix` | `chat` → `chat-{threadId}.md` | the user wants a different filename stem |

The default `-Exclude` keeps the prose conversation and nothing else — user turns and assistant
replies:

```powershell
@('thinking','synthetic','timestamps','session-markers',
  'exchange-markers','tool-calls','tool-results','subagents')
```

To keep something, name a *shorter* list — you are listing what to leave out, not what to keep:

```powershell
# "include the tool calls"  → stop excluding them
& .\Export-ClaudeChat.ps1 -SessionId $id -Exclude thinking,synthetic,timestamps,session-markers,exchange-markers,subagents

# "include everything"
& .\Export-ClaudeChat.ps1 -SessionId $id -Exclude @()

# "put it in my notes folder"
& .\Export-ClaudeChat.ps1 -SessionId $id -MarkdownDir 'D:\aghado01\notes'
```

Valid `-Exclude` values are `thinking`, `tool-calls`, `tool-results`, `subagents`, `synthetic`,
`timestamps`, `session-markers`, `exchange-markers`. A typo fails at parameter binding and lists
the valid set, so you do not have to remember them.

For anything beyond these four knobs — a different `-Format`, an exact output filename, stopping
at an intermediate stage — this script is the wrong tool. Use §2.

### When it fails, it fails loudly

No silent fallbacks anywhere in the resolution path. Each of these throws with the reason:

| Condition | Meaning |
|---|---|
| `No session id` | `$env:CLAUDE_CODE_SESSION_ID` is empty. Do not guess or substitute another id — `CLAUDE_CODE_HOST_SESSION_ID` is a *different* id and is not the transcript key. Report it; an empty session id is a system-level fault, not something to work around. |
| `No transcript found for session {id}` | The id is well-formed but no file exists. Same conclusion. |
| `Malformed session id` | Not a UUID. |
| `Ambiguous session id … N transcripts found` | Should be impossible. Report it verbatim. |
| `Cannot validate argument … -Exclude` | A record class was misspelled; the message lists the valid set. |

### Session rotation — why one conversation has several session files

Claude Code periodically mints a new session id partway through a conversation and writes a **full
cumulative copy** of the thread so far into the new file. Successive files are *snapshots, not
segments*: each opens with the same first user prompt and contains everything its predecessor did,
plus what came after.

**For you this is a non-issue.** The live session id is the newest snapshot, so exporting it gets
the complete conversation. Nothing is truncated and there is nothing to reassemble.

It matters only when exporting an **older** id: that yields the conversation as it stood at that
rotation, not its final state. To export a finished thread in full, use the newest session id
belonging to it — `Get-ClaudeThreadPlan -SessionId <any id from that thread>` lists what is in the
project directory.

Measured on this machine: 219 transcript files hold 87 distinct conversations; 58% of the bytes
under `~/.claude/projects` are redundant copies. Details:
[`../issues/brief-redundant-session-ids.md`](../issues/brief-redundant-session-ids.md) §8.

---

## 2. Human: everything else

Everything below is a function, so dot-source once:

```powershell
. "D:\aghado01\utils\jso-jackson\claude-export\claude-jso-run.ps1"
```

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
