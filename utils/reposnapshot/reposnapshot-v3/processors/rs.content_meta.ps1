<#
.LINK
    docs/rs.content_meta.md
#>
param($Item, $Config)

#region NoContentGuard
# Pass through unenriched if no usable Content string is present.
if ($null -eq $Item.PSObject.Properties['Content'] -or $Item.Content -isnot [string])
{
    return $Item
}

$content = [string]$Item.Content
#endregion

#region Config
if ($null -eq $Config) { $Config = @{} }
if ($Config.Count -eq 0 -or -not $Config.ContainsKey('Fields'))
{
    $Config = Resolve-ProcessorConfig -ProcessorName 'rs.content_meta' -CallerConfig $Config
}
$knownFields = @(
    'CharCount', 'WordCount', 'PunctuationCount', 'UniqueChars',
    'Entropy', 'CompressionRatio', 'WhitespaceRatio', 'LineStats'
)
$fields = @($Config['Fields'])
foreach ($f in $fields)
{
    if ($f -notin $knownFields)
    {
        throw "rs.content_meta: unknown Fields entry '$f'. Known: $($knownFields -join ', ')."
    }
}
# Empty Fields: processor is in the chain but computes nothing — do not attach
# ContentMeta, so downstream occupancy omits the wire block.
if ($fields.Count -eq 0) { return $Item }

$want = @{}
foreach ($f in $fields) { $want[$f] = $true }
$needScan = $want.ContainsKey('WordCount') -or $want.ContainsKey('PunctuationCount') -or
    $want.ContainsKey('UniqueChars') -or $want.ContainsKey('Entropy') -or
    $want.ContainsKey('WhitespaceRatio') -or $want.ContainsKey('LineStats')
$needGzip = $want.ContainsKey('CompressionRatio')
#endregion

