#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit + regression tests for rs.core.numerics.psm1.

.DESCRIPTION
    Coverage:
      1. Trap regressions — masked FNV, sign-bit Hamming, >64-bit signatures,
         Levenshtein on non-empty strings, empty-set Jaccard.
      2. Pinned lineage vectors — outputs must match verified G3 sources bit-for-bit.
      3. Semantics — SHA256 vectors, SimHash discrimination, Jaccard, Levenshtein, cosine.
      4. Sharding contract — call shapes rs.core.sharding uses.
#>

$modulePath = Join-Path $PSScriptRoot '..\..\rs.core.numerics.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

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
        Write-Host "  ok  $Label" -ForegroundColor Green
    }
    else
    {
        $script:Failed++
        Write-Host "  FAIL $Label $Detail" -ForegroundColor Red
    }
}

function Assert-Equal ($Expected, $Actual, [string]$Label)
{
    Assert-True ($Expected -eq $Actual) $Label "(expected: $Expected, got: $Actual)"
}

function Assert-Throws ([scriptblock]$Block, [string]$Label)
{
    try { & $Block | Out-Null; Assert-True $false $Label '(no exception thrown)' }
    catch { Assert-True $true $Label }
}
#endregion

#region Test1_TrapRegressions
Enter-Section 'Trap regressions (G1 must stay dead)'

# Law 1: masked FNV — G1 threw "-4.124E+30 to Int64" on any input >= 2 bytes.
$sim = Get-SimHash -Text ('lorem ipsum dolor sit amet consectetur ' * 100)
Assert-True ($sim -match '^[0-9a-f]{16}$') 'SimHash on large input (masked FNV, no overflow throw)'

# Law 2: sign-bit Hamming — G1 infinite-looped when bit 63 differed. 3 s guard.
$ps = [powershell]::Create()
[void]$ps.AddScript("Import-Module '$modulePath'; Get-HammingDistance -Sig1 'ffffffffffffffff' -Sig2 '0000000000000000'")
$handle = $ps.BeginInvoke()
if ($handle.AsyncWaitHandle.WaitOne(3000))
{
    $result = @($ps.EndInvoke($handle))[0]
    Assert-Equal 64 $result 'Hamming sign-bit case terminates and counts all 64 bits'
}
else
{
    $ps.Stop()
    Assert-True $false 'Hamming sign-bit case terminates and counts all 64 bits' '(HANG: 3s timeout)'
}
$ps.Dispose()

# >64-bit signatures — G1 threw on ToInt64. Chunked processing must handle.
Assert-Equal 128 (Get-HammingDistance -Sig1 ('ff' * 16) -Sig2 ('00' * 16)) 'Hamming 128-bit signatures'

# Law 3: Levenshtein — G1 threw op_Subtraction (2D comma-index trap) always.
Assert-Equal 3 (Get-LevenshteinDistance -String1 'kitten' -String2 'sitting') 'Levenshtein kitten/sitting = 3'

# Binding: empty sets — G1 rejected @() at the parameter binder.
Assert-Equal 1.0 (Get-JaccardSimilarity -Set1 @() -Set2 @()) 'Jaccard empty sets bind; J(0,0) = 1.0'
#endregion

#region Test2_PinnedVectors
Enter-Section 'Pinned lineage vectors (must match G3 sources bit-for-bit)'

Assert-Equal 'cef7991c1475e5ce' (Get-SimHash -Text 'the quick brown fox jumps over the lazy dog again and again') `
    'SimHash pinned vector (hashlib-new lineage)'

$minSig = Get-MinHashSignature -Content 'abcdefghijklmnop' -NumHashes 4
Assert-Equal '80919504,280315590,57514889,446414494' ($minSig -join ',') `
    'MinHash pinned vector (hashlib-new lineage)'

Assert-Equal '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824' `
    (Get-ContentHash -Content 'hello') 'SHA256 known vector (hello)'

Assert-Equal 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' `
    (Get-ContentHash -Content '') 'SHA256 empty-input digest'
#endregion

#region Test3_IdentitySemantics
Enter-Section 'Identity semantics'

