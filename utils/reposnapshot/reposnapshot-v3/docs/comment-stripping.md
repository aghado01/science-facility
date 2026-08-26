# Comment Stripping & AST Partitioning

Language-specific processors (`rs.ps.strip.ps1` and `rs.cs.strip.ps1`) strip comment tokens while preserving source code semantics.

## PowerShell Stripper (`rs.ps.strip.ps1`)

### Parse-Boundary Partitioning

`_SplitCommentPopulation` partitions parser tokens into:
- **`Native` Comments**: Regular `#` and `<# #>` tokens routed to classification.
- **`Derived FrontMatter`**: `#Requires` statements and line-1 shebangs (`#!`) are promoted to non-strippable metadata objects and are never removed.

### Classification Kinds

- `BlockComment`: `<# ... #>` outside function/type definitions.
- `DocString`: `<# ... #>` inside function/type definitions.
- `CommentBlock`: Run of $\ge 2$ consecutive standalone `#` lines.
- `LineComment`: Isolated single standalone `#` line.
- `InlineComment`: `#` comment trailing on a line containing code.

### Tolerance-First Execution & Regex Fallback

The AST tokenizer executes even when syntax errors exist. Regex fallback engages only when unterminated here-strings swallow the tail of the file. Here-strings are masked with private-use characters during fallback processing.

## C# Stripper (`rs.cs.strip.ps1`)

Uses regex-based span classification for `/* ... */`, `///` doc strings, `//` standalone lines/blocks, and `//` trailing comments.
