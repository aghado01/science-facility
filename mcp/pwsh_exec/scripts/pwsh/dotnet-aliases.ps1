# Wrapper functions — Set-Alias only accepts a single command name, so anything
# that needs dotnet sub-commands or argument passthrough lives here.
# $script:DotNetExe is resolved from the portable env path set above — PATH
# lookup is intentionally bypassed so these work even before PATH propagates.
$script:DotNetExe = "$script:DotNetRootPath/dotnet.exe"

function Invoke-DotnetBuild { & $script:DotNetExe build @args }
function Invoke-DotnetRun { & $script:DotNetExe run @args }
function Invoke-DotnetTest { & $script:DotNetExe test @args }
function Invoke-DotnetWatch { & $script:DotNetExe watch @args }
function Invoke-DotnetNew { & $script:DotNetExe new @args }
function Invoke-DotnetAdd { & $script:DotNetExe add @args }
function Invoke-DotnetVersion { & $script:DotNetExe --version }

function Get-DotnetAliases {
    $dotnetAliases = @{
        'dbd'  = 'Invoke-DotnetBuild'    # dotnet build  [args]
        'drn'  = 'Invoke-DotnetRun'      # dotnet run    [args]
        'dtst' = 'Invoke-DotnetTest'     # dotnet test   [args]
        'dw'   = 'Invoke-DotnetWatch'    # dotnet watch  [args]
        'dnew' = 'Invoke-DotnetNew'      # dotnet new    [args]
        'dadd' = 'Invoke-DotnetAdd'      # dotnet add    [args]
        'dnv'  = 'Invoke-DotnetVersion'  # dotnet --version
    }
    return $dotnetAliases
}

$script:dotnetAliases = Get-DotnetAliases
Set-SessionAliasesScoped -Aliases $script:dotnetAliases -Scope Global
