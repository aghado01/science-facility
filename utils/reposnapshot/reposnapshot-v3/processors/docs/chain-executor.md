# chain-executor.ps1

```powershell
<#
.SYNOPSIS
    ISS Infrastructure runtime executor for reposnapshot step-processors.

.DESCRIPTION
    RUNSPACE BOUNDARY: Always executes inside a runspace, serial or parallel.
      - Serial branch:   single dedicated runspace opened from $this.Iss
      - Parallel branch: pool workers, each opened from the same $this.Iss

    Registered unconditionally by Colonel's BuildIss() via SessionStateFunctionEntry.
    Never appears in the processor manifest or any processing profile.
    Not a step-processor — this is the runtime that runs step-processors.

    CLOSURE RULE: Pure function. No module-scope variable references permitted.
    Closure environment does not cross the runspace boundary. Everything needed
    at runtime must arrive via parameters.

    CHAINING CONTRACT:
      Iterates Plan.Steps in compiled order. Output of step N is passed as input
      to step N+1. Steps are called by resolved function name (Fn) — all name
      resolution happened at Compile() time in Colonel's module space.
      This function makes zero planning decisions at runtime.

    _ChainHalt CONVENTION:
      Any step-processor may add a _ChainHalt property to its return object to
      signal early exit. Remaining steps are skipped; the item is returned as-is.
      This protocol is owned entirely by chain-executor — step-processors only
      set the property, they do not implement the skip logic.

    Plan shape expected:
      $Plan.Steps — ordered array of:
        @{ Key = [string]; Fn = [string]; Config = [hashtable] }
      Key    — processor identity (for diagnostics)
      Fn     — resolved function name available in this runspace (e.g. 'Invoke-rs-psstrip')
      Config — per-step params passed as second argument to the processor
#>
```
