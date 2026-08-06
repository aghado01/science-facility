#!/usr/bin/env pwsh
# Thin wrapper so `mdnav ...` works without naming the runtime.
& node (Join-Path $PSScriptRoot 'mdnav.mjs') @args
exit $LASTEXITCODE
