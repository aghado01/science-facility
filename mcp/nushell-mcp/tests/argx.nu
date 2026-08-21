# Child `nu -n` tests for argx. Run:
#   nu -n mcp/nushell-mcp/tests/argx.nu

const MODULES_DIR = (path self | path dirname | path dirname | path join modules)
const NU_LIB_DIRS = [$MODULES_DIR]

use argx

def probe [a b x? ...y --cd(-c) --ef(-e): string -g --ij] {}

def assert-eq [left, right, msg: string] {
    if $left != $right {
        error make {msg: $"($msg): expected ($right | to nuon --raw), got ($left | to nuon --raw)"}
    }
}

def t [name: string, fn: closure] {
    try {
        do $fn
        {name: $name, ok: true, error: null}
    } catch {|e|
        {name: $name, ok: false, error: ($e.msg | lines | first | default $e.msg)}
    }
}

let results = [
    (t "windows path is literal" {
        assert-eq ("rg foo D:\\aghado01\\x.md" | argx token) [rg foo "D:\\aghado01\\x.md"] "path"
    })
    (t "escaped backslash" {
        assert-eq ("foo\\\\bar" | argx token) ["foo\\bar"] "double backslash"
    })
    (t "quoted token strips wrappers" {
        assert-eq ("rg 'a b' c" | argx token) [rg "a b" c] "single"
        assert-eq ("rg \"a b\" c" | argx token) [rg "a b" c] "double"
    })
    (t "nu grouping still one token" {
        assert-eq ("test [123 (3213 3)] x" | argx token) [test "[123 (3213 3)]" x] "brackets"
    })
    (t "empty line" {
        assert-eq ("" | argx token) [] "empty"
    })
    (t "unknown flags stay in _args" {
        let p = ("rg foo -C 1 --type rust" | argx parse)
        assert-eq $p._args [rg foo -C "1" --type rust] "not stolen"
        assert-eq ($p | columns | where {|c| $c not-in [_args _pos]} | is-empty) true "no invented keys"
    })
    (t "known named consumes value" {
        let p = ("probe 1 2 --ef sadf extra" | argx parse)
        assert-eq $p.ef sadf "ef"
        assert-eq $p._args [probe "1" "2" extra] "args"
        assert-eq $p._pos.a "1" "a"
        assert-eq $p._pos.x extra "optional pos"
        assert-eq $p._pos.y [] "rest empty"
    })
    (t "switch short maps to long" {
        let p = ("probe 1 2 -c -g" | argx parse)
        assert-eq $p.cd true "cd from -c"
        assert-eq $p.g true "g"
        assert-eq ($p.c? | default null) null "short key not left behind"
    })
    (t "flag=value" {
        let p = ("probe 1 2 --ef=sadf" | argx parse)
        assert-eq $p.ef sadf "eq"
    })
    (t "double-dash ends flags" {
        let p = ("probe 1 2 -- -g leftover" | argx parse)
        assert-eq ($p.g? | default null) null "g not a switch"
        assert-eq $p._args [probe "1" "2" -g leftover] "dash-g stays positional"
    })
    (t "rest after required and optional pos" {
        let p = ("probe 1 2 3 4 5" | argx parse)
        assert-eq $p._pos.a "1" "a"
        assert-eq $p._pos.x "3" "x"
        assert-eq $p._pos.y ["4" "5"] "y"
    })
    (t "missing command is rest-like" {
        let p = ("nosuch --json foo" | argx parse)
        assert-eq $p._args [nosuch --json foo] "flags not consumed"
    })
]

let failed = ($results | where {|r| $r.ok == false })
print -e ($results | to nuon --raw)
if ($failed | is-empty) {
    $results | select name ok
} else {
    error make {msg: ($failed | get name | str join ", ")}
}
