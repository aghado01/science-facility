'suppressed-profile-output'

$env:MCP_POWERSHELL_PROFILE_TEST_VALUE = 'profile-loaded'

function Get-McpPowerShellProfileTestValue {
    $env:MCP_POWERSHELL_PROFILE_TEST_VALUE
}
