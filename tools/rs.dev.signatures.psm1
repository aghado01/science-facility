#Requires -Version 7.5

<#
.SYNOPSIS
    Developer utility — read PowerShell parameter surfaces out of the AST.

.DESCRIPTION
    DEVELOPER CONVENIENCE ONLY. Nothing in the pipeline imports this module; it is
    not a runtime path and carries no rs.core dependency. Keep it out of
    project-map's operational surface.

    Reflection (`Get-Command ... .Parameters`) is the wrong instrument for reading
    a parameter surface during development because it cannot see declared
    DEFAULTS: `ParameterMetadata` has no DefaultValue member (Name, ParameterType,
    ParameterSets, IsDynamic, Aliases, Attributes, SwitchParameter — that is the
    whole surface). Defaults exist only as expressions in the AST. That gap is
    what motivated this module: rs.core.internals carried a dead
    `$p.DefaultValue` line for exactly this reason.

    Three declaration forms are reported, because this codebase uses all three
    and a function-only walker would miss most of it:

      Script       a top-level param() block with no function wrapper — EVERY
                   processor in processors/ is this shape (the colonel body-only
                   contract), so it must be first-class here.
      Function     including nested interior helpers, legitimate since the
                   colonel AST-validation fix (rs-psstrip/_SplitCommentPopulation).
      ClassMethod  the stage classes (FileSystemCrawler, IgnoreCompiler,
                   RunspaceManager) live as PowerShell classes.

    Parse errors are reported but never fatal: the PS parser is error-recovering,
    so a broken file still yields whatever it could resolve.

.NOTES
    Promotion note: this module has no reposnapshot dependency and would work on
    any PowerShell tree. It lives here for locality (it arose from reposnapshot
    development); move it to a utils-level sibling if it earns wider use.

.EXAMPLE
    Import-Module .\tools\rs.dev.signatures.psm1
    Get-FunctionSignature -Command Invoke-Plan | Format-FunctionSignature

.EXAMPLE
    # What defaults does a processor declare?
    Get-FunctionSignature -Path .\reposnapshot-v3\processors\rs-indent.ps1 | Format-FunctionSignature

.EXAMPLE
    # Which params does the wrapper forward to each target? (the ingest split)
    (Get-FunctionSignature -Command Compile-Plan).Parameters.Name
    (Get-FunctionSignature -Command Invoke-Plan).Parameters.Name
#>

using namespace System.Management.Automation.Language

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Private — attribute readers
# ---------------------------------------------------------------------------

function Get-NamedArgumentValue
{
    # Returns the text of a [Parameter(...)] named argument, or $null.
    # `Mandatory` with no `= $true` has ExpressionOmitted set — that form means
    # $true, so it must not read as "absent".
    param([AttributeAst] $Attribute, [string] $ArgumentName)

    foreach ($na in $Attribute.NamedArguments)
    {
        if ($na.ArgumentName -ne $ArgumentName) { continue }
        if ($na.ExpressionOmitted) { return '$true' }
        return $na.Argument.Extent.Text
    }
    return $null
}

function ConvertTo-ParameterInfo
{
    param([ParameterAst] $Parameter)

    $typeText = $null
    $attrNames = [System.Collections.Generic.List[string]]::new()
    $aliases = [System.Collections.Generic.List[string]]::new()
    $mandatory = $false
    $position = $null
    $paramSets = [System.Collections.Generic.List[string]]::new()

    foreach ($a in $Parameter.Attributes)
    {
        if ($a -is [TypeConstraintAst])
        {
            # First type constraint wins — that is the declared parameter type.
            if ($null -eq $typeText) { $typeText = $a.TypeName.Extent.Text }
            continue
        }

        $attrNames.Add($a.TypeName.Name)

        switch ($a.TypeName.Name)
        {
            'Parameter'
            {
                $m = Get-NamedArgumentValue -Attribute $a -ArgumentName 'Mandatory'
                if ($m -match '\$true') { $mandatory = $true }

                $p = Get-NamedArgumentValue -Attribute $a -ArgumentName 'Position'
                if ($null -ne $p) { $position = $p }

                $ps = Get-NamedArgumentValue -Attribute $a -ArgumentName 'ParameterSetName'
                if ($null -ne $ps) { $paramSets.Add($ps.Trim("'", '"')) }
            }
            'Alias'
            {
                foreach ($pa in $a.PositionalArguments) { $aliases.Add($pa.Extent.Text.Trim("'", '"')) }
            }
        }
    }

    if ($null -eq $typeText -and $null -ne $Parameter.StaticType) { $typeText = $Parameter.StaticType.Name }

    # HasDefault vs DefaultText: `$x` and `$x = $null` are DIFFERENT declarations.
    # The null-sentinel pattern (Invoke-Plan's MaxWorkers) depends on that
    # distinction, so report both rather than collapsing them.
    $hasDefault = $null -ne $Parameter.DefaultValue

    [pscustomobject]@{
        Name          = $Parameter.Name.VariablePath.UserPath
        Type          = $typeText
        IsSwitch      = ($typeText -match '^\[?switch\]?$')
        HasDefault    = $hasDefault
        DefaultText   = if ($hasDefault) { $Parameter.DefaultValue.Extent.Text } else { $null }
        Mandatory     = $mandatory
        Position      = $position
        ParameterSets = $paramSets.ToArray()
        Aliases       = $aliases.ToArray()
        Attributes    = $attrNames.ToArray()
    }
}

