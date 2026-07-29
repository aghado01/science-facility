# file-read.ps1 — ISS-loadable processor body
# Contract: param($Item, $Config)  →  enriched $Item
# $Item is an ItemDescriptor (crawler-stamped identity: AbsolutePath,
# RelativePath, NodePath, SizeBytes, LastWriteUtc — rs.core.assemble-design.md).
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
