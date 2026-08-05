# _helpers.ps1 — standalone-invocation shim for the processor suites
# =============================================================================
# Processors call the shared library in processors/bag-helpers.ps1
# (Resolve-BagContent, Copy-Bag). Under colonel those functions are registered
# into every worker runspace by Compile-Plan -SharedHelperPath. These suites
# dot-invoke processors DIRECTLY, outside any ISS, so nothing would define them.
#
# Dot-source this file first and the helpers exist in the caller's scope:
#
#     . (Join-Path $PSScriptRoot '_helpers.ps1')
#
# This is the wrapper the shared-helper consolidation traded standalone
# invocation for — deliberately accepted: collapsing six copies of the clone
# contract into one beats a convenience that is rarely used, and a one-line
# shim restores it for the suites that do use it.
# =============================================================================

. (Join-Path $PSScriptRoot '..\bag-helpers.ps1')