function New-SignatureRecord
{
    param(
        [string] $Name,
        [string] $Kind,
        # [object], not [string]: a typed [string] parameter coerces $null to '',
        # collapsing "absent" into "empty". Same trap that made IgnoreCompiler's
        # GetParentPath return '' for a null parent (fixed there as [object]) —
        # here it would report a help-less function as having an empty synopsis
        # and a plain function as belonging to a class named ''.
        [object] $Class,
        [object] $ParamBlock,
        [object[]] $ParameterAsts,
        [object] $Extent,
        [string] $File,
        [bool] $IsNested,
        [bool] $IsAdvanced,
        [bool] $HasDynamicParam,
        [string[]] $OutputType,
        [object] $Synopsis
    )

    # A function may declare params either in param() or in the name(...) form;
    # ParameterAsts covers the latter and class methods.
    $paramAsts = if ($null -ne $ParamBlock) { $ParamBlock.Parameters } else { $ParameterAsts }
    $params = @()
    if ($null -ne $paramAsts)
    {
        $params = @($paramAsts | ForEach-Object { ConvertTo-ParameterInfo -Parameter $_ })
    }

    [pscustomobject]@{
        Name            = $Name
        Kind            = $Kind
        Class           = $Class
        File            = $File
        Line            = $Extent.StartLineNumber
        Location        = "$File`:$($Extent.StartLineNumber)"
        IsNested        = $IsNested
        IsAdvanced      = $IsAdvanced
        HasDynamicParam = $HasDynamicParam
        OutputType      = $OutputType
        Synopsis        = $Synopsis
        Parameters      = $params
        ParameterCount  = $params.Count
    }
}

