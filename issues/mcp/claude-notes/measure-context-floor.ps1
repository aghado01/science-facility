<#
.SYNOPSIS
  Measure Claude Code context floor and token spend from harness-written transcripts.

.DESCRIPTION
  Reads ~/.claude/projects/**/*.jsonl. These are written by the harness itself, so the
  numbers are independent of any MCP server, hook, or routing layer.

  "Floor" = total input context of a session's FIRST request
          = system prompt + tool schemas + skill listing + agent listing + CLAUDE.md + MEMORY.md
  Compare floors across project roots at the SAME version to isolate config cost.
  Toggle one setting, start a fresh session, re-run, and diff the floor.

.EXAMPLE
  .\measure-context-floor.ps1                      # all roots, floor by version
  .\measure-context-floor.ps1 -Project D--aghado01 -PerSession
  .\measure-context-floor.ps1 -Project D--aghado01 -PerDay
#>
[CmdletBinding()]
param(
  [string]$Root = "$env:USERPROFILE\.claude\projects",
  [string]$Project,
  [switch]$PerSession,
  [switch]$PerDay,
  [int]$Last = 25
)

function Read-Session {
  param([System.IO.FileInfo]$File)
  $seen = @{}; $reqs = @(); $ver = $null
  foreach ($line in [System.IO.File]::ReadLines($File.FullName)) {
    if (-not $ver) {
      $m = [regex]::Match($line, '"version":"(\d+\.\d+\.\d+)"')
      if ($m.Success) { $ver = $m.Groups[1].Value }
    }
    if ($line -notlike '*"usage"*') { continue }
    $rid = [regex]::Match($line, '"requestId":"([^"]+)"').Groups[1].Value
    if (-not $rid -or $seen.ContainsKey($rid)) { continue }   # dedupe: one API call = many transcript lines
    $seen[$rid] = 1
    $i  = [int][regex]::Match($line, '"input_tokens":(\d+)').Groups[1].Value
    $cc = [int][regex]::Match($line, '"cache_creation_input_tokens":(\d+)').Groups[1].Value
    $cr = [int][regex]::Match($line, '"cache_read_input_tokens":(\d+)').Groups[1].Value
    $o  = [int][regex]::Match($line, '"output_tokens":(\d+)').Groups[1].Value
    $reqs += [pscustomobject]@{ In = $i; CC = $cc; CR = $cr; Out = $o; Tot = $i + $cc + $cr }
  }
  if (-not $reqs.Count) { return $null }
  $med = { param($a) if (-not $a.Count) { 0 } else { [int](($a | Sort-Object)[[int]($a.Count / 2)]) } }
  [pscustomobject]@{
    Session  = $File.BaseName.Substring(0, 8)
    Date     = $File.LastWriteTime.ToString('MM-dd')
    Version  = $ver
    Reqs     = $reqs.Count
    Floor    = $reqs[0].Tot
    MedTot   = & $med $reqs.Tot
    MedOut   = & $med $reqs.Out
    SumOut   = ($reqs | Measure-Object Out -Sum).Sum
    CacheW   = ($reqs | Measure-Object CC  -Sum).Sum
    CacheR   = ($reqs | Measure-Object CR  -Sum).Sum
    SizeMB   = [math]::Round($File.Length / 1MB, 1)
  }
}

$dirs = if ($Project) { @(Get-Item (Join-Path $Root $Project)) }
        else { Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue }

$all = foreach ($d in $dirs) {
  foreach ($f in Get-ChildItem $d.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
    $r = Read-Session $f
    if ($r) { $r | Add-Member -NotePropertyName Proj -NotePropertyValue $d.Name -PassThru }
  }
}

if (-not $all) { Write-Warning "No transcripts with usage records under $Root"; return }

if ($PerSession) {
  Write-Host "`n=== per session (last $Last) ===" -ForegroundColor Cyan
  $all | Sort-Object Date, Session | Select-Object -Last $Last |
    Format-Table Date, Session, Version, Reqs, Floor, MedTot, MedOut, SumOut, SizeMB -AutoSize
}

if ($PerDay) {
  Write-Host "`n=== per day ===" -ForegroundColor Cyan
  $all | Group-Object Date | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{
      Date       = $_.Name
      Sessions   = $_.Count
      Reqs       = ($_.Group | Measure-Object Reqs -Sum).Sum
      MedFloor   = [int](($_.Group.Floor  | Sort-Object)[[int]($_.Count / 2)])
      MedOutReq  = [int](($_.Group.MedOut | Sort-Object)[[int]($_.Count / 2)])
      CacheWrite = ($_.Group | Measure-Object CacheW -Sum).Sum
      CacheRead  = ($_.Group | Measure-Object CacheR -Sum).Sum
    }
  } | Format-Table -AutoSize
}

if (-not $PerSession -and -not $PerDay) {
  Write-Host "`n=== floor by Claude Code version (floor tracks version; spread within a version is YOUR config) ===" -ForegroundColor Cyan
  $all | Group-Object Version | Sort-Object { $_.Group[0].Date } | ForEach-Object {
    [pscustomobject]@{
      Version  = $_.Name
      Sessions = $_.Count
      MinFloor = ($_.Group.Floor | Measure-Object -Minimum).Minimum
      MedFloor = [int](($_.Group.Floor | Sort-Object)[[int]($_.Count / 2)])
      MaxFloor = ($_.Group.Floor | Measure-Object -Maximum).Maximum
      Days     = (($_.Group.Date | Sort-Object -Unique) -join ',')
    }
  } | Format-Table -AutoSize

  Write-Host "=== floor by project root, newest version only (isolates project .mcp.json + CLAUDE.md) ===" -ForegroundColor Cyan
  $newest = ($all | Sort-Object Date | Select-Object -Last 1).Version
  $all | Where-Object Version -eq $newest | Group-Object Proj | Sort-Object { $_.Group[0].Floor } -Descending | ForEach-Object {
    [pscustomobject]@{
      Project  = $_.Name
      Sessions = $_.Count
      MinFloor = ($_.Group.Floor | Measure-Object -Minimum).Minimum
      MaxFloor = ($_.Group.Floor | Measure-Object -Maximum).Maximum
    }
  } | Format-Table -AutoSize
  Write-Host "  (version $newest; difference between roots = project-scoped MCP servers + project CLAUDE.md)`n" -ForegroundColor DarkGray
}

Write-Host ("totals: {0} sessions, {1} requests, {2:N0} output tok, {3:N0} cache-read tok, {4:N0} cache-write tok" -f `
  $all.Count, ($all | Measure-Object Reqs -Sum).Sum, ($all | Measure-Object SumOut -Sum).Sum, `
  ($all | Measure-Object CacheR -Sum).Sum, ($all | Measure-Object CacheW -Sum).Sum) -ForegroundColor Green
