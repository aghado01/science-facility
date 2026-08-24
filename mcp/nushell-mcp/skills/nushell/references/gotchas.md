# Nushell: LLM Gotchas & Syntax Traps

## String Interpolation & Escaping
- **Parentheses required**: `$"Count: (ls | length)"` (never `$"Count: {$var}"`).
- **Literal parens**: Must escape with backslash: `$"\(literal text\)"` (un-escaped `(text)` evaluates as a command call).

## Scope & Pipeline Precedence
- **`where` multi-condition**: Use bare columns (`where a > 1 and b > 2`). Chaining `$in` (`where ($in.a > 1) and ($in.b > 2)`) breaks because `$in` rebinds to `bool` after first clause.
- **Sub-pipelines in conditions**: `where (col | cmd)` requires parens, otherwise parsed as next pipeline stage.

## MCP Execution Substrate
- **Builtin `inspect` is a passthrough, not a census.** It prints a debug table to the terminal — which does not exist under `--mcp` — and returns its input *unchanged*, so `$big | inspect` dumps the whole value into the tool result. It is the flood trap wearing the name you would reach for. For "what is this" use `dataspection`'s `shape` (see [`nu-skills read dataspection`](dataspection.md)); the builtin is left unshadowed on purpose (see [`nu-skills read appendix/inspect`](appendix/inspect.md)).
- **`schema` (dataspection) shadows SQLite's `schema`** while the module is in the overlay. Ours profiles a population (`$x | schema`); the builtin shows a SQLite database schema. Prefer [`nu-skills read dataspection`](dataspection.md) for the drill loop.
- **`metadata` (builtin) vs `meta` (dataspection)**: `metadata` returns *pipeline* metadata — `{span}`, plus `source` on a live pipeline — and is **stripped when a value lands in `$history`**. `meta` returns the provenance record this layer stamps onto its own results (`{verb, at, tag?, …}`). Similar names, unrelated data.
- **Stdio output**: Bare `print "text"` in stdio MCP drops output. Return values implicitly or use `print -e "stderr msg"`.
- **Result retrieval**: Access truncated MCP output buffers via `$history.0`, `$history.1`.