Assert-Equal (Get-ContentHash -Content 'src/a.ts') (Get-PathHash -Path 'src/a.ts') `
    'Get-PathHash == Get-ContentHash for the same string'

$tmpFile = Join-Path ([IO.Path]::GetTempPath()) "rs-numerics-test-$PID.txt"
[IO.File]::WriteAllText($tmpFile, 'file content check', [Text.UTF8Encoding]::new($false))
try
{
    Assert-Equal (Get-ContentHash -Content 'file content check') (Get-ContentHash -FilePath $tmpFile) `
        'File hash matches content hash of identical text'

    $fs = [IO.File]::OpenRead($tmpFile)
    try
    {
        Assert-Equal (Get-ContentHash -Content 'file content check') (Get-StreamHash -Stream $fs) `
            'Stream hash matches content hash'
    }
    finally { $fs.Dispose() }
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}
finally { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }

Assert-Throws { Get-ContentHash -FilePath (Join-Path ([IO.Path]::GetTempPath()) 'rs-numerics-does-not-exist.bin') } `
    'Missing file throws'
#endregion

#region Test4_SimHashSemantics
Enter-Section 'SimHash semantics'

$textA = 'the quick brown fox jumps over the lazy dog and runs away fast'
$textB = 'the quick brown fox jumps over the lazy dog and runs away quickly'
$textC = 'completely unrelated content about database indexing strategies here'

Assert-Equal (Get-SimHash -Text $textA) (Get-SimHash -Text $textA) 'Deterministic: same text, same hash'

$dSimilar = Get-HammingDistance -Sig1 (Get-SimHash -Text $textA) -Sig2 (Get-SimHash -Text $textB)
$dDifferent = Get-HammingDistance -Sig1 (Get-SimHash -Text $textA) -Sig2 (Get-SimHash -Text $textC)
Assert-True ($dSimilar -lt $dDifferent) 'Discrimination: near-identical closer than unrelated' "(similar=$dSimilar different=$dDifferent)"
Assert-True ($dSimilar -le 16) 'Near-identical texts within 16 bits' "(got $dSimilar)"

Assert-Equal ('0' * 16) (Get-SimHash -Text "   `n  ") 'Whitespace-only text yields zero hash'

$stats = Get-DocStats -Documents @($textA, $textB, $textC)
Assert-Equal 3 $stats.DocumentCount 'Get-DocStats counts documents'
Assert-True ($stats.AvgDocLength -gt 0) 'Get-DocStats average length positive'
$weighted = Get-SimHash -Text $textA -IdfMap $stats.IdfMap -AvgDocLength $stats.AvgDocLength
Assert-True ($weighted -match '^[0-9a-f]{16}$') 'IDF-weighted SimHash produces a valid hash'
#endregion

#region Test5_MinHashSemantics
Enter-Section 'MinHash semantics'

$sigX = Get-MinHashSignature -Content ('shared prefix content block ' * 20 + 'unique tail one')
$sigY = Get-MinHashSignature -Content ('shared prefix content block ' * 20 + 'unique tail two')
$sigZ = Get-MinHashSignature -Content 'entirely different text with no overlap whatsoever in shingles'

Assert-Equal 1.0 (Get-JaccardEstimate -Signature1 $sigX -Signature2 $sigX) 'Self-estimate = 1.0'
$estNear = Get-JaccardEstimate -Signature1 $sigX -Signature2 $sigY
$estFar = Get-JaccardEstimate -Signature1 $sigX -Signature2 $sigZ
Assert-True ($estNear -gt $estFar) 'Overlapping content estimates higher than disjoint' "(near=$estNear far=$estFar)"

$zeroSig = Get-MinHashSignature -Content 'ab' -ShingleSize 3
Assert-True (@($zeroSig | Where-Object { $_ -ne 0 }).Count -eq 0) 'Content shorter than shingle yields zero signature'
Assert-Equal 128 $zeroSig.Count 'Default signature length 128'

Assert-Throws { Get-JaccardEstimate -Signature1 $sigX -Signature2 (Get-MinHashSignature -Content 'abcd' -NumHashes 4) } `
    'Mismatched signature lengths throw'
#endregion

#region Test6_MeasuresSemantics
Enter-Section 'Measures semantics'

Assert-Equal 4 (Get-HammingDistance -Sig1 '000000000000000f' -Sig2 '0000000000000000') 'Hamming low-bits = 4'
Assert-Equal 0 (Get-HammingDistance -Sig1 'abc123' -Sig2 'abc123') 'Hamming identical = 0'
Assert-Throws { Get-HammingDistance -Sig1 'ff' -Sig2 'ffff' } 'Hamming unequal lengths throw'
Assert-Equal 0.9375 (Get-HammingSimilarity -Sig1 '000000000000000f' -Sig2 '0000000000000000') `
    'Hamming similarity derives width from signature (1 - 4/64)'

Assert-Equal 0.5 (Get-JaccardSimilarity -Set1 @('a', 'b', 'c') -Set2 @('b', 'c', 'd')) 'Jaccard abc/bcd = 0.5'
Assert-Equal 1.0 (Get-JaccardSimilarity -Set1 @('a') -Set2 @('a')) 'Jaccard identical singletons = 1.0'
Assert-Equal 0.5 (Get-JaccardDistance -Set1 @('a', 'b', 'c') -Set2 @('b', 'c', 'd')) 'Jaccard distance = 1 - similarity'

Assert-Equal 3 (Get-LevenshteinDistance -String1 'ABC' -String2 'abc') 'Levenshtein case-sensitive by default'
Assert-Equal 0 (Get-LevenshteinDistance -String1 'ABC' -String2 'abc' -CaseInsensitive) 'Levenshtein -CaseInsensitive'
Assert-Equal 1 (Get-LevenshteinDistance -String1 '' -String2 'x') 'Levenshtein empty vs one char'
Assert-Equal 1.0 (Get-LevenshteinSimilarity -String1 '' -String2 '') 'Levenshtein similarity of two empties = 1.0'

Assert-Equal 1 (Get-CosineSimilarity -Vector1 @{a = 3; b = 4 } -Vector2 @{a = 6; b = 8 }) 'Cosine parallel = 1'
Assert-Equal 0 (Get-CosineSimilarity -Vector1 @{x = 1 } -Vector2 @{y = 1 }) 'Cosine orthogonal = 0'
Assert-Equal 0 (Get-CosineSimilarity -Vector1 @{ } -Vector2 @{x = 1 }) 'Cosine zero-magnitude = 0'
#endregion

#region Test7_ShardingContract
Enter-Section 'Sharding contract (rs.core.sharding call shapes)'

$positional = Get-PathHash 'src/nested/file.ts'
Assert-True ($positional -match '^[0-9a-f]{64}$') 'Get-PathHash positional (sharding:298)'
Assert-True ((Get-ContentHash -Content 'x') -match '^[0-9a-f]{64}$') 'Get-ContentHash -Content (sharding:648)'
Assert-True ((Get-SimHash -Text 'some file content here') -match '^[0-9a-f]{16}$') 'Get-SimHash -Text (sharding:649)'
#endregion

Write-Host "`n═══ rs-numerics: $script:Passed passed, $script:Failed failed ═══" `
    -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')

if ($script:Failed -gt 0) { exit 1 }
