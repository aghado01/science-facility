#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs.tex.strip.ps1.

.DESCRIPTION
    Tests the TeX/LaTeX processor directly (dot-invoked) to isolate behavior from dispatcher mechanics.
    Covers:
      1. Item unpacking — string / hashtable / pscustomobject
      2. FrontMatter + mask lens + default ops
      3. Selective ops — each kind in isolation
      4. Whitespace suppression preservation
      5. QuickExit optimization (no % in content)
      6. Real-world specimen battery (LaTeXML latexml.sty)
      7. Harmonized content-mutator contract (6d)
#>

$processorPath = Join-Path $PSScriptRoot '..\rs.tex.strip.ps1'

# Shared ISS helpers
. (Join-Path $PSScriptRoot '_helpers.ps1')

#region Assertions
$script:Passed = 0
$script:Failed = 0

function Enter-Section ([string]$Name)
{
    Write-Host "`n── $Name" -ForegroundColor Cyan
}

function Assert-True ([bool]$Condition, [string]$Label, [string]$Detail = '')
{
    if ($Condition)
    {
        $script:Passed++
        Write-Host "    PASS  $Label" -ForegroundColor Green
    }
    else
    {
        $script:Failed++
        $msg = "    FAIL  $Label"
        if ($Detail) { $msg += "  ($Detail)" }
        Write-Host $msg -ForegroundColor Red
    }
}

function Assert-Equal ($Actual, $Expected, [string]$Label)
{
    Assert-True ($Actual -eq $Expected) $Label "expected $(([string]$Expected).Length -le 60 ? "'$Expected'" : "(value)"), got $(([string]$Actual).Length -le 60 ? "'$Actual'" : "(value)")"
}

function Invoke-Processor ([object]$Item, [hashtable]$Config = @{})
{
    if ($Item -is [string]) { $Item = [pscustomobject]@{ Content = $Item } }
    & $processorPath $Item $Config
}

function Invoke-ProcessorRaw ([object]$Item, [hashtable]$Config = @{})
{
    & $processorPath $Item $Config
}
#endregion

#region Fixture
$fixture = @'
% !TeX program = pdflatex
% !TEX root = main.tex
% block line one
% block line two
\documentclass{article}

\usepackage{amsmath}
\usepackage{url}

\begin{comment}
This is a multi-line comment block
using the comment package.
\end{comment}

% isolated single line comment

\newcommand{\mybox}[1]{%
  \mbox{%
    \textbf{#1}%
  }%
}

\def\sample#1{
  The discount is 20\% today!
  Row break then comment: \\% this is a comment after linebreak
  Three slashes: \\\% this is literal percent after linebreak
}

