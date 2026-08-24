<#
.SYNOPSIS
    File-reading processor for reposnapshot pipelines.

.DESCRIPTION
    The chain's reader: consumes an ItemDescriptor (crawler-stamped identity —
    AbsolutePath, RelativePath, NodePath, SizeBytes, LastWriteUtc) and attaches
    Content + Encoding. Binary (NUL-byte) content _ChainHalts with
    ReadError='BinaryOrNulContent'; read failures _ChainHalt with the exception
    message. Halted items are routed to Diagnostics by assemble.

    ENCODING: Source encoding stamp (decoded as), an ingest-stage fact. Not the
    payload's emission encoding.

    HONEST STATE: Stamp is a constant assertion ('UTF-8' unconditional decode).

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  descriptor (Content; open-bag copy-on-enrich)
      - Position class: reader (chain head — produces Content)
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.PARAMETER Item
    ItemDescriptor object carrying AbsolutePath and identity fields.
.PARAMETER Config
    Hashtable with per-step configuration (unused).
#>
param($Item, $Config)

#region FileRead
# Copy-on-enrich via shared Copy-Bag: clones all input properties so identity
# fields survive the chain without mutating caller's reference.
try
{
    $bytes = [System.IO.File]::ReadAllBytes($Item.AbsolutePath)

    # NUL byte / binary guard
    if ($bytes -contains 0)
    {
        return Copy-Bag -Item $Item -Add ([ordered]@{ ReadError = 'BinaryOrNulContent'; _ChainHalt = $true })
    }

    $enc = [System.Text.Encoding]::UTF8
    $content = $enc.GetString($bytes)

    return Copy-Bag -Item $Item -Add ([ordered]@{ Content = $content; Encoding = 'UTF-8' })
}
catch
{
    return Copy-Bag -Item $Item -Add ([ordered]@{ ReadError = $_.Exception.Message; _ChainHalt = $true })
}
#endregion
