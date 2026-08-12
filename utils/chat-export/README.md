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

Both Markdown renderers pass their completed document through the shared
`chat-export-format-ws.ps1` final-stage formatter. It normalizes line endings
and Unicode, removes zero-width formatting characters, compacts prose
whitespace, and retains significant whitespace in Markdown code and tool
payloads. Valid generated tool-call JSON is normalized recursively so escaped
invisible characters are removed without corrupting its structure; truncated
or non-JSON payloads remain literal. Canonical merged and exchange JSONL
artifacts are not modified.

Regression checks:

```powershell
& "D:\aghado01\science-facility\utils\chat-export\tests\claude-export.tests.ps1"
& "D:\aghado01\science-facility\utils\chat-export\tests\markdown-whitespace.tests.ps1"
```
