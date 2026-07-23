```Powershell
$projectDir = 'c--Users-azrie-PDenv-UserGithub-PowerShellCore-ps-core-pwshspc'
$srcDir = "$env:CLAUDE_CONFIG_DIR/projects/$projectDir"
. "$env:CLAUDE_CONFIG_DIR/tools/claude-jso-run.ps1" -Force
$batch = Invoke-ClaudeThreadExportBatch -SourceDir $srcDir
```
