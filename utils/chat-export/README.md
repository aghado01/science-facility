# Chat export entrypoints

For an ordinary export, invoke the applicable wrapper directly. These commands
are the complete agent-facing contracts; reading or dot-sourcing their
implementation is unnecessary unless the user asks to debug or modify an
exporter.

```powershell
# Current Claude Code chat
& "D:\aghado01\science-facility\utils\chat-export\claude-export\Export-ClaudeChat.ps1"

# Current Codex task
& "D:\aghado01\science-facility\utils\chat-export\codex-export\Export-CodexChat.ps1"
```

Pass only user-requested output or exclusion overrides. Report the returned
path or paths without reading the generated transcript back into model context.

The Claude merge stage deduplicates copied continuation history by record UUID.
It retains distinct thinking, text, and tool-use records even when Claude assigns
them the same response `message.id`.
