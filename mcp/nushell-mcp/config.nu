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
#   deps/cli/        vendored CLI binaries (rg, fd, jq, …) — gitignored, see deps/README.md

const MCP_ROOT = (path self | path dirname)
const MODULES_DIR = ($MCP_ROOT | path join modules)
const SKILLS_DIR = ($MCP_ROOT | path join skills nushell)
const DEPS_CLI_DIR = ($MCP_ROOT | path join deps cli)

# Parse-time: lets `use nu-skills` etc. resolve below.
const NU_LIB_DIRS = $NU_LIB_DIRS ++ [$MODULES_DIR]

# Runtime: nushell populates $env.NU_LIB_DIRS with its own defaults even when the
# process env is unset, so nu-modules' fallback would never fire — set it explicitly.
$env.NU_LIB_DIRS = ($env.NU_LIB_DIRS? | default [] | append $MODULES_DIR | uniq)
$env.NU_SKILL_DIR = $SKILLS_DIR

# Vendored CLI deps: prepend so the layer's pinned binaries win over whatever the
# host PATH happens to carry (deterministic console). Absent dir → no-op; wrappers
# like `rg` still fail closed if their binary is missing.
if ($DEPS_CLI_DIR | path exists) {
    $env.PATH = ($env.PATH | prepend $DEPS_CLI_DIR | uniq)
}

# Preload the augmentation modules into the persistent engine state.
# `par` freezes `$env.NU_PAR` (cores, knobs, ceiling) once via export-env;
# `jobs` initializes `$env.JOBS`. dataspection then xq then rg. Do not preload
# `core/capture.nu`; xq and rg import it. All die with the MCP child.
use nu-skills *
use nu-modules *
use par *
use jobs *
use dataspection *
use xq *
use rg *
