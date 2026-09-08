#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs.pm.strip.ps1.

.DESCRIPTION
    Tests the Perl processor directly (dot-invoked) to isolate behavior from dispatcher mechanics.
    Covers:
      1. Item unpacking — string / hashtable / pscustomobject
      2. FrontMatter + mask lens + default ops
      3. Selective ops — each kind in isolation
      4. POD documentation block variations
      5. Real-world specimen battery (LaTeXML Alignment.pm)
      6. CRLF normalization side effect
      7. Empty content and empty Operations
      8. IncludeMeta = $false
      9. Harmonized content-mutator contract (6d)
#>

$processorPath = Join-Path $PSScriptRoot '..\rs.pm.strip.ps1'

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
#!/usr/bin/env perl
# block line one
# block line two
package Foo;

use strict;
use warnings;
use List::Util qw(max sum # not a comment in qw);

=head1 NAME

Foo - sample perl module

=cut

my $url = "http://example.com#anchor";
my $sq = 'single # quote';
my @arr = (1, 2, 3);
my $len = $#arr; # inline comment kept by default
my $len2 = $#{$ref};

# isolated single line comment

sub bar {
    my ($self) = @_;
    my $rx = qr/foo#bar/;
    if ($url =~ /match#1/) {
        $url =~ s/foo#1/bar#2/g;
    }
    return $len;
}

my $here = <<'EOF';
# heredoc line one
# heredoc line two
EOF

1;

__END__

=pod

=head1 DESCRIPTION

Module documentation at end.

=cut
'@
#endregion

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' rs.pm.strip.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

try
{
    #region Test1_ItemUnpacking
    Enter-Section '1. Item unpacking'

    $rStr = Invoke-ProcessorRaw -Item $fixture
    $rHash = Invoke-Processor -Item @{ Content = $fixture; Id = 'h1'; Path = 'Foo.pm' }
    $rPsco = Invoke-Processor -Item ([pscustomobject]@{ Content = $fixture; Id = 'p1'; Path = 'Bar.pm' })

    Assert-True ($rStr -is [string]) 'String item: bare string in → bare string out'
    Assert-True ($rStr -notmatch 'block line one') 'String item: stripping applied to the returned string'
    Assert-True ($rHash -is [pscustomobject]) 'Hashtable item: cloned to pscustomobject'
    Assert-True ($rPsco -is [pscustomobject]) 'PSCustomObject item: returns pscustomobject'
    Assert-Equal $rPsco.Id 'p1' 'PSCustomObject item: Id propagated'
    Assert-Equal $rPsco.Path 'Bar.pm' 'PSCustomObject item: Path propagated'
    Assert-Equal $rPsco.Processing[0].Processor 'rs.pm.strip' 'Processing record names the processor'
    Assert-Equal $rPsco.Processing[0].Implementation 'rs.pm.strip' 'Implementation is rs.pm.strip'
    #endregion

    #region Test2_DefaultOps
    Enter-Section '2. FrontMatter + mask lens + default ops'

    $rDef = Invoke-Processor -Item $fixture
    Assert-True ($rDef.Content.StartsWith('#!/usr/bin/env perl')) 'Default: shebang on line 1 kept'
    Assert-True ($rDef.Content -notmatch 'block line one') 'Default: CommentBlock stripped'
    Assert-True ($rDef.Content -notmatch 'isolated single line comment') 'Default: LineComment stripped'
    Assert-True ($rDef.Content -notmatch 'Foo - sample perl module') 'Default: inline POD stripped'
    Assert-True ($rDef.Content -notmatch 'Module documentation at end') 'Default: __END__ POD stripped'
    Assert-True ($rDef.Content -match 'inline comment kept by default') 'Default: InlineComment kept'
    Assert-True ($rDef.Content.Contains('$#arr')) 'Mask: $#arr sigil preserved'
    Assert-True ($rDef.Content.Contains('$#{$ref}')) 'Mask: $#{$ref} sigil preserved'
    Assert-True ($rDef.Content.Contains('"http://example.com#anchor"')) 'Mask: # inside double quotes kept'
    Assert-True ($rDef.Content.Contains('''single # quote''')) 'Mask: # inside single quotes kept'
    Assert-True ($rDef.Content.Contains('# not a comment in qw')) 'Mask: # inside qw(...) kept'
    Assert-True ($rDef.Content.Contains('qr/foo#bar/')) 'Mask: # inside qr/.../ kept'
    Assert-True ($rDef.Content.Contains('/match#1/')) 'Mask: # inside /.../ kept'
    Assert-True ($rDef.Content.Contains('s/foo#1/bar#2/g')) 'Mask: # inside s/.../.../ kept'
    Assert-True ($rDef.Content.Contains('# heredoc line one')) 'Mask: # inside heredoc body kept'
    Assert-True ($rDef.Content -match 'package Foo;') 'Default: package statement preserved'
    Assert-True ($rDef.Content -match 'sub bar \{') 'Default: sub declaration preserved'
    Assert-True ($rDef.Content -match '1;') 'Default: 1; preserved'
    Assert-True ($rDef.Content -notmatch ([char]0x01)) 'Mask: no sentinel leaked'
    #endregion

    #region Test3_SelectiveOps
    Enter-Section '3. Selective ops'

    # block-comments in isolation
    $rB = Invoke-Processor -Item $fixture -Config @{ Operations = @('block-comments') }
    Assert-True ($rB.Content -notmatch 'Foo - sample perl module') 'block-comments: POD stripped'
    Assert-True ($rB.Content -match 'block line one') 'block-comments: CommentBlock kept'
    Assert-True ($rB.Content -match 'isolated single line comment') 'block-comments: LineComment kept'

    # doc-strings in isolation
    $rD = Invoke-Processor -Item $fixture -Config @{ Operations = @('doc-strings') }
    Assert-True ($rD.Content -notmatch 'Foo - sample perl module') 'doc-strings: POD stripped'
    Assert-True ($rD.Content -match 'block line one') 'doc-strings: CommentBlock kept'

    # comment-blocks in isolation
    $rCB = Invoke-Processor -Item $fixture -Config @{ Operations = @('comment-blocks') }
    Assert-True ($rCB.Content -notmatch 'block line one') 'comment-blocks: 2-line run stripped'
    Assert-True ($rCB.Content -match 'isolated single line comment') 'comment-blocks: isolated LineComment kept'
    Assert-True ($rCB.Content -match 'Foo - sample perl module') 'comment-blocks: POD kept'

    # line-comments in isolation
    $rL = Invoke-Processor -Item $fixture -Config @{ Operations = @('line-comments') }
    Assert-True ($rL.Content -notmatch 'isolated single line comment') 'line-comments: isolated line stripped'
    Assert-True ($rL.Content -match 'block line one') 'line-comments: 2-line run kept'
    Assert-True ($rL.Content -match 'Foo - sample perl module') 'line-comments: POD kept'

    # inline-comments in isolation
    $rI = Invoke-Processor -Item $fixture -Config @{ Operations = @('inline-comments') }
    Assert-True ($rI.Content -notmatch 'inline comment kept by default') 'inline-comments: trailing comment stripped'
    Assert-True ($rI.Content -match 'my \$len = \$#arr;') 'inline-comments: code before trailing comment preserved'
    Assert-True ($rI.Content -match 'block line one') 'inline-comments: standalone block kept'
    Assert-True ($rI.Content -match 'isolated single line comment') 'inline-comments: standalone line kept'
    Assert-True ($rI.Content -match 'Foo - sample perl module') 'inline-comments: POD kept'
    #endregion

    #region Test4_PodVariations
    Enter-Section '4. POD variations'

    # Unclosed POD extends to EOF
    $unclosedPod = "package Bar;`n1;`n__END__`n=head1 UNCLOSED`nThis doc has no cut."
    $rUnclosed = Invoke-Processor -Item $unclosedPod
    Assert-True ($rUnclosed.Content -notmatch 'UNCLOSED|This doc has no cut') 'unclosed POD stripped to EOF'
    Assert-True ($rUnclosed.Content -match 'package Bar;') 'unclosed POD: preceding code kept'

    # Multiple POD blocks separated by code
    $multiPod = "package Baz;`n=head1 FIRST`nDoc 1`n=cut`nsub a {}`n=head1 SECOND`nDoc 2`n=cut`nsub b {}`n"
    $rMulti = Invoke-Processor -Item $multiPod
    Assert-True ($rMulti.Content -notmatch 'FIRST|Doc 1|SECOND|Doc 2') 'multi-POD: all POD blocks stripped'
    Assert-True ($rMulti.Content -match 'sub a \{\}') 'multi-POD: intermediate sub a kept'
    Assert-True ($rMulti.Content -match 'sub b \{\}') 'multi-POD: trailing sub b kept'

    # POD inside quote-like literal (not real POD)
    $fakePod = "my `$str = q{`n=head1 NOT POD`nSome text`n=cut`n};`n# real comment`n"
    $rFake = Invoke-Processor -Item $fakePod
    Assert-True ($rFake.Content -match '=head1 NOT POD') 'fake POD inside string preserved'
    Assert-True ($rFake.Content -notmatch 'real comment') 'real comment outside string stripped'

    # Heredoc edge cases: << inside q{} and bitshift << must not be parsed as heredocs
    $fakeHeredoc = "Parse::RecDescent::_trace(q{<<Didn't match rule>>});`n# real comment`nmy `$shift = `$a << 2;`n"
    $rFakeHd = Invoke-Processor -Item $fakeHeredoc
    Assert-True ($rFakeHd.Content -match '<<Didn''t match rule>>') 'q{<<...>>} in trace literal preserved'
    Assert-True ($rFakeHd.Content -match 'my \$shift = \$a << 2;') 'bitshift << preserved'
    Assert-True ($rFakeHd.Content -notmatch 'real comment') 'comment following non-heredocs stripped'
    #endregion

    #region Test5_RealSpecimen
    Enter-Section '5. Complex module specimen battery'
    $complexSpecimen = @'
# /=====================================================================\ #
# |  Sample::Core::Engine                                               | #
# | Support for tabular/array environments                              | #
# |=====================================================================| #
package Sample::Core::Engine;
use strict;
use warnings;
use List::Util qw(max sum);
our @EXPORT = (qw(&RunEngine &StopEngine));

# Create a new Engine instance.
sub new {
    my ($class, %data) = @_;
    my $self = bless {%data}, $class;
    $$self{level} = 0;
    return $self;
}

sub run {
    my ($self, @items) = @_;
    my $len = $#items; # trailing comment kept
    my $qr = qr/pattern#test/;
    if ($qr) {
        $self->{last} = $#items;
    }
    return $len;
}

1;

__END__

=pod

=head1 NAME

C<Sample::Core::Engine> - representation of core engine

=head1 DESCRIPTION

This module defines engine structures.

=cut
'@
    $out = Invoke-Processor -Item $complexSpecimen
    Assert-True ($out.Content -notmatch ([char]0x01)) 'specimen: no sentinel leaked'
    Assert-True ($out.Content -match 'package Sample::Core::Engine;') 'specimen: package declaration intact'
    Assert-True ($out.Content -match 'sub new \{') 'specimen: sub new intact'
    Assert-True ($out.Content -match 'sub run \{') 'specimen: sub run intact'
    Assert-True ($out.Content -notmatch 'Support for tabular/array environments') 'specimen: header comment box stripped'
    Assert-True ($out.Content -notmatch 'representation of core engine') 'specimen: trailing POD stripped'
    Assert-True ($out.Content.Length -lt $complexSpecimen.Length) "specimen: stripped size ($($out.Content.Length)) < source size ($($complexSpecimen.Length))"
    #endregion

    #region Test6_CrlfNormalization
    Enter-Section '6. CRLF normalization (documented side effect)'

    $rCrlf = Invoke-Processor -Item "my `$a = 1;`r`nmy `$b = 2;`r`n" -Config @{ Operations = @() }
    Assert-True ($rCrlf.Content -notmatch "`r") 'CRLF normalized to LF even with no ops'
    Assert-Equal $rCrlf.Content "my `$a = 1;`nmy `$b = 2;`n" 'content otherwise unchanged'
    #endregion

    #region Test7_EmptyContent
    Enter-Section '7. Empty content and empty Operations'

    $rEmpty = Invoke-Processor -Item ''
    Assert-True ($rEmpty -is [pscustomobject]) 'empty content: returns bag'
    Assert-Equal $rEmpty.Content '' 'empty content: Content is empty'

    $rEmptyStr = Invoke-ProcessorRaw -Item ''
    Assert-True ($rEmptyStr -is [string] -and $rEmptyStr -eq '') 'empty string in → empty string out'

    $rNoop = Invoke-Processor -Item $fixture -Config @{ Operations = @() }
    Assert-True ($rNoop.Content -match 'block line one') 'empty ops: CommentBlock preserved'
    Assert-True ($rNoop.Content -match 'Foo - sample perl module') 'empty ops: POD preserved'
    #endregion

    #region Test8_IncludeMeta
    Enter-Section '8. IncludeMeta = $false'

    $rBare = Invoke-ProcessorRaw -Item $fixture -Config @{ IncludeMeta = $false }
    Assert-True ($rBare -is [string]) 'IncludeMeta=false: bare string in still returns bare string'
    Assert-True ($rBare -notmatch 'block line one') 'IncludeMeta=false: stripping still applied'

    $rBagNoMeta = Invoke-Processor -Item ([pscustomobject]@{ RelativePath = 'a.pm'; Content = $fixture }) -Config @{ IncludeMeta = $false }
    Assert-True ($rBagNoMeta -is [pscustomobject]) 'IncludeMeta=false: bag stays a bag'
    Assert-Equal $rBagNoMeta.RelativePath 'a.pm' 'IncludeMeta=false: identity survives'
    Assert-True ($null -eq $rBagNoMeta.PSObject.Properties['Processing']) 'IncludeMeta=false: no Processing record'
    #endregion

    #region Test9_HarmonizedContract
    Enter-Section '9. Harmonized content-mutator contract (6d)'

    $descriptor = [pscustomobject]@{
        AbsolutePath = 'D:\repo\lib\Foo.pm'
        RelativePath = 'lib/Foo.pm'
        NodePath     = 'lib/'
        SizeBytes    = 500
        LastWriteUtc = [datetime]'2026-08-01T12:00:00Z'
        Content      = $fixture
        Encoding     = 'UTF-8'
    }
    $rDesc = Invoke-Processor -Item $descriptor

    Assert-Equal $rDesc.AbsolutePath 'D:\repo\lib\Foo.pm' 'descriptor: AbsolutePath survives'
    Assert-Equal $rDesc.RelativePath 'lib/Foo.pm' 'descriptor: RelativePath survives'
    Assert-Equal $rDesc.NodePath 'lib/' 'descriptor: NodePath survives'
    Assert-Equal $rDesc.SizeBytes 500 'descriptor: SizeBytes survives'
    Assert-Equal $rDesc.LastWriteUtc ([datetime]'2026-08-01T12:00:00Z') 'descriptor: LastWriteUtc survives'
    Assert-Equal $rDesc.Encoding 'UTF-8' 'descriptor: Encoding survives'
    Assert-True ($rDesc.Content -notmatch 'block line one') 'descriptor: Content mutated'
    Assert-True ($null -eq $rDesc.PSObject.Properties['Text']) 'descriptor: no Text key invented'
    Assert-Equal $descriptor.Content $fixture 'copy-on-mutate: input bag not mutated'

    # tp-era Text key: read and written back under its own name
    $tpBag = [pscustomobject]@{ Id = 'p1'; Path = 'y.pm'; Text = $fixture }
    $rTp = Invoke-Processor -Item $tpBag
    Assert-True ($rTp.Text -notmatch 'block line one') 'Text-keyed bag: Text mutated in place'
    Assert-True ($null -eq $rTp.PSObject.Properties['Content']) 'Text-keyed bag: no Content key invented'
    Assert-Equal $rTp.Id 'p1' 'Text-keyed bag: Id passed through'

    # No-content bag → returned untouched
    $halted = [pscustomobject]@{ RelativePath = 'bin/x.dll'; SizeBytes = 9; ReadError = 'BinaryOrNulContent' }
    $rHalt = Invoke-Processor -Item $halted
    Assert-True ($null -eq $rHalt.PSObject.Properties['Content']) 'no-content bag: no phantom Content fabricated'
    Assert-True ($null -eq $rHalt.PSObject.Properties['Processing']) 'no-content bag: no Processing record attached'
    Assert-Equal $rHalt.ReadError 'BinaryOrNulContent' 'no-content bag: returned intact'

    # Chained mutators
    $fmt = Join-Path $PSScriptRoot '..\rs.whitespace.ps1'
    $step1 = & $fmt $descriptor @{ Operations = @('lf') }
    $step2 = Invoke-Processor -Item $step1
    Assert-Equal $step2.Processing.Count 2 'chain: two records accumulated'
    Assert-Equal $step2.Processing[0].Processor 'rs.whitespace' 'chain: order[0] = rs.whitespace'
    Assert-Equal $step2.Processing[1].Processor 'rs.pm.strip' 'chain: order[1] = rs.pm.strip'
    Assert-Equal $step2.RelativePath 'lib/Foo.pm' 'chain: identity survives cross-processor chain'
    Assert-True ($step2.Content -notmatch 'block line one') 'chain: both mutations applied'
    #endregion
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Passed: $($script:Passed)   Failed: $($script:Failed)" -ForegroundColor $color
Write-Host '============================================================' -ForegroundColor Yellow