function Expand-SignatureFromAst
{
    # The single walk shared by every input mode (file / text / command), so a
    # caller that already holds source in memory gets identical records to one
    # that points at a path. This is what makes the module wrappable by a
    # processor: chain items carry Content that upstream mutators have already
    # rewritten, and re-reading from disk would survey the wrong bytes.
    param(
        [ScriptBlockAst] $Ast,
        [string] $Source,
        [string] $NameFilter,
        [bool] $ExcludeNested,
        [bool] $ExcludeClassMethods
    )

    # --- Script-level param block (the processor shape) ---------------------
    if ($null -ne $Ast.ParamBlock)
    {
        $scriptName = [IO.Path]::GetFileNameWithoutExtension($Source)
        if ([string]::IsNullOrWhiteSpace($scriptName)) { $scriptName = $Source }
        if ($scriptName -like $NameFilter)
        {
            $facts = Get-ScriptBlockFacts -Ast $Ast
            New-SignatureRecord -Name $scriptName -Kind 'Script' -Class $null `
                -ParamBlock $Ast.ParamBlock -ParameterAsts $null -Extent $Ast.ParamBlock.Extent `
                -File $Source -IsNested $false -IsAdvanced $facts.IsAdvanced `
                -HasDynamicParam $facts.HasDynamicParam -OutputType $facts.OutputType -Synopsis $null
        }
    }

    # --- Functions (including interior helpers) -----------------------------
    foreach ($f in $Ast.FindAll({ param($n) $n -is [FunctionDefinitionAst] }, $true))
    {
        if ($f.Name -notlike $NameFilter) { continue }

        # Walk every ancestor, not just the grandparent: a helper can sit any
        # number of scriptblocks deep inside its owner.
        $nested = $false
        $ancestor = $f.Parent
        while ($null -ne $ancestor)
        {
            if ($ancestor -is [FunctionDefinitionAst]) { $nested = $true; break }
            $ancestor = $ancestor.Parent
        }
        if ($ExcludeNested -and $nested) { continue }

        $facts = Get-ScriptBlockFacts -Ast $f.Body
        $help = $f.GetHelpContent()

        New-SignatureRecord -Name $f.Name -Kind 'Function' -Class $null `
            -ParamBlock $f.Body.ParamBlock -ParameterAsts $f.Parameters -Extent $f.Extent `
            -File $Source -IsNested $nested -IsAdvanced $facts.IsAdvanced `
            -HasDynamicParam $facts.HasDynamicParam -OutputType $facts.OutputType `
            -Synopsis $(
                # GetHelpContent keeps the block's trailing newline —
                # trim so consumers get a clean one-liner.
                if ($null -ne $help -and -not [string]::IsNullOrWhiteSpace($help.Synopsis))
                { $help.Synopsis.Trim() } else { $null })
    }

    # --- Class methods ------------------------------------------------------
    if (-not $ExcludeClassMethods)
    {
        foreach ($t in $Ast.FindAll({ param($n) $n -is [TypeDefinitionAst] }, $true))
        {
            foreach ($m in $t.Members)
            {
                if ($m -isnot [FunctionMemberAst]) { continue }
                if ($m.Name -notlike $NameFilter) { continue }

                New-SignatureRecord -Name $m.Name -Kind 'ClassMethod' -Class $t.Name `
                    -ParamBlock $null -ParameterAsts $m.Parameters -Extent $m.Extent `
                    -File $Source -IsNested $false -IsAdvanced $false `
                    -HasDynamicParam $false `
                    -OutputType @($(if ($null -ne $m.ReturnType) { $m.ReturnType.TypeName.Extent.Text } else { 'void' })) `
                    -Synopsis $null
            }
        }
    }
}

function Get-ScriptBlockFacts
{
    # [CmdletBinding] / [OutputType] / dynamicparam presence for a scriptblock.
    param([ScriptBlockAst] $Ast)

    $isAdvanced = $false
    $outputTypes = [System.Collections.Generic.List[string]]::new()

    if ($null -ne $Ast.ParamBlock)
    {
        foreach ($a in $Ast.ParamBlock.Attributes)
        {
            switch ($a.TypeName.Name)
            {
                'CmdletBinding' { $isAdvanced = $true }
                'OutputType'
                {
                    foreach ($pa in $a.PositionalArguments) { $outputTypes.Add($pa.Extent.Text) }
                }
            }
        }
    }

    [pscustomobject]@{
        IsAdvanced      = $isAdvanced
        OutputType      = $outputTypes.ToArray()
        HasDynamicParam = ($null -ne $Ast.DynamicParamBlock)
    }
}

# ---------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Reports declared parameter surfaces — including DEFAULTS — from the AST.
.DESCRIPTION
    Emits one record per Script / Function / ClassMethod declaration found.
    Unlike reflection, DefaultText carries the default as written, and
    HasDefault distinguishes `$x` from `$x = $null`.
.PARAMETER Path
    One or more .ps1/.psm1 files. Accepts pipeline input from Get-ChildItem.
.PARAMETER Command
    An already-loaded command name, resolved via Get-Command. Convenient for
    imported modules when you do not want to hunt for the file.
    Caveat: resolution runs inside THIS module's session state, so it sees
    module-exported and global commands — not functions defined script-locally
    by the caller. Pass -Path for those.
.PARAMETER ScriptText
    Source held in memory. This is the mode a reposnapshot processor uses: chain
    items carry Content that upstream mutators have already rewritten, so the
    survey must read those bytes, never re-read the file from disk.
.PARAMETER SourceName
    Label stamped into File/Location for -ScriptText input, and the basis for a
    script record's Name. Pass the item's RelativePath so records stay
    addressable in artifact-facing terms (path doctrine).
.PARAMETER Name
    Wildcard filter on the declaration name. Default '*'.
.PARAMETER ExcludeNested
    Skip interior helper functions declared inside another function.
.PARAMETER ExcludeClassMethods
    Skip PowerShell class members.
