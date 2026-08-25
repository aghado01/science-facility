# file-read.ps1

```powershell
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
```
