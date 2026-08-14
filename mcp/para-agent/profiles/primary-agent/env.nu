# Profile 3: Primary Supervisor Agent Environment (env.nu)
$env.PARA_ROLE = "primary-supervisor"
$env.LANG = "en_US.UTF-8"

# Resolve package root and inject internal binaries to PATH
let pkg_root = ($env.PARA_PKG_ROOT? | default (pwd))
let nu_bin = ($pkg_root | path join "bin" "nu")
let mux_bin = ($pkg_root | path join "bin" "mux")

$env.PATH = ($env.PATH | prepend [$nu_bin, $mux_bin] | uniq)

# Setup history in gitignored workspace .para-agent directory
let ws_root = ($env.PARA_WORKSPACE_ROOT? | default (pwd))
let history_dir = ($ws_root | path join ".para-agent")
if not ($history_dir | path exists) {
  mkdir $history_dir
}
$env.NU_HISTORY_FILE = ($history_dir | path join "history.txt")
