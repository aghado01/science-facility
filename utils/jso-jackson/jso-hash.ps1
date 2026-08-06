# jso-hash.ps1 — Hashing primitives for Claude Code sub-agents
#
# Dot-source this file to get the Phase 1 hashing surface:
#
#   . "D:\aghado01\science-facility\utils\jso-jackson\jso-hash.ps1"
#
# FUNCTIONS
# ---------
#   Find-StringPattern   Rabin-Karp exact substring search.
#                        Use for QA anchor matching: locate a turn's first-8-words
#                        anchor inside raw JSONL content without full scanning.
#                        Returns array of 0-based match positions. Empty = no match.
#
#   Get-ContentFingerprint
#                        Rabin-Karp whole-content fingerprint (Int64).
#                        Use for turn deduplication keys (Phase 2).
#                        Deliberately NOT named Get-ContentHash — that name is
#                        taken by reposnapshot's rs.core.numerics (SHA256 hex),
#                        and no alias shim is provided: an alias would outrank
#                        the reposnapshot function and reintroduce the collision.
#
# CLASSES (available after dot-sourcing)
# ----------------------------------------
#   RabinKarpHash        Rolling hash engine. Base=257, Mod=1000000007.
#                        AddChar / RemoveChar / RollWindow / Reset.
#                        Used internally by Find-StringPattern and Get-ContentFingerprint.
#
# DEPENDENCY
# ----------
#   None. Fully self-contained. No Import-Module, no dot-source chains.
#
# SOURCE
# ------
#   RabinKarpHash  — storage.psm1 (context-guardian), canonical bug-fixed version
#   Find-StringPattern — rewritten against RabinKarpHash (replaces tooldig.readwrite
#                        version which depended on hashing-primitives.psm1)
# -----------------------------------------------------------------------

class RabinKarpHash
{
    [uint32] $Hash
    [int]    $WindowSize
    [uint32] $Base      = 257
    [uint32] $Mod       = 1000000007
    [uint32] $BasePower

    RabinKarpHash([int]$windowSize)
    {
        $this.WindowSize = $windowSize
        $this.Hash       = 0
        $this.BasePower  = 1
        for ($i = 0; $i -lt $windowSize; $i++)
        {
            # Cast to long before multiply — uint32*uint32 can exceed uint32 range
            # at WindowSize > 5 (257^6 > 4.29B). Result fits back in uint32 after mod.
            $this.BasePower = [uint32](([long]$this.BasePower * [long]$this.Base) % [long]$this.Mod)
        }
    }

    [uint32] AddChar([char]$c)
    {
        $this.Hash = (($this.Hash * $this.Base) + [int]$c) % $this.Mod
        return $this.Hash
    }

    # RollWindow: correct formula is hash = (hash*base - oldChar*base^m + newChar) mod mod
    # BasePower = base^m (set in constructor), so this is a single composed operation.
    # RemoveChar and AddChar are NOT composed here — composing them produces the wrong result
    # because AddChar multiplies by base AFTER the removal, yielding base^(m+1) not base^m.
    [uint32] RollWindow([char]$oldChar, [char]$newChar)
    {
        [long]$h        = ([long]$this.Hash * $this.Base) % $this.Mod
        [long]$removal  = ([long][int]$oldChar * $this.BasePower) % $this.Mod
        $h = ($h - $removal + [long]$this.Mod) % $this.Mod
        $h = ($h + [int]$newChar) % $this.Mod
        $this.Hash = [uint32]$h
        return $this.Hash
    }

    [void] Reset() { $this.Hash = 0 }
}

function Get-ContentFingerprint
{
    <#
    .SYNOPSIS
        Rabin-Karp whole-content fingerprint. Returns Int64.
    .DESCRIPTION
        Feeds every character through a RabinKarpHash roller and returns the
        final hash value. Use as a fast deduplication key for turn content.
    .PARAMETER Content
        String to fingerprint.
    .PARAMETER WindowSize
        Rolling window size (default 32). Affects hash distribution, not correctness.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Content,

        [int]$WindowSize = 32
    )
    process
    {
        if ([string]::IsNullOrWhiteSpace($Content)) { return 0L }
        $roller = [RabinKarpHash]::new($WindowSize)
        foreach ($char in $Content.ToCharArray()) { [void]$roller.AddChar($char) }
        return [long]$roller.Hash
    }
}

function Find-StringPattern
{
    <#
    .SYNOPSIS
        Rabin-Karp exact substring search. Returns 0-based match positions.
    .DESCRIPTION
        Searches Text for all occurrences of Pattern using rolling-hash comparison.
        Returns an [int[]] of starting indices. Empty array = no match.

        Primary use: QA anchor matching. Given an anchor string (first 8 words of a
        turn), locate it inside a raw JSONL line without scanning full file content.

        O(n + m) average case. Falls back to character comparison on hash collision
        to eliminate false positives.
    .PARAMETER Text
        The string to search within.
    .PARAMETER Pattern
        The exact substring to find.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Pattern
    )

    [int]$n = $Text.Length
    [int]$m = $Pattern.Length
    [int[]]$matches = @()

    if ($m -eq 0 -or $m -gt $n) { return $matches }

    $patternRoller = [RabinKarpHash]::new($m)
    $textRoller    = [RabinKarpHash]::new($m)

    # Build pattern hash and initial window hash.
    for ($i = 0; $i -lt $m; $i++)
    {
        [void]$patternRoller.AddChar($Pattern[$i])
        [void]$textRoller.AddChar($Text[$i])
    }

    [uint32]$patternHash = $patternRoller.Hash

    for ($i = 0; $i -le $n - $m; $i++)
    {
        if ($textRoller.Hash -eq $patternHash)
        {
            # Hash match — verify character by character to rule out collision.
            if ($Text.Substring($i, $m) -ceq $Pattern)
            {
                $matches += $i
            }
        }

        # Roll window forward (skip on last iteration).
        if ($i -lt $n - $m)
        {
            [void]$textRoller.RollWindow($Text[$i], $Text[$i + $m])
        }
    }

    return $matches
}
