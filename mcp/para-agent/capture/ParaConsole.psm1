#Requires -Version 7.2
<#
.SYNOPSIS
    Interactive console capture for the para-agent journal.

.DESCRIPTION
    `run` captures the commands para-agent dispatches. This module captures the
    ones it does not: anything a human or an agent types straight into the pane,
    including a REPL session driven through `send`.

    Two mechanisms, chosen for what they can actually see:

      Command metadata comes from a `prompt` hook. PowerShell calls `prompt`
      after every command, and `$?` / `$LASTEXITCODE` / `Get-History` are all
      accurate at that moment, so the hook can record what ran, how long it
      took, and how it ended.

      Output comes from `Start-Transcript`, sliced by byte offset between
      prompts. An `Out-Default` proxy would have been the obvious choice and is
      the wrong one: `Write-Host` writes to the host rather than the pipeline,
      so a proxy silently misses it. The transcript is what the host actually
      displayed, which is the thing worth journalling.

    Records are appended to `inbox.jsonl` rather than to the journal itself.
    The journal is single-writer by design — para-agent assigns `seq` — so this
    producer hands over envelopes and lets the reader do the sequencing. That
    also means nothing here can corrupt the journal if it crashes mid-write.

.NOTES
    Domain: para-agent
    Role: interactive producer
    Contract: contract/CONSOLE-CONTRACT.md
#>

$script:ParaDir = $null
$script:ParaInbox = $null
$script:ParaTranscript = $null
$script:ParaOffset = 0
$script:ParaLastHistoryId = -1
$script:ParaOriginalPrompt = $null
$script:ParaActive = $false

# Commands para-agent dispatches itself look like `. 'C:\...\turns\000007.ps1'`.
# Those are already journalled by the run path, so recording them again here
# would double every captured turn.
$script:ParaSelfPattern = "^\s*\.\s+'.*[\\/]turns[\\/]\d{6}\.(ps1|sh)'\s*$"

function Initialize-ParaConsole {
    <#
    .SYNOPSIS
        Begin capturing interactive commands in this shell.
    .PARAMETER StreamDir
        The journal stream directory, e.g. <root>/streams/<session>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StreamDir
    )

    if ($script:ParaActive) {
        Write-Verbose "[para] already active"
        return
    }

    $script:ParaDir = $StreamDir
    $script:ParaInbox = Join-Path $StreamDir 'inbox.jsonl'
    $script:ParaTranscript = Join-Path $StreamDir 'interactive.transcript'

    if (-not (Test-Path $StreamDir)) {
        New-Item -ItemType Directory -Path $StreamDir -Force | Out-Null
    }

    try {
        Start-Transcript -Path $script:ParaTranscript -Append -Force | Out-Null
    }
    catch {
        # Transcription is the output half only. Without it we still capture
        # command metadata, and the note below makes the gap visible rather
        # than letting it look like commands produced no output.
        Write-ParaEnvelope @{
            kind = 'note'
            note = "transcription unavailable: $($_.Exception.Message). Interactive turns will have metadata but no output body."
        }
    }

    $script:ParaOffset = Get-ParaTranscriptLength
    $h = Get-History -Count 1
    $script:ParaLastHistoryId = if ($h) { $h.Id } else { 0 }

    $script:ParaOriginalPrompt = $function:prompt
    Set-Item -Path function:global:prompt -Value {
        # Capture BEFORE anything else runs — both are clobbered instantly.
        $__paraOk = $?
        $__paraCode = $LASTEXITCODE
        try { Write-ParaTurn -Ok $__paraOk -Code $__paraCode } catch { }
        if ($script:ParaOriginalPrompt) { & $script:ParaOriginalPrompt } else { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
    }

    $script:ParaActive = $true
    Write-ParaEnvelope @{ kind = 'note'; note = 'interactive capture started'; data = @{ pid = $PID } }
    Write-Verbose "[para] capturing to $script:ParaInbox"
}

function Stop-ParaConsole {
    <#
    .SYNOPSIS
        Stop capturing and restore the original prompt.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:ParaActive) { return }

    if ($script:ParaOriginalPrompt) {
        Set-Item -Path function:global:prompt -Value $script:ParaOriginalPrompt
    }
    try { Stop-Transcript | Out-Null } catch { }
    Write-ParaEnvelope @{ kind = 'note'; note = 'interactive capture stopped' }
    $script:ParaActive = $false
}

function Get-ParaTranscriptLength {
    try { (Get-Item -LiteralPath $script:ParaTranscript -ErrorAction Stop).Length }
    catch { 0 }
}

function Write-ParaEnvelope {
    <#
    .SYNOPSIS
        Append one envelope to the inbox for para-agent to sequence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Record)

    if (-not $script:ParaInbox) { return }
    $Record['producer'] = 'interactive'
    if (-not $Record.ContainsKey('ts')) {
        $Record['ts'] = (Get-Date).ToUniversalTime().ToString('o')
    }
    $json = [pscustomobject]$Record | ConvertTo-Json -Compress -Depth 6
    # Retry briefly: the reader renames the inbox to drain it, so a write can
    # land in the gap. Losing a record silently is worse than a 30ms wait.
    for ($i = 0; $i -lt 5; $i++) {
        try {
            Add-Content -LiteralPath $script:ParaInbox -Value $json -Encoding utf8 -ErrorAction Stop
            return
        }
        catch { Start-Sleep -Milliseconds 10 }
    }
}

function Write-ParaTurn {
    <#
    .SYNOPSIS
        Emit an envelope for the command that just finished, if there was one.
    #>
    [CmdletBinding()]
    param($Ok, $Code)

    $h = Get-History -Count 1
    if (-not $h) { return }
    if ($h.Id -le $script:ParaLastHistoryId) { return }   # prompt redrawn, no new command
    $script:ParaLastHistoryId = $h.Id

    $cmd = $h.CommandLine
    if ($cmd -match $script:ParaSelfPattern) {
        # A para-agent run turn — already journalled by the run path.
        $script:ParaOffset = Get-ParaTranscriptLength
        return
    }

    $end = Get-ParaTranscriptLength
    $start = $script:ParaOffset
    $script:ParaOffset = $end

    $duration = $null
    if ($h.EndExecutionTime -and $h.StartExecutionTime) {
        $duration = [int]($h.EndExecutionTime - $h.StartExecutionTime).TotalMilliseconds
    }

    Write-ParaEnvelope @{
        kind        = 'turn'
        cmd         = $cmd
        cwd         = (Get-Location).Path
        shell       = 'pwsh'
        origin      = 'interactive'
        code        = $Code
        ok          = [bool]$Ok
        duration_ms = $duration
        transcript  = @{
            file  = 'interactive.transcript'
            start = $start
            end   = $end
        }
    }
}

Export-ModuleMember -Function @(
    'Initialize-ParaConsole',
    'Stop-ParaConsole',
    'Write-ParaEnvelope'
)