#>
function Get-FunctionSignature
{
    [CmdletBinding(DefaultParameterSetName = 'ByPath')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, ParameterSetName = 'ByPath')]
        [Alias('FullName', 'PSPath')]
        [string[]] $Path,

        [Parameter(Mandatory, ParameterSetName = 'ByCommand')]
        [string[]] $Command,

        [Parameter(Mandatory, ParameterSetName = 'ByText')]
        [AllowEmptyString()]
        [string] $ScriptText,

        [Parameter(ParameterSetName = 'ByText')]
        [string] $SourceName = '<text>',

        [string] $Name = '*',

        [switch] $ExcludeNested,

        [switch] $ExcludeClassMethods
    )

    process
    {
        if ($PSCmdlet.ParameterSetName -eq 'ByCommand')
        {
            foreach ($c in $Command)
            {
                $cmd = Get-Command $c -ErrorAction Stop
                if ($null -eq $cmd.ScriptBlock)
                {
                    Write-Warning "[$c] is a $($cmd.CommandType), not a script command — no AST available."
                    continue
                }
                $sbAst = $cmd.ScriptBlock.Ast
                $facts = Get-ScriptBlockFacts -Ast (
                    $(if ($sbAst -is [FunctionDefinitionAst]) { $sbAst.Body } else { $sbAst }))
                $paramBlock = if ($sbAst -is [FunctionDefinitionAst]) { $sbAst.Body.ParamBlock } else { $sbAst.ParamBlock }

                New-SignatureRecord -Name $cmd.Name -Kind 'Function' -Class $null `
                    -ParamBlock $paramBlock -ParameterAsts $null -Extent $sbAst.Extent `
                    -File ($cmd.ScriptBlock.File ?? '<in-memory>') -IsNested $false `
                    -IsAdvanced $facts.IsAdvanced -HasDynamicParam $facts.HasDynamicParam `
                    -OutputType $facts.OutputType -Synopsis $null
            }
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'ByText')
        {
            $errs = [ref] $null
            $ast = [Parser]::ParseInput($ScriptText, [ref] $null, $errs)
            if ($errs.Value.Count -gt 0)
            {
                Write-Warning "[$SourceName] $($errs.Value.Count) parse error(s); reporting what resolved."
            }
            Expand-SignatureFromAst -Ast $ast -Source $SourceName -NameFilter $Name `
                -ExcludeNested $ExcludeNested.IsPresent -ExcludeClassMethods $ExcludeClassMethods.IsPresent
            return
        }

        foreach ($p in $Path)
        {
            $resolved = Resolve-Path -LiteralPath $p -ErrorAction Stop
            foreach ($r in $resolved)
            {
                $file = $r.ProviderPath
                $errors = [ref] $null
                $ast = [Parser]::ParseFile($file, [ref] $null, $errors)

                if ($errors.Value.Count -gt 0)
                {
                    # Non-fatal: the parser is error-recovering, so keep going.
                    Write-Warning "[$([IO.Path]::GetFileName($file))] $($errors.Value.Count) parse error(s); reporting what resolved."
                }

                Expand-SignatureFromAst -Ast $ast -Source $file -NameFilter $Name `
                    -ExcludeNested $ExcludeNested.IsPresent -ExcludeClassMethods $ExcludeClassMethods.IsPresent
            }
        }
    }
}

<#
.SYNOPSIS
    Renders Get-FunctionSignature records as readable signature blocks.
.DESCRIPTION
    Defaults are shown as declared, which is the point of the module — a
    parameter with no default reads differently from one defaulting to $null.
#>
function Format-FunctionSignature
{
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject[]] $Signature
    )

    process
    {
        foreach ($s in $Signature)
        {
            $header = switch ($s.Kind)
            {
                'Script' { "script  $($s.Name)" }
                'ClassMethod' { "method  [$($s.Class)]::$($s.Name)" }
                default { "function $($s.Name)" }
            }

            $tags = [System.Collections.Generic.List[string]]::new()
            if ($s.IsAdvanced) { $tags.Add('advanced') }
            if ($s.HasDynamicParam) { $tags.Add('dynamicparam') }
            if ($s.IsNested) { $tags.Add('nested') }
            $tagText = if ($tags.Count -gt 0) { "  [$($tags -join ', ')]" } else { '' }

            $out = [System.Text.StringBuilder]::new()
            [void]$out.AppendLine("$header$tagText   — $($s.Location)")

            if ($s.ParameterCount -eq 0)
            {
                [void]$out.AppendLine('    (no parameters)')
            }
            else
            {
                $widest = ($s.Parameters | ForEach-Object { "$($_.Type) `$$($_.Name)".Length } |
                        Measure-Object -Maximum).Maximum

                foreach ($p in $s.Parameters)
                {
                    $decl = "$($p.Type) `$$($p.Name)".PadRight($widest)
                    $suffix = if ($p.HasDefault) { " = $($p.DefaultText)" }
                    elseif ($p.Mandatory) { '   (mandatory)' }
                    else { '' }
                    [void]$out.AppendLine("    $decl$suffix".TrimEnd())
                }
            }

            $out.ToString().TrimEnd()
        }
    }
}

