# bag-helpers.ps1 — ISS-registered shared library (NOT a step-processor)
# =============================================================================
# Registered into every worker runspace by Compile-Plan -SharedHelperPath, the
# same way chain-executor is. Never appears in a processor manifest or profile.
#
# Unlike a processor, this file DOES declare function wrappers: Compile-Plan
# registers each top-level function separately as a SessionStateFunctionEntry.
#
# WHY THIS EXISTS
#   The 6d harmonization put the same content-key resolution and copy-on-mutate
#   clone in four content mutators, and the same clone-all in file-read and
#   rs-content_meta. `Add-Member` became the fleet's dominant cmdlet purely as a
#   side effect. One definition of the contract beats six copies of it, and the
#   clone gets to be a single ordered-hashtable cast instead of N reflection
#   calls.
#
# CLOSURE RULE (same as chain-executor): pure functions, parameters only. No
# module-scope references — the closure environment does not cross the runspace
# boundary.
#
# STANDALONE USE
#   Processors dot-invoked outside an ISS (the processors/tests suites) must
#   dot-source this file first; see processors/tests/_helpers.ps1.
# =============================================================================

function Resolve-BagContent
{
    # Content-key resolution — the harmonized content-mutator contract (6d).
    #
    # Reads Content (descriptor contract) else Text (tp-era). The key that was
    # read is the key the caller writes back, which is what keeps a mutator
    # track-agnostic. Content wins when both exist; Text is then left exactly as
    # found (never edit a key you did not read) — no current producer emits both.
    #
    # Returns $null when there is nothing to mutate, so callers guard with one
    # line and pass the item through untouched:
    #   - a bag carrying NEITHER key (mirrors rs-content_meta' no-Content rule: a
    #     mutator with nothing to mutate must not fabricate an empty payload,
    #     because assemble splits EmptyFile from EmptiedByProcessing and a
    #     phantom '' would forge an entry)
    #   - anything that is not a string, hashtable or pscustomobject
    #
    # Otherwise returns @{ Kind; Keys; ContentKey; Text }:
    #   Kind 'String' — bare string in; ContentKey is $null and the caller
    #                   returns a bare string out (a track-agnostic processor
    #                   must not invent a track-specific key)
    #   Kind 'Bag'    — Keys in declaration order, ContentKey, Text
    param([object] $Item)

    if ($Item -is [string])
    {
        return [pscustomobject]@{ Kind = 'String'; Keys = @(); ContentKey = $null; Text = $Item }
    }

    if ($Item -is [hashtable] -or $Item -is [pscustomobject])
    {
        $keys = if ($Item -is [hashtable]) { @($Item.Keys) } else { @($Item.PSObject.Properties.Name) }
        $contentKey = if ('Content' -in $keys) { 'Content' } elseif ('Text' -in $keys) { 'Text' } else { $null }
        if ($null -eq $contentKey) { return $null }

        return [pscustomobject]@{
            Kind       = 'Bag'
            Keys       = $keys
            ContentKey = $contentKey
            Text       = [string]$Item.$contentKey
        }
    }

    return $null
}

function Copy-Bag
{
    # Copy-on-enrich / copy-on-mutate — one definition for the whole fleet.
    #
    # Clones the incoming bag and returns a NEW pscustomobject; the caller's
    # reference is never mutated. Built by a single [ordered] cast rather than N
    # Add-Member calls: same property order, one allocation, and it works under
    # a Bare ISS where Add-Member does not exist.
    #
    #   -Resolved  a Resolve-BagContent result. When its Kind is 'String' the
    #              content itself is returned (bare string in, bare string out).
    #              When Kind is 'Bag', ContentKey is replaced with -Content.
    #   -Content   replacement content for the resolved key. Mutators pass their
    #              transformed text; readers/enrichers omit it.
    #   -Add       extra properties to set after cloning (adds or overwrites).
    #              This is how file-read attaches Content/Encoding/ReadError and
    #              rs-content_meta attaches Attributes, without Add-Member.
    #              Typed IDictionary so callers can pass [ordered]@{} — a plain
    #              hashtable enumerates in no guaranteed order, which would make
    #              emitted property order nondeterministic run to run.
    #   -Record    a Processing record to APPEND to the bag's trail. Chain order
    #              is array order, so a profile running the same processor twice
    #              records both passes instead of the second overwriting the
    #              first. Omit to attach nothing (IncludeMeta = $false).
    param(
        [object]                        $Item,
        [object]                        $Resolved = $null,
        [object]                        $Content = $null,
        [System.Collections.IDictionary] $Add = $null,
        [object]                        $Record = $null
    )

    # Bare string in → bare string out; there is no bag to carry metadata.
    if ($null -ne $Resolved -and $Resolved.Kind -eq 'String') { return $Content }

    $keys = if ($null -ne $Resolved) { $Resolved.Keys }
    elseif ($Item -is [hashtable]) { @($Item.Keys) }
    else { @($Item.PSObject.Properties.Name) }

    $contentKey = if ($null -ne $Resolved) { $Resolved.ContentKey } else { $null }

    $ord = [ordered]@{}
    foreach ($name in $keys)
    {
        $ord[$name] = if ($null -ne $contentKey -and $name -eq $contentKey) { $Content } else { $Item.$name }
    }

    if ($null -ne $Add)
    {
        foreach ($k in $Add.Keys) { $ord[$k] = $Add[$k] }
    }

    if ($null -ne $Record)
    {
        $ord['Processing'] = if ('Processing' -in $keys) { @($Item.Processing) + $Record } else { @($Record) }
    }

    return [pscustomobject]$ord
}
