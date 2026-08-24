# Mutator Contracts & Shared Helpers

Processors in `reposnapshot-v3/processors/` follow the harmonized content-mutator contract.

## Contract Rules

1. **Track-Agnostic Content Resolution**:
   - Reads `Content` (descriptor contract) else `Text` (tp-era).
   - Writes the modified string back to the exact key that was read.
   - If neither key is present on an item, the item is returned untouched without fabricating an empty string.
2. **Copy-on-Mutate**:
   - Clones input property bags into a new `PSCustomObject` via `Copy-Bag`.
   - Caller references and existing identity fields (`AbsolutePath`, `RelativePath`, `NodePath`, etc.) are preserved intact.
   - Preserves property insertion order using ordered dictionaries.
3. **Processing Trail**:
   - Each mutator appends an entry to the `Processing` array (`@{ Processor; Operations; ... }`).
   - Multiple passes through a mutator append records sequentially.
4. **Early Termination (`_ChainHalt`)**:
   - Step processors signal pipeline halt by attaching `_ChainHalt = $true`.
   - `chain-executor.ps1` detects the halt property, aborts remaining steps for that item, and returns the halted object for diagnostic routing.
