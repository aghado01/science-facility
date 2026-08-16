# config.nu — startup config for the nushell MCP server
#   nu --mcp --config ./mcp/nushell_mcp/config.nu
#
# Preloads the augmented-shell modules so every `evaluate` call sees them
# without an explicit `use`. Self-anchoring: the env NU_LIB_DIRS from
# .mcp.json is NOT yet merged into the parse-time const when this file is
# parsed, so we extend the const here relative to this file's location.

const MCP_ROOT = (path self | path dirname)
const NU_LIB_DIRS = $NU_LIB_DIRS ++ [($MCP_ROOT | path join modules)]

# Runtime env for the modules themselves (nu-modules reads $env.NU_LIB_DIRS,
# nu-skills reads $env.NU_SKILL_DIR). Defaults keep working even if .mcp.json
# omits them.
$env.NU_SKILL_DIR = ($env.NU_SKILL_DIR? | default ($MCP_ROOT | path join skills nushell))

use nu-skills *
use nu-modules *
