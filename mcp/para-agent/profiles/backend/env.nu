# Profile 1: Backend Stdio Daemon Environment (env.nu)
$env.PARA_MODE = "backend-daemon"
$env.LANG = "en_US.UTF-8"

# Resolve package root and inject internal binaries to PATH
let pkg_root = ($env.PARA_PKG_ROOT? | default (pwd))
let nu_bin = ($pkg_root | path join "bin" "nu")
let mux_bin = ($pkg_root | path join "bin" "mux")

$env.PATH = ($env.PATH | prepend [$nu_bin, $mux_bin] | uniq)
