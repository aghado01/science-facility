# file-read.ps1 — ISS-loadable processor body
# Contract: param($Item, $Config)  →  enriched $Item
#
# The chain's reader: consumes an ItemDescriptor (crawler-stamped identity —
# AbsolutePath, RelativePath, NodePath, SizeBytes, LastWriteUtc; see
# issues/reposnapshot/design/rs.core.assemble-design.md) and attaches Content + Encoding.
# Binary (NUL-byte) content _ChainHalts with ReadError='BinaryOrNulContent';
# read failures _ChainHalt with the exception message. Halted items are
# routed to Diagnostics by assemble (lean-payload doctrine).
#
# ENCODING — this stamp is the SOURCE encoding (what the on-disk bytes were
# decoded as), an ingest-stage fact. It is NOT the payload's emission
# encoding, which is a serializer declaration; the two are separate entries
# in the manifest ledger (#17). Both are owed to a reader: mojibake in the
# artifact is unattributable without knowing which end introduced it.
#
# HONEST STATE: the stamp is a CONSTANT, not a detection. This reader decodes
# every file as UTF-8 unconditionally — no BOM sniff, no UTF-16 branch — so
# 'UTF-8' is an assertion about what we did, not a measurement of what the
# file was. A UTF-16 source survives the NUL guard only if it has no NUL
# bytes (rare for UTF-16, which is why the guard catches most of them by
# accident rather than by design) and would otherwise pass through as
# mojibake wearing a UTF-8 label. Making the stamp truthful means either
# detecting for real or renaming the field to say it is a decode policy.
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

# Copy-on-enrich via the shared Copy-Bag helper (processors/bag-helpers.ps1,
# registered into the ISS by Compile-Plan -SharedHelperPath): clones ALL input
# properties so identity fields — including ones added to the descriptor after
# this processor was written — survive the chain without mutating the caller's
# reference object. [ordered] on -Add keeps emitted property order deterministic.
try
{
    $bytes = [System.IO.File]::ReadAllBytes($Item.AbsolutePath)

    # NUL byte / binary guard
    # null byte check on full file read may benefit from streaming read if large files are expected. however right now, there is maxfilesize bytes filter upstream
    # Note: High entropy on short files could be useful but also have false positives, introduce a new processor if desired
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