#region ScanType
# One native pass replaces: -split '\s+', \p{P} Matches, ToCharArray entropy,
# \s Matches, -split "`n" line stats. Compiled once per AppDomain (type-exists
# guard); never per file. Roslyn APIs, not the Add-Type cmdlet — Bare ISS has
# no cmdlets; the compiler types are already in the process.
if ($needScan -and -not ('Rs.ContentMeta.Scan' -as [type]))
{
    $scanSrc = @'
using System;
using System.Collections.Generic;

namespace Rs.ContentMeta {
    public sealed class Stats {
        public int WordCount, PunctCount, WsCount, UniqueChars, LineMedian, LineMax;
        public double Entropy, LineMean, LineStdDev;
    }
    public static class Scan {
        public static Stats Run(string s) {
            int n = s.Length;
            var st = new Stats();
            int[] ascii = new int[128];
            Dictionary<char, int> rest = null;
            var lens = new List<int>(64);
            int punct = 0, ws = 0, wordCount = 1, lineLen = 0;
            bool inWs = false;
            for (int i = 0; i < n; i++) {
                char c = s[i];
                if (c < 128) ascii[c]++;
                else {
                    if (rest == null) rest = new Dictionary<char, int>();
                    int k;
                    if (rest.TryGetValue(c, out k)) rest[c] = k + 1;
                    else rest[c] = 1;
                }
                if (char.IsPunctuation(c)) punct++;
                if (char.IsWhiteSpace(c)) {
                    ws++;
                    if (!inWs) { inWs = true; wordCount++; }
                } else inWs = false;
                if (c == '\n') { lens.Add(lineLen); lineLen = 0; }
                else lineLen++;
            }
            lens.Add(lineLen);
            st.WordCount = wordCount;
            st.PunctCount = punct;
            st.WsCount = ws;

            int unique = 0;
            double entropy = 0.0;
            double inv = 1.0 / n;
            for (int i = 0; i < 128; i++) {
                int cnt = ascii[i];
                if (cnt == 0) continue;
                unique++;
                double p = cnt * inv;
                entropy += -p * Math.Log(p, 2.0);
            }
            if (rest != null) {
                foreach (var kv in rest) {
                    unique++;
                    double p = kv.Value * inv;
                    entropy += -p * Math.Log(p, 2.0);
                }
            }
            st.UniqueChars = unique;
            st.Entropy = Math.Round(entropy, 4);

            int lineCount = lens.Count;
            double sum = 0;
            for (int i = 0; i < lineCount; i++) sum += lens[i];
            double mean = sum / lineCount;
            int[] sorted = lens.ToArray();
            Array.Sort(sorted);
            double varSum = 0.0;
            for (int i = 0; i < lineCount; i++) {
                double d = lens[i] - mean;
                varSum += d * d;
            }
            st.LineMean = Math.Round(mean, 2);
            st.LineMedian = sorted[sorted.Length / 2];
            st.LineStdDev = Math.Round(Math.Sqrt(varSum / lineCount), 2);
            st.LineMax = sorted[sorted.Length - 1];
            return st;
        }
    }
}
'@
    try
    {
        $tree = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($scanSrc)
        $refs = [System.Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
        foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies())
        {
            if ($a.IsDynamic) { continue }
            $loc = $a.Location
            if ([string]::IsNullOrEmpty($loc) -or -not [IO.File]::Exists($loc)) { continue }
            [void]$refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($loc))
        }
        $opts = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new(
            [Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
        $comp = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create(
            'Rs.ContentMeta', [Microsoft.CodeAnalysis.SyntaxTree[]]@($tree), $refs, $opts)
        $pe = [System.IO.MemoryStream]::new()
        try
        {
            $emit = $comp.Emit($pe)
            if (-not $emit.Success)
            {
                $fail = foreach ($d in $emit.Diagnostics)
                {
                    if ($d.Severity -eq [Microsoft.CodeAnalysis.DiagnosticSeverity]::Error) { $d.ToString() }
                }
                throw ($fail -join [Environment]::NewLine)
            }
            [void][Reflection.Assembly]::Load($pe.ToArray())
        }
        finally { $pe.Dispose() }
    }
    catch
    {
        if (-not ('Rs.ContentMeta.Scan' -as [type])) { throw }
    }
}
#endregion

#region Metrics
$charCount = if ($content) { $content.Length } else { 0 }
$spanBytes = 0
$scan = $null
$bytes = $null

if ($charCount -gt 0)
{
    if ($needScan) { $scan = [Rs.ContentMeta.Scan]::Run($content) }
    # SpanBytes is always on the element (not a Fields toggle, not a wire
    # sub-field). One UTF-8 encoding serves it and the gzip proxy.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    $spanBytes = $bytes.Length
}

$meta = [ordered]@{ SpanBytes = $spanBytes }
if ($want.ContainsKey('CharCount')) { $meta['CharCount'] = $charCount }
if ($want.ContainsKey('WordCount'))
{
    $meta['WordCount'] = if ($null -ne $scan) { $scan.WordCount } else { 0 }
}
if ($want.ContainsKey('PunctuationCount'))
{
    $meta['PunctuationCount'] = if ($null -ne $scan) { $scan.PunctCount } else { 0 }
}
if ($want.ContainsKey('UniqueChars'))
{
    $meta['UniqueChars'] = if ($null -ne $scan) { $scan.UniqueChars } else { 0 }
}
if ($want.ContainsKey('Entropy'))
{
    $meta['Entropy'] = if ($null -ne $scan) { $scan.Entropy } else { 0.0 }
}
if ($want.ContainsKey('WhitespaceRatio'))
{
    $meta['WhitespaceRatio'] = if ($null -ne $scan -and $charCount -gt 0)
    {
        [Math]::Round($scan.WsCount / $charCount, 4)
    }
    else { 0.0 }
}
if ($want.ContainsKey('LineStats'))
{
    $meta['LineStats'] = if ($null -ne $scan)
    {
        [PSCustomObject]@{
            Mean   = $scan.LineMean
            Median = $scan.LineMedian
            StdDev = $scan.LineStdDev
            Max    = $scan.LineMax
        }
    }
    else { [PSCustomObject]@{ Mean = 0; Median = 0; StdDev = 0; Max = 0 } }
}
if ($needGzip)
{
    $compressionRatio = 1.0
    if ($null -ne $bytes -and $charCount -gt 100)
    {
        try
        {
            $ms = [System.IO.MemoryStream]::new()
            $gz = [System.IO.Compression.GZipStream]::new(
                $ms, [System.IO.Compression.CompressionLevel]::Fastest, $true)
            $gz.Write($bytes, 0, $bytes.Length)
            $gz.Dispose()
            $compressionRatio = [Math]::Round($ms.Length / $bytes.Length, 2)
            $ms.Dispose()
        }
        catch { }
    }
    $meta['CompressionRatio'] = $compressionRatio
}
#endregion

#region Emit
# Copy-on-enrich via shared Copy-Bag helper: clone all input properties, then attach.
return Copy-Bag -Item $Item -Add ([ordered]@{
        ContentMeta = [PSCustomObject]$meta
    })
#endregion
