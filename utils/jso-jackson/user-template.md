```Powershell
# Dot-source the export pipeline
. "D:\aghado01\science-facility\utils\jso-jackson\claude-export\claude-jso-run.ps1"

# Source directory
$sourceDir = "C:\Users\azrie\.claude\projects\D--aghado01-codex-scientiae"

# Destination directory for markdown
$markdownDir = "D:\aghado01\.discussion"

# Just the specific session ID
$sessionId = "b7d823db-3846-4cda-a535-ff7da75b2f5b"

# Default exclusions
# $exclude = @('thinking','synthetic', 'timestamps', 'session-markers','exchange-markers','tool-calls', 'tool-results','subagents')

# Non-default forensic exclusions -- everything except elements introduced by the export process itself
$exclude = @('synthetic')

# Run the export for the specified session
$result = Invoke-ClaudeThreadExport `
    -SourceDir $sourceDir `
    -SessionIds @($sessionId) `
    -MarkdownDir $markdownDir `
    -Exclude $exclude `
    -Format 'Structural' `
    -OutputPrefix 'opus'
```
