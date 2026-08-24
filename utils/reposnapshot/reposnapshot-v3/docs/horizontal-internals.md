# Horizontal Infrastructure & Parameter Forwarding

The internals module (`rs.core.internals.psm1`) provides shared utilities for parameter forwarding and dynamic wrapper construction.

## Dynamic Parameter Reflection

`New-ForwardedParamDictionary` inspects target cmdlets/functions and constructs a `RuntimeDefinedParameterDictionary` for use in `DynamicParam` blocks.

### Default Value Policy

- Default values are intentionally **not** reflected into dynamic parameter dictionaries.
- When an argument is omitted by a caller, it remains absent from `$PSBoundParameters`.
- The target function's native `param(...)` default applies naturally, preserving tri-state evaluation (unset / explicit default / explicit non-default).

## Utilities

- `New-ForwardedParamDictionary`: Constructs dynamic parameter dictionaries from a command's metadata.
- `Split-ForwardedParams`: Splits `$PSBoundParameters` into target parameters and wrapper-specific parameters.
- `Register-StageWrapper`: Dynamically creates transparent wrapper functions in the current session.
