# file-read.ps1 — ISS-loadable processor body
# Contract: param($Item, $Config)  →  enriched $Item
#
# The chain's reader: consumes an ItemDescriptor (crawler-stamped identity —
# AbsolutePath, RelativePath, NodePath, SizeBytes, LastWriteUtc; see
# issues/v3/rs.core.assemble-design.md) and attaches Content + Encoding.
# Binary (NUL-byte) content _ChainHalts with ReadError='BinaryOrNulContent';
# read failures _ChainHalt with the exception message. Halted items are
# routed to Diagnostics by assemble (lean-payload doctrine).
#
# ISS-load-safe: no #Requires, top-level param contract (interior helpers
# permitted per colonel AST validation).
#
# Processor self-documentation (no runtime enforcement in this file):
#     - Item contract:  descriptor (Content; open-bag copy-on-enrich)
#     - Position class: reader (chain head — produces Content)
#     - Intended Colonel IssPreset floor: Core
#     - Required IssModules: none
param($Item, $Config)

# Copy-on-enrich: clone ALL input properties so identity fields — including
# ones added to the descriptor after this processor was written — survive the
# chain without mutation of the caller's reference object.
$result = [PSCustomObject]@{}
foreach ($p in $Item.PSObject.Properties)
{
    $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
}


try
{
    $bytes = [System.IO.File]::ReadAllBytes($result.AbsolutePath)

    # NUL byte / binary guard
    # null byte check on full file read may benefit from streaming read if large files are expected. however right now, there is maxfilesize bytes filter upstream
    # Note: High entropy on short files could be useful but also have false positives, introduce a new processor if desired
    if ($bytes -contains 0)
    {
        $result | Add-Member -NotePropertyName ReadError -NotePropertyValue 'BinaryOrNulContent'
        $result | Add-Member -NotePropertyName _ChainHalt -NotePropertyValue $true
        return $result
    }

    $enc = [System.Text.Encoding]::UTF8
    $content = $enc.GetString($bytes)

    $result | Add-Member -NotePropertyName Content -NotePropertyValue $content
    $result | Add-Member -NotePropertyName Encoding -NotePropertyValue 'UTF-8'
    return $result
}
catch
{
    $result | Add-Member -NotePropertyName ReadError -NotePropertyValue $_.Exception.Message
    $result | Add-Member -NotePropertyName _ChainHalt -NotePropertyValue $true
    return $result
}
