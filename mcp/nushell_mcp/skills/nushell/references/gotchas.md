# Nushell: LLM Gotchas & Syntax Traps

## String Interpolation & Escaping
- **Parentheses required**: `$"Count: (ls | length)"` (never `$"Count: {$var}"`).
- **Literal parens**: Must escape with backslash: `$"\(literal text\)"` (un-escaped `(text)` evaluates as a command call).

## Scope & Pipeline Precedence
- **`where` multi-condition**: Use bare columns (`where a > 1 and b > 2`). Chaining `$in` (`where ($in.a > 1) and ($in.b > 2)`) breaks because `$in` rebinds to `bool` after first clause.
- **Sub-pipelines in conditions**: `where (col | cmd)` requires parens, otherwise parsed as next pipeline stage.

## MCP Execution Substrate
- **Stdio output**: Bare `print "text"` in stdio MCP drops output. Return values implicitly or use `print -e "stderr msg"`.
- **Result retrieval**: Access truncated MCP output buffers via `$history.0`, `$history.1`.
