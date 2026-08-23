# failure — normalize a caught Nu error for fail-as-data results.
# Does not throw. Not re-exported by the dataspection façade.

# Short first line + full rendered/debug trace.
export def "failure fields" [e]: nothing -> record {
    let msg = (try { $e.msg } catch { "error" })
    let line = (try { $msg | lines | first } catch { $msg }) | default $msg
    let short = (
        if ($line | str length) <= 240 { $line } else { $line | str substring ..<240 }
    )
    let rendered = (try { $e.rendered } catch { "" }) | default ""
    let debug = (try { $e.debug } catch { "" }) | default ""
    let trace = (
        if ($rendered | str length) > 0 { $rendered
        } else if ($debug | str length) > 0 { $debug
        } else { $short }
    )
    {error: $short, trace: $trace}
}
