```Powershell
# Dot-source the export pipeline
. "~/.claude/tools/jso-jackson/claude-jso-run.ps1"

# Source directory
$sourceDir = "C:\Users\azrie\.claude\projects\D--aghado01-codex-scientiae"

# Destination directory for markdown
$markdownDir = "D:\aghado01\.discussion"

# Just the specific session ID
$sessionId = "b7d823db-3846-4cda-a535-ff7da75b2f5b"

# Run the export with only that session
$exclude = @('thinking','synthetic', 'timestamps', 'session-markers','exchange-markers','tool-calls', 'tool-results','subagents')
$result = Invoke-ClaudeThreadExport `
    -SourceDir $sourceDir `
    -SessionIds @($sessionId) `
    -MarkdownDir $markdownDir `
    -Exclude $exclude `
    -Format 'Structural' `
    -OutputPrefix 'opus'
```
