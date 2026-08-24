<#
.SYNOPSIS
    Standalone-invocation shim for the processor test suites.

.DESCRIPTION
    Processors call the shared library in processors/bag-helpers.ps1
    (Resolve-BagContent, Copy-Bag). Under colonel those functions are registered
    into every worker runspace by Compile-Plan -SharedHelperPath. These suites
    dot-invoke processors DIRECTLY, outside any ISS, so dot-sourcing this file
    first brings the helpers into scope:

        . (Join-Path $PSScriptRoot '_helpers.ps1')
#>

. (Join-Path $PSScriptRoot '..\bag-helpers.ps1')
