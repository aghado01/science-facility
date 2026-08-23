# dataspection — agent-facing façade: census/views/meta re-exported from core/, plus in-hand `read`.
# `use dataspection *`. Does not export `inspect` (nushell's builtin stays).
# Does not re-export `value.*` or `failure fields`.
# `read` is `--env` and stashes over cap through `jobs stash`.

export use core/census.nu *
export use core/schema.nu *
export use core/spine.nu *
export use core/views.nu *
export use core/meta.nu *

use core/failure.nu ["failure fields"]
use jobs ["jobs stash"]
use par ["par cap"]

# Disclose the body. Under cap → the value. Over cap → stash via `jobs stash` and a receipt naming `jobs fetch <tag>`. `--env`. The only verb that may decline.
export def --env read []: any -> any {
    try {
        let x = $in
        let s = ($x | shape)
        let cap = (par cap)
        let bytes = $s.bytes
        if $bytes == null or $bytes <= $cap {
            return $x
        }
        let stashed = (try { $x | jobs stash } catch {|e|
            let f = (failure fields $e)
            {ok: false, error: $f.error, trace: $f.trace}
        })
        if ($stashed.ok? == false) {
            return ($stashed | default {} | merge {
                ok: false
                disclosed: false
                tag: ($stashed.tag? | default null)
                bytes: $bytes
                error: ($stashed.error? | default "stash failed")
                trace: ($stashed.trace? | default ($stashed.error? | default "stash failed"))
            } | meta stamp --verb read)
        }
        let tag = $stashed.tag
        {
            ok: true
            disclosed: false
            tag: $tag
            bytes: $bytes
            retrieve: $"jobs fetch ($tag)"
        } | meta stamp --verb read
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, disclosed: false, error: $f.error, trace: $f.trace} | meta stamp --verb read
    }
}
