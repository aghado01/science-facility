# nu-modules.nu — discovery and introspection over $env.NU_LIB_DIRS
#
# Uses nushell's own loader as the source of truth: a unit is whatever `use`
# accepts, loadability is decided by actually loading it in a child `nu -n`,
# and command facts come from `scope modules` / `scope commands` there.
# No source-text parsing of definitions.

# `path self` only works at parse time, so capture the module dir in a const
const SELF_DIR = (path self | path dirname)

# ---------------------------------------------------------------- helpers

# Existing library directories from $env.NU_LIB_DIRS (list, or PATH-style string)
def lib-dirs []: nothing -> list<string> {
    let raw = ($env.NU_LIB_DIRS? | default ($SELF_DIR | path join ".."))
    let dirs = if ($raw | describe) =~ "list" { $raw } else { $raw | split row (char esep) }
    $dirs
    | each {|d| $d | path expand | str replace -a '\' '/' }
    | where {|d| $d | path exists }
}

# Enumerate `use`-able units under one lib dir.
#   dir containing mod.nu           -> {unit: <dir>,          kind: module}
#   any other .nu file (recursive)  -> {unit: <rel/path.nu>,  kind: file}
# Files inside a mod.nu directory are internal to that module and not listed.
def units-in [lib: string]: nothing -> table {
    let entries = (ls $lib)
    let dirs = ($entries | where type == dir | get name | each {|d| $d | str replace -a '\' '/' })
    let mod_dirs = ($dirs | where {|d| $d | path join mod.nu | path exists })
    let loose_dirs = ($dirs | where {|d| not ($d | path join mod.nu | path exists) })

    let modules = ($mod_dirs | each {|d|
        {unit: ($d | path basename), kind: "module", entry: ($d | path join mod.nu), lib: $lib}
    })
    let loose_files = ($loose_dirs
        | each {|d| glob $"($d)/**/*.nu" }
        | flatten
        | append ($entries | where type == file and name =~ '\.nu$' | get name)
        | each {|f|
            let f = ($f | str replace -a '\' '/')
            {unit: ($f | str replace $"($lib)/" ''), kind: "file", entry: $f, lib: $lib}
        })
    $modules | append $loose_files
}

# All units across all lib dirs
def all-units []: nothing -> table {
    lib-dirs | each {|lib| units-in $lib } | flatten | sort-by kind unit
}

# Resolve a unit name to its record, or error listing what exists
def resolve [name: string]: nothing -> record {
    let all = (all-units)
    let hit = ($all | where unit == $name)
    if ($hit | is-empty) {
        error make {
            msg: $"Unit '($name)' not found in NU_LIB_DIRS. Known units:\n($all | get unit | each { $'  - ($in)' } | str join "\n")"
        }
    }
    $hit | first
}

# Load a unit in a child nu and return what the engine says about it.
# Single mechanism for both "does it load" and "what does it export".
def load-unit [u: record]: nothing -> record {
    let stem = ($u.unit | path parse | get stem)
    let script = ([
        'const NU_LIB_DIRS = ' (lib-dirs | to nuon) '; '
        'use ' $u.unit ' *; '
        'let m = (scope modules | where name == ' ($stem | to nuon) ' | first); '
        'let cmds = (scope commands | where name in ($m.commands.name) | select name description signatures attributes is_sub); '
        '{module: $m.name, file: $m.file, has_env: $m.has_env_block, description: $m.description, commands: $cmds} | to nuon'
    ] | str join)
    # `$nu.current-exe`, not `^nu`: the MCP child's PATH need not contain a
    # `nu` at all (the engine is launched by absolute path from .mcp.json, and
    # config.nu prepends only deps/cli). Using the running binary also pins the
    # child to this session's engine version.
    let r = (^$nu.current-exe -n -c $script | complete)
    if $r.exit_code == 0 {
        let info = ($r.stdout | from nuon)
        {loads: true, error: "", info: $info}
    } else {
        let err = ($r.stderr | lines | where $it =~ '^\s*(Error:|x )' | str join ' | ' | str trim | str substring 0..240)
        {loads: false, error: $err, info: null}
    }
}

# Render one `scope commands` signature record as a compact string
def render-sig [sigs: record]: nothing -> string {
    let params = ($sigs | transpose k v | get -o 0.v | default [])
    let inp = ($params | where parameter_type == input | get -o 0.syntax_shape | default "any")
    let out = ($params | where parameter_type == output | get -o 0.syntax_shape | default "any")
    let args = ($params
        | where parameter_type in [positional rest named switch]
        | each {|p|
            let short = (if $p.short_flag != null { '(-' + $p.short_flag + ')' } else { '' })
            match $p.parameter_type {
                "positional" => $"($p.parameter_name)(if $p.is_optional { '?' } else { '' }): ($p.syntax_shape)",
                "rest" => $"...($p.parameter_name): ($p.syntax_shape)",
                "switch" => $"--($p.parameter_name)($short)",
                "named" => $"--($p.parameter_name)($short): ($p.syntax_shape)",
                _ => ""
            }
        }
        | str join ", ")
    $"[($args)]: ($inp) -> ($out)"
}

# ---------------------------------------------------------------- exports

# Exported as `main` — a module cannot export a command named after itself;
# `use nu-modules` / `use nu-modules *` binds this to `nu-modules`.

# List all units, or inspect one
export def main [
    unit?: string # Optional unit to inspect (e.g. argx, formats/to-ini.nu)
]: nothing -> any {
    if ($unit == null or $unit == "") { nu-modules list } else { nu-modules inspect $unit }
}

# List every `use`-able unit on NU_LIB_DIRS with loadability decided by loading it
export def "nu-modules list" []: nothing -> table {
    all-units | each {|u|
        let p = (load-unit $u)
        {
            unit: $u.unit,
            kind: $u.kind,
            loads: $p.loads,
            commands: (if $p.loads { $p.info.commands | length } else { null }),
            has_env: (if $p.loads { $p.info.has_env } else { null }),
            error: $p.error,
            entry: $u.entry,
        }
    }
}

# Exported commands of one unit, straight from `scope commands` after loading it
export def "nu-modules inspect" [
    unit: string # Unit name as shown by `nu-modules list`
]: nothing -> table {
    let u = (resolve $unit)
    let p = (load-unit $u)
    if not $p.loads {
        error make { msg: $"Unit '($unit)' does not load:\n($p.error)" }
    }
    $p.info.commands | each {|c|
        {
            module: $p.info.module,
            command: $c.name,
            signature: (render-sig $c.signatures),
            description: $c.description,
            attributes: ($c.attributes | get -o name | default []),
        }
    }
}

# Line-level regex search across every .nu file on NU_LIB_DIRS (text search, not parsed)
export def "nu-modules search" [
    query: string # Regex to search for
]: nothing -> table {
    lib-dirs | each {|lib|
        glob $"($lib)/**/*.nu" | each {|f|
            let f = ($f | str replace -a '\' '/')
            open --raw $f | lines | enumerate
            | where {|row| $row.item =~ $query }
            | each {|row| {file: ($f | str replace $"($lib)/" ''), line: ($row.index + 1), content: ($row.item | str trim)} }
        } | flatten
    } | flatten
}

# Raw source of a unit's entry file (mod.nu for a module, the file itself for a file unit)
export def "nu-modules read" [
    unit: string # Unit name as shown by `nu-modules list`
]: nothing -> string {
    open --raw (resolve $unit | get entry)
}

# Lib dirs and unit/command totals
export def "nu-modules status" []: nothing -> record {
    let rows = (nu-modules list)
    {
        lib_dirs: (lib-dirs),
        units: ($rows | length),
        loadable: ($rows | where loads | length),
        commands: ($rows | where loads | get commands | append 0 | math sum),
    }
}
