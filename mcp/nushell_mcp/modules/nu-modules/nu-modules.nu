# nu-modules.nu - Native module introspection and discovery for $env.NU_LIB_DIRS

# `path self` only works at parse time, so capture the module dir in a const
const SELF_DIR = (path self | path dirname)

# Resolve list of existing library directories from $env.NU_LIB_DIRS
def get-lib-dirs []: nothing -> list<string> {
    let raw = ($env.NU_LIB_DIRS? | default ($SELF_DIR | path join ".."))
    # Accept a list (nushell-native) or a PATH-style joined string (raw OS env)
    let list_dirs = if ($raw | describe) =~ "list" {
        $raw
    } else {
        $raw | split row (char esep)
    }
    
    $list_dirs
    | each { |d| $d | path expand }
    | where { |d| $d | path exists }
}

# Recursively glob *.nu under a dir; `glob` rejects backslash separators, so normalize
def nu-files-under [dir: string]: nothing -> list<string> {
    glob $"($dir | str replace -a '\' '/')/**/*.nu"
}

# Find entry file or root directory for a given module name
def resolve-module [name: string]: nothing -> record {
    let dirs = (get-lib-dirs)
    for dir in $dirs {
        let dir_mod = ($dir | path join $name)
        if ($dir_mod | path exists) and (($dir_mod | path type) == "dir") {
            let mod_entry = ($dir_mod | path join "mod.nu")
            let alt_entry = ($dir_mod | path join $"($name).nu")
            let entry = if ($mod_entry | path exists) {
                $mod_entry
            } else if ($alt_entry | path exists) {
                $alt_entry
            } else {
                let first_nu = (ls ($dir_mod | path join "*.nu" | into glob) | first 1 | default [{ name: "" }] | get 0.name)
                $first_nu
            }
            return { found: true, type: "dir", name: $name, path: $dir_mod, entry: $entry }
        }

        let file_mod = ($dir | path join $"($name).nu")
        if ($file_mod | path exists) {
            return { found: true, type: "file", name: $name, path: $file_mod, entry: $file_mod }
        }
    }

    { found: false, type: "none", name: $name, path: "", entry: "" }
}

# Exported as `main` — nushell forbids a module exporting a command with its own name;
# `use nu-modules` / `use nu-modules *` binds this to `nu-modules`.

# Main command: List all modules or inspect a specific module
export def main [
    name?: string # Optional module name to inspect
]: nothing -> any {
    if ($name == null or $name == "") {
        nu-modules list
    } else {
        nu-modules inspect $name
    }
}

# List all available modules across $env.NU_LIB_DIRS in a structured table
export def "nu-modules list" []: nothing -> table {
    let lib_dirs = (get-lib-dirs)
    if ($lib_dirs | is-empty) {
        return []
    }

    $lib_dirs
    | each { |dir|
        let entries = (ls $dir)
        let dir_mods = ($entries | where type == dir | each { |d|
            let mod_name = ($d.name | path basename)
            let nu_files = (nu-files-under $d.name)
            let cmd_count = if ($nu_files | is-not-empty) {
                $nu_files | each { |f| open --raw $f | lines | where $it =~ '^\s*export\s+def' | length } | math sum
            } else { 0 }

            {
                module: $mod_name,
                type: "dir",
                commands: $cmd_count,
                path: $d.name
            }
        })

        let file_mods = ($entries | where type == file and name =~ '\.nu$' | each { |f|
            let mod_name = ($f.name | path parse | get stem)
            let cmd_count = (open --raw $f.name | lines | where $it =~ '^\s*export\s+def' | length)

            {
                module: $mod_name,
                type: "file",
                commands: $cmd_count,
                path: $f.name
            }
        })

        $dir_mods | append $file_mods
    }
    | flatten
    | sort-by module
}

# Inspect a module and extract all exported commands, signatures, and doc comments
export def "nu-modules inspect" [
    name: string # Module name to inspect
]: nothing -> table {
    let mod = (resolve-module $name)
    if not $mod.found {
        let available = (nu-modules list | get module)
        error make {
            msg: $"Module '($name)' not found in NU_LIB_DIRS.\nAvailable modules:\n($available | each { $'  - ($in)' } | str join "\n")"
        }
    }

    let files_to_scan = if $mod.type == "dir" {
        nu-files-under $mod.path
    } else {
        [$mod.entry]
    }

    $files_to_scan
    | each { |file|
        let lines = (open --raw $file | lines)
        let total = ($lines | length)

        $lines
        | enumerate
        | where { |row| $row.item =~ '^\s*export\s+def' }
        | each { |row|
            let def_line = ($row.item | str trim)
            let cmd_name = ($def_line | parse -r 'export\s+def\s+(?:(?:"([^"]+)")|([^\s\[]+))' | get -o 0 | default {} | values | compact | get -o 0 | default "")
            # Signature is only captured when the `[...]` closes on the def line; multi-line sigs yield ""
            let sig = ($def_line | parse -r 'export\s+def\s+(?:(?:"[^"]+")|(?:[^\s\[]+))\s*(\[[^\]]*\](?:\s*:\s*[^\s\{]+)?)' | get -o 0.capture0 | default "")
            
            # Look backwards for docstring comment
            let idx = $row.index
            let doc = if $idx > 0 {
                let prev = ($lines | get ($idx - 1) | str trim)
                if ($prev | str starts-with "#") {
                    $prev | str replace -r '^#+\s*' ''
                } else { "" }
            } else { "" }

            {
                module: $name,
                command: $cmd_name,
                signature: $sig,
                description: $doc,
                file: ($file | path basename)
            }
        }
    }
    | flatten
}

# Search across all module files for a keyword or pattern
export def "nu-modules search" [
    query: string # Keyword or regex to search for in modules
]: nothing -> table {
    let lib_dirs = (get-lib-dirs)
    if ($lib_dirs | is-empty) {
        return []
    }

    $lib_dirs
    | each { |dir|
        nu-files-under $dir
        | each { |file|
            let mod_name = ($file | path parse | get stem)
            open --raw $file
            | lines
            | enumerate
            | where { |row| $row.item =~ $query }
            | each { |row|
                {
                    module: $mod_name,
                    line: ($row.index + 1),
                    content: ($row.item | str trim),
                    file: ($file | path basename)
                }
            }
        }
        | flatten
    }
    | flatten
}

# Read the raw source code of a module entrypoint
export def "nu-modules read" [
    name: string # Module name to read
]: nothing -> string {
    let mod = (resolve-module $name)
    if not $mod.found {
        error make { msg: $"Module '($name)' not found in NU_LIB_DIRS" }
    }
    open --raw $mod.entry
}

# Diagnostics for $env.NU_LIB_DIRS and module counts
export def "nu-modules status" []: nothing -> record {
    let dirs = (get-lib-dirs)
    let mods = (nu-modules list)
    let total_cmds = if ($mods | is-empty) { 0 } else { $mods | get commands | math sum }

    {
        lib_dirs: $dirs,
        module_count: ($mods | length),
        total_commands: $total_cmds
    }
}
