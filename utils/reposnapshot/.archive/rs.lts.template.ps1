#Requires -Version 7.2

<#
.SYNOPSIS
    Micro template engine and TOC model builders for RepoSnapshot tree manifest files.

.DESCRIPTION
    Engine directives (Handlebars-lite):
        {{Name}}                   — scalar substitution
        {{#if Name}}...{{/if}}     — conditional block; falsy = null / empty string / empty array
        {{#each Name}}...{{/each}} — loop; {{this}} for scalar items, {{Prop}} for object items

    Public surface:
        Expand-TocTemplate    — expand $script:TocTemplate against a model hashtable/pscustomobject
        New-SnapshotTocModel  — build model for a JSON (.json) snapshot tree manifest
        New-ShardedTocModel   — build model for a sharded (.txt) snapshot tree manifest

    Internal (available after dot-sourcing):
        Resolve-TemplateValue — dotted-path property resolver
        Expand-Template       — recursive three-pass expander

.NOTES
    Standalone file — dot-source to use. Not a module.
    Integration COMPLETE: RepoSnapshotLts.psm1 consumes this engine via
    Import-TocTemplateEngine (Get-RepoSnapshot and Shard-SnapshotFile render
    tree manifests through Expand-TocTemplate).
    Named precedent of the config/code-separation architecture (assemble
    design): neutral engine · thin model builders · the variable parts
    (template string, instruction sets) as declarative data. The template
    fixes the artifact's SECTION SEQUENCE; models supply content —
    operation-order doctrine, writer level.

    QUEUED — Compaction section (design 2026-08-09, not yet implemented):
    the codec's cipher key belongs here, as an optional `{{#if Compaction}}`
    block placed BEFORE the Tree block (adjacent to Instructions — both are
    reader guidance), plus a model-builder field. The tree file is the
    payload's exclusive entrypoint and is read first, which is what makes it
    the correct carrier: the key precedes all shard content structurally, not
    by convention. Contents are a RECEIPT of substitutions actually made, not
    a catalog of what the codec can do — an absent entry is information. Each
    entry names the target character AND its code point (`\n -> LF U+000A`);
    a bare `{newline}` would blur the LF/CR/CRLF distinction the codec's
    preserve stance exists to maintain. Spec: issues/shard-format-notes.md
    §"The Compaction block"; obligation: payload-manifest-ledger #16.
#>

# ---------------------------------------------------------------------------
# Shared template
# Single-quoted here-string: backticks, dollar signs, and {{...}} are all literal.
# ---------------------------------------------------------------------------

$script:TocTemplate = @'
# Tree Manifest TOC for Snapshot: `{{Title}}`

{{#if SummaryLine}}{{SummaryLine}}

{{/if}}Payload:
{{#each PayloadLines}}{{this}}
{{/each}}
## Instructions

{{#each Instructions}}{{this}}
{{/each}}
## Tree for `{{TreeLabel}}`
```
{{ColumnHeader}}
{{TocTree}}
```
'@

# ---------------------------------------------------------------------------
# Engine — private helpers
# ---------------------------------------------------------------------------

function Resolve-TemplateValue
{
    <#
    .SYNOPSIS
        Resolve a dotted property path against a model, with optional current-item override.
    .PARAMETER Model
        Root model object (pscustomobject or hashtable).
    .PARAMETER Path
        Dotted property name, e.g. "Header.Title". Special value "this" returns $CurrentItem.
    .PARAMETER CurrentItem
        Current loop item, if inside an #each block.
    #>
    param(
        [Parameter(Mandatory)] $Model,
        [Parameter(Mandatory)] [string] $Path,
        $CurrentItem = $null
    )

    if ($Path -eq 'this') { return $CurrentItem }

    # Prefer CurrentItem's property if it has one, otherwise fall back to Model
    $target = if (
        $null -ne $CurrentItem -and
        $CurrentItem -is [psobject] -and
        $null -ne $CurrentItem.PSObject.Properties[$Path]
    )
    {
        $CurrentItem
    }
    else
    {
        $Model
    }

    $value = $target
    foreach ($part in ($Path -split '\.'))
    {
        if ($null -eq $value) { return $null }
        $prop = $value.PSObject.Properties[$part]
        if ($null -eq $prop) { return $null }
        $value = $prop.Value
    }

    return $value
}

function Expand-Template
{
    <#
    .SYNOPSIS
        Expand a template string against a model in three passes: each → if → scalars.
    .PARAMETER Template
        Template string containing {{...}} directives.
    .PARAMETER Model
        Root model (pscustomobject).
    .PARAMETER CurrentItem
        Current loop item; set automatically during #each expansion.
    #>
    param(
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] $Model,
        $CurrentItem = $null
    )

    $result = $Template

    # Pass 1: expand {{#each Name}}...{{/each}}
    $eachRx = [System.Text.RegularExpressions.Regex]::new(
        '\{\{#each\s+([^\}]+)\}\}(.*?)\{\{/each\}\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    while ($eachRx.IsMatch($result))
    {
        $result = $eachRx.Replace($result, {
                param($m)
                $name = $m.Groups[1].Value.Trim()
                $body = $m.Groups[2].Value
                $items = @(Resolve-TemplateValue -Model $Model -Path $name -CurrentItem $CurrentItem)
                ($items | ForEach-Object {
                    Expand-Template -Template $body -Model $Model -CurrentItem $_
                }) -join ''
            })
    }

    # Pass 2: expand {{#if Name}}...{{/if}}
    $ifRx = [System.Text.RegularExpressions.Regex]::new(
        '\{\{#if\s+([^\}]+)\}\}(.*?)\{\{/if\}\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    while ($ifRx.IsMatch($result))
    {
        $result = $ifRx.Replace($result, {
                param($m)
                $name = $m.Groups[1].Value.Trim()
                $body = $m.Groups[2].Value
                $value = Resolve-TemplateValue -Model $Model -Path $name -CurrentItem $CurrentItem
                $empty = (
                    $null -eq $value -or
                    ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) -or
                    ($value -isnot [string] -and $value -is [System.Collections.IEnumerable] -and @($value).Count -eq 0)
                )
                if ($empty) { '' } else { Expand-Template -Template $body -Model $Model -CurrentItem $CurrentItem }
            })
    }

    # Pass 3: scalar {{Name}} substitution
    $scalarRx = [System.Text.RegularExpressions.Regex]::new('\{\{\s*([A-Za-z0-9_.@]+)\s*\}\}')
    $result = $scalarRx.Replace($result, {
            param($m)
            $name = $m.Groups[1].Value.Trim()
            $value = Resolve-TemplateValue -Model $Model -Path $name -CurrentItem $CurrentItem
            if ($null -eq $value) { '' } else { [string]$value }
        })

    return $result
}

function Get-MonolithInstructionSet
{
    <#
    .SYNOPSIS
        Instruction set for MONOLITH (.json) snapshot tree manifests.
    #>
    [pscustomobject]@{
        Primary = @(
            'Monolith snapshot manifests are single JSON files containing the entire tree metadata. They can be large and unwieldy, but are simple to generate and consume.'
        )
        Secondary = @()
    }
}

function Get-ShardedInstructionSet
{
    <#
    .SYNOPSIS
        Instruction set for SHARDED (.txt) snapshot tree manifests — the
        virtual-DB guidance block (reader-directed guidance is a first-class
        payload feature; shard-format-notes doctrine).
    #>
    [pscustomobject]@{
        Primary = @(
            'Treat this payload like a virtual database which may be selectively scanned/seeked with byte offsets available for random-access and intentional seeking/fetching.'
            'You can manage "firehose" context overload by selectively seeking segments of the payload file iteratively over multiple inference cycles.'
            'Do not use grep to search the data because it will return an explosion of duplications.'
        )
        Secondary = @(
            'Seek to `row_offset` in the .json file to read any entry directly without scanning.'
            'The shard files are intentionally .txt to encourage use of lower level tools like `read_file` instead of json tools.'
        )
    }
}


# ---------------------------------------------------------------------------
# Model builders
# ---------------------------------------------------------------------------

function New-SnapshotTocModel
{
    <#
    .SYNOPSIS
        Build the template model for a JSON snapshot tree manifest.
    .PARAMETER TreeStem
        Filename stem of the .json snapshot, e.g. "myrepo_20260426_120000".
    .PARAMETER TreeFile
        Full path to the _tree.md output file (leaf name is used in Payload).
    .PARAMETER TocTree
        Pre-rendered tree string from Build-TocTree.
    #>
    param(
        [Parameter(Mandatory)] [string] $TreeStem,
        [Parameter(Mandatory)] [string] $TreeFile,
        [Parameter(Mandatory)] [string] $TocTree
    )

    $instructionSet = Get-MonolithInstructionSet

    [pscustomobject]@{
        Title        = "$TreeStem.json"
        SummaryLine  = ''
        PayloadLines = @("``./$( Split-Path $TreeFile -Leaf )``")
        Instructions = @($instructionSet.Primary) + $instructionSet.Secondary
        TreeLabel    = "$TreeStem.json"
        ColumnHeader = 'file row metadata: name<TAB>row_offset<TAB>row_meta_end<TAB>row_content_begin<TAB>row_content_end'
        TocTree      = $TocTree
    }
}

function New-ShardedTocModel
{
    <#
    .SYNOPSIS
        Build the template model for a sharded snapshot tree manifest.
    .PARAMETER PathParts
        Path-parts object from Get-SnapshotPathParts; needs .Stem property.
    .PARAMETER TreeFile
        Full path to the _tree.md output file.
    .PARAMETER Results
        Shard result objects; each must expose .Path (string) and .Files (int).
    .PARAMETER SummaryLine
        Pre-formatted summary string shown below the title.
        Example: "Strategy: Auto | MaxShardSizeKB: 2048 | Created: 20260426211500 | Shards: 4"
    .PARAMETER TocTree
        Pre-rendered tree string from Build-TocTree.
    #>
    param(
        [Parameter(Mandatory)] $PathParts,
        [Parameter(Mandatory)] [string] $TreeFile,
        [Parameter(Mandatory)] $Results,
        [Parameter(Mandatory)] [string] $SummaryLine,
        [Parameter(Mandatory)] [string] $TocTree,
        [Parameter()] [bool] $WriteMetadataBlock = $true,
        [Parameter()] [string[]] $ExcludedShardBlocks = @()
    )

    $stem = $PathParts.Stem
    $treeLeaf = "``./$( Split-Path $TreeFile -Leaf )``"
    $shardLeaves = @($Results | ForEach-Object { "``./$( Split-Path $_.Path -Leaf )`` files:$($_.Files)" })

    $instructionSet = Get-ShardedInstructionSet
    [pscustomobject]@{
        Title        = "${stem}_s*.txt"
        SummaryLine  = $SummaryLine
        PayloadLines = @($treeLeaf) + $shardLeaves
        Instructions = @($instructionSet.Primary) + $instructionSet.Secondary
        TreeLabel    = "${stem}_s*.txt"
        ColumnHeader = 'file row metadata: name<TAB>shard_index<TAB>row_offset<TAB>row_meta_end<TAB>row_content_begin<TAB>row_content_end'
        TocTree      = $TocTree
        WriteMetadataBlock = $WriteMetadataBlock
        ExcludedShardBlocks = $ExcludedShardBlocks
    }
}

# ---------------------------------------------------------------------------
# Public render function
# ---------------------------------------------------------------------------

function Expand-TocTemplate
{
    <#
    .SYNOPSIS
        Expand $script:TocTemplate against a model and return the rendered string.
    .PARAMETER Model
        pscustomobject produced by New-SnapshotTocModel or New-ShardedTocModel.
    .OUTPUTS
        Rendered string with trailing whitespace trimmed (ready for Set-Content).
    #>
    param(
        [Parameter(Mandatory)] $Model
    )

    (Expand-Template -Template $script:TocTemplate -Model $Model).TrimEnd()
}
