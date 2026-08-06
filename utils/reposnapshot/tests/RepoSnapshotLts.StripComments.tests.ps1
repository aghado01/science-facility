#Requires -Version 7.5
# Pester tests for Normalize-FileContent -StripComments string-literal safety.
#
# Acceptance coverage for issues/lts-stripcomments-string-corruption.md:
#   - Round-trip: rs-psstrip.ps1 regex literals (the angle-hash block pattern)
#     survive intact.
#   - Span-deletion: a string-embedded block-comment opener with no closer in the
#     same literal must not pair with a later closer and delete real code.
#   - Real doc comment blocks and standalone # lines still stripped; #Requires
#     and inline comments kept.
#   - .cs/.py/.js branches: comment markers inside string literals preserved.
#
# (Header deliberately uses # line comments: spelling the block-comment closer
#  inside a block comment would terminate it early — the very defect under test.)
#
# Run:  Invoke-Pester -Path tests\RepoSnapshotLts.StripComments.tests.ps1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\RepoSnapshotLts.psm1') -Force -DisableNameChecking
}

Describe 'Normalize-FileContent -StripComments: PowerShell (tokenizer path)' {

    It 'round-trips rs-psstrip.ps1: every [regex]::new literal survives intact' {
        $srcPath = Join-Path $PSScriptRoot '..\reposnapshot-v3\processors\rs-psstrip.ps1'
        $src = Get-Content -Raw $srcPath
        $out = Normalize-FileContent -Content $src -RelPath 'processors/rs-psstrip.ps1' -StripComments $true

        # Dynamic: pull each single-quoted [regex]::new pattern from source and
        # require it verbatim in the normalized output.
        $literals = [regex]::Matches($src, "\[regex\]::new\('([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        $literals.Count | Should -BeGreaterThan 0
        foreach ($lit in $literals)
        {
            $out.Contains($lit) | Should -BeTrue -Because "regex literal '$lit' must survive normalization"
        }

        # The proven corruption from the selfie snapshot must not reappear.
        $out.Contains("[regex]::new('(?s)', 'None')") | Should -BeFalse

        # Comments themselves are still stripped.
        $out.Contains('.COMMENT KINDS') | Should -BeFalse
    }

    # NB: no angle-hash sequences in It names — Pester 6 name templating chokes on them.
    It 'does not delete a span when a string-embedded comment opener has no closer in the same literal' {
        $content = @'
$opener = 'contains <# but no closer'
$survivor = 'this line must survive'
# real comment
$closer = 'stray closer #> here'
$x = 42
'@
        $out = Normalize-FileContent -Content $content -RelPath 'f.ps1' -StripComments $true
        $out.Contains("'contains <# but no closer'") | Should -BeTrue
        $out.Contains("'this line must survive'") | Should -BeTrue
        $out.Contains("'stray closer #> here'") | Should -BeTrue
        $out.Contains('$x = 42') | Should -BeTrue
        $out.Contains('# real comment') | Should -BeFalse
    }

    It 'still strips doc blocks and standalone # lines; keeps #Requires and inline comments' {
        $content = @'
#Requires -Version 7.5
<#
.SYNOPSIS
    Module help.
#>
function Foo
{
    # standalone comment line
    $x = 1 # inline comment stays
    return $x
}
'@
        $out = Normalize-FileContent -Content $content -RelPath 'f.psm1' -StripComments $true
        $out.Contains('.SYNOPSIS') | Should -BeFalse
        $out.Contains('# standalone comment line') | Should -BeFalse
        $out.Contains('#Requires -Version 7.5') | Should -BeTrue
        $out.Contains('# inline comment stays') | Should -BeTrue
        $out.Contains('$x = 1') | Should -BeTrue
    }

    It 'preserves comment-like sequences inside here-strings' {
        $content = @'
$doc = @"
Example: <# looks like a comment #>
"@
$y = 1
'@
        $out = Normalize-FileContent -Content $content -RelPath 'f.ps1' -StripComments $true
        $out.Contains('<# looks like a comment #>') | Should -BeTrue
    }

    It 'still strips comments via tokens when the file has syntax errors; code survives' {
        # Tolerance case (design constraint): ingestion never gates on validity.
        # Unbalanced brace + half-written statement — tokenizer is error-recovering.
        $content = @'
function Broken {
    # doomed comment
    $x = 'literal with <# marker'
    if ($x -eq
'@
        $out = Normalize-FileContent -Content $content -RelPath 'broken.ps1' -StripComments $true
        $out.Contains("'literal with <# marker'") | Should -BeTrue
        $out.Contains('# doomed comment') | Should -BeFalse
        $out.Contains('function Broken {') | Should -BeTrue
        $out.Contains('if ($x -eq') | Should -BeTrue
    }

    It 'keeps a line-1 shebang as frontmatter' {
        $content = @'
#!/usr/bin/env pwsh
# ordinary comment removed
$z = 3
'@
        $out = Normalize-FileContent -Content $content -RelPath 'tool.ps1' -StripComments $true
        $out.StartsWith('#!/usr/bin/env pwsh') | Should -BeTrue
        $out.Contains('# ordinary comment removed') | Should -BeFalse
        $out.Contains('$z = 3') | Should -BeTrue
    }
}

Describe 'Normalize-FileContent -StripComments: C#' {

    It 'preserves comment markers inside string literals; strips real comments' {
        $content = @'
var a = "/* not a comment */";
var b = "// also not";
var v = @"verbatim /* keep */ text";
/* real block comment */
int x = 1; // trailing comment kept
// standalone comment removed
int y = 2;
'@
        $out = Normalize-FileContent -Content $content -RelPath 'f.cs' -StripComments $true
        $out.Contains('"/* not a comment */"') | Should -BeTrue
        $out.Contains('"// also not"') | Should -BeTrue
        $out.Contains('@"verbatim /* keep */ text"') | Should -BeTrue
        $out.Contains('real block comment') | Should -BeFalse
        $out.Contains('// trailing comment kept') | Should -BeTrue
        $out.Contains('// standalone comment removed') | Should -BeFalse
        $out.Contains('int y = 2;') | Should -BeTrue
    }
}

Describe 'Normalize-FileContent -StripComments: Python' {

    It 'preserves hash/triple-quote sequences inside literals; strips docstrings and # lines' {
        $content = @'
#!/usr/bin/env python
url = "http://example.com#anchor"
data = """triple-quoted data kept"""
def f():
    """docstring removed"""
    return url  # trailing comment kept
# standalone comment removed
z = 1
'@
        $out = Normalize-FileContent -Content $content -RelPath 'f.py' -StripComments $true
        $out.StartsWith('#!/usr/bin/env python') | Should -BeTrue
        $out.Contains('"http://example.com#anchor"') | Should -BeTrue
        $out.Contains('"""triple-quoted data kept"""') | Should -BeTrue
        $out.Contains('docstring removed') | Should -BeFalse
        $out.Contains('# trailing comment kept') | Should -BeTrue
        $out.Contains('# standalone comment removed') | Should -BeFalse
        $out.Contains('z = 1') | Should -BeTrue
    }
}

Describe 'Normalize-FileContent -StripComments: JS/TS' {

    It 'preserves comment markers inside strings and templates; strips real comments' {
        $content = @'
const a = "http://example.com/path";
const b = 'contains /* not a comment */';
const t = `template with // slashes`;
/* real block removed */
let x = 1; // trailing kept
// standalone removed
let y = 2;
'@
        $out = Normalize-FileContent -Content $content -RelPath 'f.ts' -StripComments $true
        $out.Contains('"http://example.com/path"') | Should -BeTrue
        $out.Contains("'contains /* not a comment */'") | Should -BeTrue
        $out.Contains('`template with // slashes`') | Should -BeTrue
        $out.Contains('real block removed') | Should -BeFalse
        $out.Contains('// trailing kept') | Should -BeTrue
        $out.Contains('// standalone removed') | Should -BeFalse
        $out.Contains('let y = 2;') | Should -BeTrue
    }
}
