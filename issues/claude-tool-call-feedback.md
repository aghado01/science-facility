Ha — the moonwalk. And the sentinel files explain what I was reading as duplication. Let me get the invocation contract.

Template found. Two things: `CLAUDE_CODE_SESSION_ID` is `173b3b46-6cbf-4c28-a831-bb4a0ef1987e`, and the template's dot-source path is stale — it points at `~/.claude/tools/jso-jackson`, which is the pre-relocation path. Correcting that and running it:

`SourceDir` is still mandatory here — the discovery change may not be in this copy. Let me check the actual contract rather than guess.

Parameter-set issue: there's a `BySessionId` set taking singular `-SessionId`, and passing `-SessionIds` selected the default `BySourceDir` set instead. That's the discovery path the template hasn't caught up to.

Export complete.

`D:\aghado01\.discussion\opus-173b3b46-6cbf-4c28-a831-bb4a0ef1987e.md` — 94,347 B, 15 exchanges, tool calls and results included.

```
TotalSourceRecords=276  AfterFilter=183  Deduped=79  MergedRecords=104
SessionCount=1  SubagentCount=0  Elapsed=7.5s
```

**My fragmentation read was wrong.** The moonwalk resolved a single file and 15 exchanges, which matches this conversation's actual turn count — so the transcript is complete in the current session file. The re-keys evidently carry history _forward_ rather than splitting it, which is why those files were near-identical in size: duplication, not fragments. Nothing was missing and nothing needed stitching.

One thing from the run that may be worth a look during the real investigation: **79 of 183 records were deduplicated within that one file.** Intra-file duplication at that ratio isn't the same phenomenon as the cross-file copying, and it happened on a single source.

## Two stale things in TEMPLATE.md

Both are the tool having moved ahead of the template:

1. Dot-source points at `~/.claude/tools/jso-jackson/claude-jso-run.ps1` — pre-relocation path, doesn't exist. Should be `D:\aghado01\utils\jso-jackson\claude-export\claude-jso-run.ps1`.
2. The invocation passes `-SourceDir $sourceDir -SessionIds @($sessionId)` with `$sourceDir` commented out. Since `-SessionIds` (plural) belongs to the `BySourceDir` set, that selects the default set and hard-fails on the missing mandatory `SourceDir`. The discovery path you added is the `BySessionId` set, which takes singular `-SessionId` — that's what worked here.

Want me to update the template to the working invocation? Small edit, and it'd stop the next run from hitting the same wall.