<#
.SYNOPSIS
    Compares two parameter surfaces — partition, plus same-name conflicts.
.DESCRIPTION
    Built for the forwarding pattern in rs.core.internals: a wrapper that
    reflects two targets must know which names belong to which, and a splat
    routed by a HARDCODED list rots the moment a target gains a parameter. That
    is not hypothetical — Invoke-Ingest withheld a hardcoded @('Items','Plan')
    from its compile splat, so every other Invoke-Plan-only param fell through
    into Compile-Plan and was rejected.

    Common parameters never appear: signatures come from the AST, which sees only
    the DECLARED param block (CmdletBinding adds commons at runtime).

    Conflicts are same-name parameters whose declared type or default differs.
    Those are the entries a "one side wins" merge would silently resolve — worth
    seeing before the merge decides for you.
.PARAMETER Reference
    A signature record from Get-FunctionSignature, or a command name to resolve.
.PARAMETER Difference
    Same, for the other side.
.EXAMPLE
    Compare-ParameterSurface -Reference Compile-Plan -Difference Invoke-Plan
#>
function Compare-ParameterSurface
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object] $Reference,

        [Parameter(Mandatory, Position = 1)]
        [object] $Difference
    )

    $refSig = Resolve-SignatureInput -InputObject $Reference
    $diffSig = Resolve-SignatureInput -InputObject $Difference

    $refByName = [ordered]@{}
    foreach ($p in $refSig.Parameters) { $refByName[$p.Name] = $p }
    $diffByName = [ordered]@{}
    foreach ($p in $diffSig.Parameters) { $diffByName[$p.Name] = $p }

    $onlyRef = [System.Collections.Generic.List[string]]::new()
    $onlyDiff = [System.Collections.Generic.List[string]]::new()
    $shared = [System.Collections.Generic.List[string]]::new()
    $conflicts = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($name in $refByName.Keys)
    {
        if (-not $diffByName.Contains($name)) { $onlyRef.Add($name); continue }

        $shared.Add($name)
        $a = $refByName[$name]
        $b = $diffByName[$name]
        $reasons = [System.Collections.Generic.List[string]]::new()
        if ($a.Type -ne $b.Type) { $reasons.Add('TypeMismatch') }
        if ($a.DefaultText -ne $b.DefaultText) { $reasons.Add('DefaultMismatch') }
        if ($a.Mandatory -ne $b.Mandatory) { $reasons.Add('MandatoryMismatch') }

        if ($reasons.Count -gt 0)
        {
            $conflicts.Add([pscustomobject]@{
                    Name              = $name
                    Reasons           = $reasons.ToArray()
                    ReferenceType     = $a.Type
                    DifferenceType    = $b.Type
                    ReferenceDefault  = $a.DefaultText
                    DifferenceDefault = $b.DefaultText
                })
        }
    }

    foreach ($name in $diffByName.Keys)
    {
        if (-not $refByName.Contains($name)) { $onlyDiff.Add($name) }
    }

    [pscustomobject]@{
        Reference        = $refSig.Name
        Difference       = $diffSig.Name
        OnlyInReference  = $onlyRef.ToArray()
        OnlyInDifference = $onlyDiff.ToArray()
        Shared           = $shared.ToArray()
        Conflicts        = $conflicts.ToArray()
        HasConflicts     = ($conflicts.Count -gt 0)
        IsDisjoint       = ($shared.Count -eq 0)
    }
}

function Resolve-SignatureInput
{
    # Accepts a signature record or a command name; anything with .Parameters
    # passes through so callers can pre-filter before comparing.
    param([object] $InputObject)

    if ($InputObject -is [string])
    {
        $sig = @(Get-FunctionSignature -Command $InputObject)
        if ($sig.Count -eq 0) { throw "No signature resolved for command '$InputObject'." }
        return $sig[0]
    }

    if ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties['Parameters'])
    {
        return $InputObject
    }

    throw 'Expected a Get-FunctionSignature record or a command name.'
}

Export-ModuleMember -Function @(
    'Get-FunctionSignature'
    'Format-FunctionSignature'
    'Compare-ParameterSurface'
)
