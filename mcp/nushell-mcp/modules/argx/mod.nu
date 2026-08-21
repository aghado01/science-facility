# argx — tokenize / parse a command line against a Nu command signature.
# Starting point: nu_scripts modules/argx. Occupies `argx parse` (`use argx`),
# not builtin `parse` unless glob-imported.

# Signature facts for a loaded command. Unknown / missing commands → empty lists
# (every flag then stays positional; see `parse`).
export def get-sign [cmd] {
    let x = (scope commands | where name == $cmd).signatures?.0?.any? | default []
    mut s = []
    mut n = {}
    mut named = []
    mut p = []
    mut pr = []
    mut r = []
    for it in $x {
        if $it.parameter_type == 'switch' {
            let long = $it.parameter_name
            let short = $it.short_flag
            if ($long | is-not-empty) {
                $s ++= [$long]
                if ($short | is-not-empty) {
                    $n = ($n | upsert $short $long)
                }
            } else if ($short | is-not-empty) {
                $s ++= [$short]
            }
        } else if $it.parameter_type == 'named' {
            if ($it.parameter_name | is-empty) {
                $n = ($n | upsert $it.short_flag $it.short_flag)
                $named ++= [$it.short_flag]
            } else if ($it.short_flag | is-empty) {
                $n = ($n | upsert $it.parameter_name $it.parameter_name)
                $named ++= [$it.parameter_name]
            } else {
                $n = ($n | upsert $it.short_flag $it.parameter_name)
                $named ++= [$it.parameter_name]
            }
        } else if $it.parameter_type == 'positional' {
            if $it.is_optional == false {
                $p ++= [$it.parameter_name]
            } else {
                $pr ++= [$it.parameter_name]
            }
        } else if $it.parameter_type == 'rest' {
            $r ++= [$it.parameter_name]
        }
    }
    { switch: $s, name: $n, named: $named, positional: ($p ++ $pr), rest: $r }
}

def unquote [tok: string] {
    let n = ($tok | str length)
    if $n < 2 { return $tok }
    let a = ($tok | str substring 0..<1)
    let b = ($tok | str substring ($n - 1)..)
    if $a in ['"' "'" '`'] and $a == $b {
        $tok | str substring 1..<($n - 1)
    } else {
        $tok
    }
}

# Split a command line into argv tokens.
# `\` is literal unless it escapes `\`, `"`, `'`, or backtick — Windows paths
# (`D:\foo\bar`) must survive. Matching quote wrappers are stripped.
export def token [] {
    let chars = ($in | split row '')
    let chars = (
        if ($chars | is-empty) { [] }
        else if ($chars | first) == '' and ($chars | last) == '' { $chars | slice 1..-2 }
        else { $chars }
    )
    if ($chars | is-empty) { return [] }
    let chars = (if ($chars | last) == ' ' { $chars } else { $chars | append ' ' })
    mut par = []
    mut res = []
    mut cur = ''
    mut esc = false
    mut i = 0
    let n = ($chars | length)
    loop {
        if $i >= $n { break }
        let c = ($chars | get $i)
        if $esc {
            $cur ++= $c
            $esc = false
            $i += 1
            continue
        }
        if $c == '\' {
            let nxt = (if ($i + 1) < $n { $chars | get ($i + 1) } else { '' })
            if $nxt in ['\' '"' "'" '`'] {
                $esc = true
            } else {
                $cur ++= $c
            }
            $i += 1
            continue
        }
        if $c == ' ' and ($par | is-empty) {
            if ($cur | is-not-empty) {
                $res ++= [(unquote $cur)]
            }
            $cur = ''
            $i += 1
            continue
        }
        if $c in ['{' '[' '('] {
            $par ++= [$c]
        }
        if $c in ['}' ']' ')'] {
            $par = ($par | slice ..-2)
        }
        if $c in ['"' "'" '`'] {
            if ($par | is-not-empty) and ($par | last) == $c {
                $par = ($par | slice ..-2)
            } else {
                $par ++= [$c]
            }
        }
        $cur ++= $c
        $i += 1
    }
    $res
}

def split-eq [spec: string] {
    let idx = ($spec | str index-of '=')
    if $idx < 0 {
        {key: $spec, val: null}
    } else {
        {
            key: ($spec | str substring 0..<$idx)
            val: ($spec | str substring ($idx + 1)..)
        }
    }
}

def resolve-key [raw: string, sign: record] {
    let spec = (
        if ($raw | str starts-with '--') {
            $raw | str substring 2..
        } else {
            $raw | str substring 1..
        }
    )
    let parts = (split-eq $spec)
    let mapped = (if $parts.key in $sign.name { $sign.name | get $parts.key } else { $parts.key })
    {key: $mapped, val: $parts.val, raw: $raw}
}

# Parse tokens against `get-sign` of argv[0].
# Known switches/named flags bind; unknown flags stay in `_args` (they do not
# consume the next token). `--` ends flag parsing. `--flag=value` splits.
export def parse [] {
    let token = ($in | token)
    if ($token | is-empty) {
        return {_args: [], _pos: {}}
    }
    let sign = (get-sign $token.0)
    mut sw = ''
    mut pos = []          # `_args`: argv[0], positionals, and unknown flags (unconsumed)
    mut bindable = []     # positional candidates only — unknown flags never bind to `_pos`
    mut opt = {}
    mut rest_only = false
    for c in $token {
        if $rest_only {
            $pos ++= [$c]
            $bindable ++= [$c]
            continue
        }
        if $c == '--' {
            $rest_only = true
            continue
        }
        if not ($sw | is-empty) {
            $opt = ($opt | upsert $sw $c)
            $sw = ''
            continue
        }
        if ($c | str starts-with '-') and ($c != '-') {
            let f = (resolve-key $c $sign)
            if $f.key in $sign.switch {
                $opt = ($opt | upsert $f.key true)
            } else if $f.key in ($sign.named | default []) {
                if $f.val != null {
                    $opt = ($opt | upsert $f.key $f.val)
                } else {
                    $sw = $f.key
                }
            } else {
                $pos ++= [$c]
            }
        } else {
            $pos ++= [$c]
            $bindable ++= [$c]
        }
    }
    $opt._args = $pos
    let npos = ($sign.positional | length)
    let p = (if $npos < 1 { [] } else { $bindable | skip 1 | take $npos })
    let rest = ($bindable | skip (1 + $npos))
    $opt._pos = (
        $p | enumerate
        | reduce -f {} {|it, acc|
            $acc | upsert ($sign.positional | get $it.index) $it.item
        }
    )
    if ($sign.rest | length) > 0 {
        $opt._pos = ($opt._pos | upsert $sign.rest.0 $rest)
    }
    $opt
}
