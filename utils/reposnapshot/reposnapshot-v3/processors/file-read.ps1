# See [file-read.md](docs/file-read.md) for docstring
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
