# config.nu — startup config for the nushell MCP augmentation layer
#   nu --mcp --config <path-to-this-file>
#
# This file is the SINGLE OWNER of the layer's layout. Launchers (.mcp.json,
# para-agent, a hand-run `nu --mcp`) only need to pass --config; they should
# not set NU_LIB_DIRS / NU_SKILL_DIR themselves. Everything below is anchored
# to this file's location via `path self`, so it is cwd-independent.
#
# Layout:
#   modules/         custom modules incl. nu-skills, nu-modules
#   skills/nushell/  reference corpus (SKILL.md + references/*.md)

const MCP_ROOT = (path self | path dirname)
const MODULES_DIR = ($MCP_ROOT | path join modules)
const SKILLS_DIR = ($MCP_ROOT | path join skills nushell)

# Parse-time: lets `use nu-skills` etc. resolve below.
const NU_LIB_DIRS = $NU_LIB_DIRS ++ [$MODULES_DIR]

# Runtime: nushell populates $env.NU_LIB_DIRS with its own defaults even when the
# process env is unset, so nu-modules' fallback would never fire — set it explicitly.
$env.NU_LIB_DIRS = ($env.NU_LIB_DIRS? | default [] | append $MODULES_DIR | uniq)
$env.NU_SKILL_DIR = $SKILLS_DIR

# Preload the augmentation modules into the persistent engine state.
use nu-skills *
use nu-modules *