\url{https://example.com/query%20test}
\verb|foo%bar|
\verb*+abc%def+
\lstinline|x%y|

\begin{verbatim}
verbatim line 1 % not a comment
verbatim line 2
\end{verbatim}

\setlength{\parindent}{0pt} % inline comment kept by default
\end{document}
'@
#endregion

Write-Host "`n============================================================" -ForegroundColor White
Write-Host " rs.tex.strip.tests.ps1" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White

# ============================================================
# Section 1: Item Unpacking
# ============================================================
Enter-Section "1. Item unpacking"

$rawStr = "% comment`n\relax"
$resStr = Invoke-ProcessorRaw $rawStr
Assert-True ($resStr -is [string]) "String item: bare string in → bare string out"
Assert-Equal $resStr "\relax" "String item: stripping applied to the returned string"

$hashItem = @{ Content = "% comment`n\relax"; Path = 'sample.tex' }
$resHash = Invoke-ProcessorRaw $hashItem
Assert-True ($resHash -is [pscustomobject]) "Hashtable item: cloned to pscustomobject"

$objItem = [pscustomobject]@{ Content = "% comment`n\relax"; Id = 'spec-01'; Path = 'pkg.sty' }
$resObj = Invoke-ProcessorRaw $objItem
Assert-True ($resObj -is [pscustomobject]) "PSCustomObject item: returns pscustomobject"
Assert-Equal $resObj.Id 'spec-01' "PSCustomObject item: Id propagated"
Assert-Equal $resObj.Path 'pkg.sty' "PSCustomObject item: Path propagated"

$record = $resObj.Processing[-1]
Assert-True ($null -ne $record) "Processing record attached"
Assert-Equal $record.Implementation 'rs.tex.strip' "Implementation is rs.tex.strip"

# ============================================================
# Section 2: FrontMatter + Mask Lens + Default Ops
# ============================================================
Enter-Section "2. FrontMatter + mask lens + default ops"

$resDefault = Invoke-Processor $fixture
$outText = $resDefault.Content

Assert-True ($outText.Contains("% !TeX program = pdflatex")) "Default: magic comment line 1 kept"
Assert-True ($outText.Contains("% !TEX root = main.tex")) "Default: magic comment line 2 kept"
Assert-True (-not $outText.Contains("% block line one")) "Default: CommentBlock line 1 stripped"
Assert-True (-not $outText.Contains("% block line two")) "Default: CommentBlock line 2 stripped"
Assert-True (-not $outText.Contains("% isolated single line comment")) "Default: LineComment stripped"
Assert-True (-not $outText.Contains("This is a multi-line comment block")) "Default: \begin{comment} block stripped"
Assert-True ($outText.Contains("% inline comment kept by default")) "Default: InlineComment kept"

# Mask lens checks
Assert-True ($outText.Contains("20\% today!")) "Mask: \% literal percent preserved"
Assert-True ($outText.Contains("Row break then comment: \\% this is a comment after linebreak")) "Mask: \\% recognized as inline comment (kept by default)"
Assert-True ($outText.Contains('\\\% this is literal percent')) "Mask: \\\% literal percent preserved"
Assert-True ($outText.Contains('\url{https://example.com/query%20test}')) "Mask: \url content with % preserved"
Assert-True ($outText.Contains('\verb|foo%bar|')) "Mask: \verb content with % preserved"
Assert-True ($outText.Contains('\verb*+abc%def+')) "Mask: \verb* content with % preserved"
Assert-True ($outText.Contains('\lstinline|x%y|')) "Mask: \lstinline content with % preserved"
Assert-True ($outText.Contains("verbatim line 1 % not a comment")) "Mask: \begin{verbatim} content with % preserved"

# Structure preservation
Assert-True ($outText.Contains('\newcommand{\mybox}[1]{%')) "Default: macro continuation {% preserved"
Assert-True ($outText.Contains('\textbf{#1}%')) "Default: inner continuation preserved"
Assert-True (-not $outText.Contains([char]0x01)) "Mask: no sentinel U+0001 leaked"

# Shebang test
$shebangInput = "#!/usr/bin/env texlua`n% comment`nprint('hello')"
$shebangRes = Invoke-Processor $shebangInput
Assert-True ($shebangRes.Content.StartsWith("#!/usr/bin/env texlua")) "Default: shebang on line 1 kept"
Assert-True (-not $shebangRes.Content.Contains("% comment")) "Default: comment after shebang stripped"

# ============================================================
# Section 3: Selective Ops
# ============================================================
Enter-Section "3. Selective ops"

$blockOnly = Invoke-Processor $fixture @{ Operations = @('block-comments') }
Assert-True (-not $blockOnly.Content.Contains("This is a multi-line comment block")) "block-comments: \begin{comment} stripped"
Assert-True ($blockOnly.Content.Contains("% block line one")) "block-comments: CommentBlock kept"
Assert-True ($blockOnly.Content.Contains("% isolated single line comment")) "block-comments: LineComment kept"

$cbOnly = Invoke-Processor $fixture @{ Operations = @('comment-blocks') }
Assert-True (-not $cbOnly.Content.Contains("% block line one")) "comment-blocks: 2-line run stripped"
Assert-True ($cbOnly.Content.Contains("% isolated single line comment")) "comment-blocks: isolated LineComment kept"
Assert-True ($cbOnly.Content.Contains("This is a multi-line comment block")) "comment-blocks: \begin{comment} kept"

$lineOnly = Invoke-Processor $fixture @{ Operations = @('line-comments') }
Assert-True (-not $lineOnly.Content.Contains("% isolated single line comment")) "line-comments: isolated line stripped"
Assert-True ($lineOnly.Content.Contains("% block line one")) "line-comments: 2-line run kept"
Assert-True ($lineOnly.Content.Contains("This is a multi-line comment block")) "line-comments: \begin{comment} kept"

# Inline comments
$inlineOnly = Invoke-Processor $fixture @{ Operations = @('inline-comments') }
Assert-True (-not $inlineOnly.Content.Contains("% inline comment kept by default")) "inline-comments: trailing comment stripped"
Assert-True ($inlineOnly.Content.Contains('\setlength{\parindent}{0pt}')) "inline-comments: code before trailing comment preserved"
Assert-True ($inlineOnly.Content.Contains("% block line one")) "inline-comments: standalone block kept"
Assert-True ($inlineOnly.Content.Contains("% isolated single line comment")) "inline-comments: standalone line kept"
Assert-True (-not $inlineOnly.Content.Contains("this is a comment after linebreak")) "inline-comments: \\% comment stripped"
Assert-True ($inlineOnly.Content.Contains("20\% today!")) "inline-comments: \% literal preserved"
Assert-True ($inlineOnly.Content.Contains('\\\% this is literal percent')) "inline-comments: \\\% literal preserved"

# ============================================================
# Section 4: Whitespace Suppression Preservation
# ============================================================
Enter-Section "4. Whitespace suppression preservation"

# Test inline comments with attached code: \foo{% comment
$wsSnippet = @'
\newcommand{\test}[1]{% this is a macro body comment
  \textbf{#1}% trailing comment
}
'@

# With PreserveWhitespaceSuppression = $true (default):
$wsStripped = Invoke-Processor $wsSnippet @{ Operations = @('inline-comments'); PreserveWhitespaceSuppression = $true }
Assert-True ($wsStripped.Content.Contains('\newcommand{\test}[1]{%')) "WS Suppression: % retained after code"
Assert-True (-not $wsStripped.Content.Contains("this is a macro body comment")) "WS Suppression: comment body stripped"
Assert-True ($wsStripped.Content.Contains('\textbf{#1}%')) "WS Suppression: inner % retained"

# With PreserveWhitespaceSuppression = $false (aggressive mode):
$wsAggressive = Invoke-Processor $wsSnippet @{ Operations = @('inline-comments'); PreserveWhitespaceSuppression = $false }
Assert-True ($wsAggressive.Content.Contains('\newcommand{\test}[1]{')) "Aggressive: % removed"
Assert-True (-not $wsAggressive.Content.Contains('\newcommand{\test}[1]{%')) "Aggressive: no % after brace"

# ============================================================
# Section 5: QuickExit Optimization
# ============================================================
Enter-Section "5. QuickExit optimization"

$noPercent = "Hello world without any comments`nJust pure text."
$quickRes = Invoke-Processor $noPercent
Assert-Equal $quickRes.Content $noPercent "QuickExit: text returned unchanged"
Assert-Equal $quickRes.Processing[-1].Implementation 'rs.tex.strip' "QuickExit: audit record attached"

# ============================================================
# Section 6: Real-World Specimen (LaTeXML latexml.sty)
# ============================================================
Enter-Section "6. Real-world specimen (LaTeXML latexml.sty)"

$realPath = 'd:\aipithicus\LaTeXAI\lib\LaTeXML\texmf\latexml.sty'
if (Test-Path -LiteralPath $realPath)
{
    $realContent = [System.IO.File]::ReadAllText($realPath)
    $realItem = [pscustomobject]@{ Content = $realContent; Path = $realPath }
    $realRes = Invoke-Processor $realItem
    $realOut = $realRes.Content

    Assert-True (-not $realOut.Contains("Style file for latexml documents")) "latexml.sty: header comment block stripped"
    Assert-True ($realOut.Contains('\newif\iflatexml\latexmlfalse')) "latexml.sty: \newif code preserved"
    Assert-True ($realOut.Contains('\def\UrlLeft##1\UrlRight')) "latexml.sty: ##1 parameter macro preserved"
    Assert-True ($realOut.Contains('\def\@URL[#1]{#1')) "latexml.sty: #1 parameter macro preserved"
    Assert-True ($realOut.Contains('\providecommand{\XML}{\textsc{xml}}%')) "latexml.sty: trailing whitespace % preserved"
    Assert-True ($realOut.Length -lt $realContent.Length) "latexml.sty: size reduced ($($realContent.Length) -> $($realOut.Length) bytes)"
}
else
{
    Write-Host "    SKIP  latexml.sty not found on disk" -ForegroundColor Yellow
}

# ============================================================
# Section 7: Harmonized Mutator Contract (6d)
# ============================================================
Enter-Section "7. Harmonized content-mutator contract (6d)"

# Invariant: input object must not be mutated
$origBag = [pscustomobject]@{ Content = "% c`n\relax"; Tag = 'immutable' }
$origContent = $origBag.Content
$mutatedBag = Invoke-ProcessorRaw $origBag
Assert-True ($origBag.Content -eq $origContent) "Contract: original bag Content not mutated in-place"
Assert-True ($mutatedBag.Content -eq "\relax") "Contract: returned bag Content mutated"
Assert-True ($origBag -ne $mutatedBag) "Contract: returned bag is a new reference"
Assert-Equal $mutatedBag.Tag 'immutable' "Contract: other properties preserved"

# ============================================================
# Summary
# ============================================================
Write-Host "`n============================================================" -ForegroundColor White
Write-Host " Results: $script:Passed passed, $script:Failed failed" -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
Write-Host "============================================================`n" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
