# Colonel & InitialSessionState (ISS) Dispatch

Colonel (`rs.core.colonel.v2.psm1`) compiles processing plans and manages worker runspace pools for parallel or serial processor execution.

## Two-Call API Surface

1. **`Compile-Plan`**:
   - Parses each processor script file with the native PowerShell parser.
   - Validates that scripts declare a top-level `param(...)` block.
   - Enforces the `#Requires` prohibition: `#Requires` is rejected via `$ast.ScriptRequirements` because directives are inert when function bodies are loaded into an InitialSessionState.
   - Registers script bodies as `SessionStateFunctionEntry` instances.
   - Registers shared helpers (`bag-helpers.ps1`) and the runtime engine (`chain-executor.ps1`).
   - Returns a frozen, immutable `Plan` object.

2. **`Invoke-Plan`**:
   - Resolves worker budget (worker count, chunk sizing) based on item count and core availability.
   - Creates a `RunspacePool` using the compiled `InitialSessionState`.
   - Dispatches items round-robin or chunked to pool workers.
   - Collates results into an index-stable envelope (`Results`, `Errors`, `Warnings`, `Streams`, `Budget`, `Timing`).

## InitialSessionState Presets (`IssPreset`)

- **`Bare`**: Empty engine with 0 built-in cmdlets. Processors must rely exclusively on .NET types and pure functions.
- **`Core` (Default)**: PowerShell Core core cmdlets only. Provides high isolation and low overhead.
- **`Full`**: Full module and provider set loaded. Used when processors require filesystem or external providers.

## Worker Closure Rules

Worker runspaces do not share module scope with the caller. All state required by a processor must arrive via parameters ($Item and $Config). Shared helpers must be pure functions registered in the ISS.
