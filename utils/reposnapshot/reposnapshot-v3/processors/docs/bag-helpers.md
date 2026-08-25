# bag-helpers.ps1

```powershell
<#
.SYNOPSIS
    ISS-registered shared library for reposnapshot processors.

.DESCRIPTION
    Registered into every worker runspace by Compile-Plan -SharedHelperPath, the
    same way chain-executor is. Never appears in a processor manifest or profile.

    Unlike a processor, this file DOES declare function wrappers: Compile-Plan
    registers each top-level function separately as a SessionStateFunctionEntry.

    WHY THIS EXISTS:
      The 6d harmonization put the same content-key resolution and copy-on-mutate
      clone in four content mutators, and the same clone-all in file-read and
      rs-content_meta. `Add-Member` became the fleet's dominant cmdlet purely as a
      side effect. One definition of the contract beats six copies of it, and the
      clone gets to be a single ordered-hashtable cast instead of N reflection calls.

    CLOSURE RULE (same as chain-executor):
      Pure functions, parameters only. No module-scope references — the closure
      environment does not cross the runspace boundary.

    STANDALONE USE:
      Processors dot-invoked outside an ISS (the processors/tests suites) must
      dot-source this file first; see processors/tests/_helpers.ps1.
#>
```
