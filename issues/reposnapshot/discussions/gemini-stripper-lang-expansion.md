To expand `reposnapshot`'s language-specific stripping battery to **JavaScript/TypeScript** and **Python**, we can build upon the foundations established in [`rs.cs.strip.ps1`](file:///d:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/rs.cs.strip.ps1) and [`rs.ps.strip.ps1`](file:///d:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/rs.ps.strip.ps1).

Here is the architectural sketch and design analysis for bringing robust, best-effort regex strippers to JS/TS and Python under the harmonized 6d mutator contract.

---

### 1. Unified Comment Ontology Mapping

The goal is to maintain semantic parity across languages while respecting each language's idioms and frontmatter requirements.

| Comment Kind | JavaScript / TypeScript | Python | Default Action |
| :--- | :--- | :--- | :--- |
| **`FrontMatter`** | Shebang (`#!/usr/bin/env node`), TS Triple-slash directives (`/// <reference ... />`, `/// <amd-...>`) | Shebang (`#!/usr/bin/env python3`), PEP 263 encoding (`# -*- coding: utf-8 -*-`) | **Never Strip** |
| **`DocString`** | JSDoc / TSDoc (`/** ... */`) | Top-level module, class, and function triple-quoted strings (`"""..."""` / `'''...'''`) | **Strip** |
| **`BlockComment`** | Multi-line `/* ... */` on standalone lines (not `/**`) | Standalone multi-line triple-quoted string blocks (when not attached as docstrings) | **Strip** |
| **`InteriorComment`**| `/* ... */` embedded between code on a single line | N/A (Python does not have interior block comment tokens) | **Keep** |
| **`CommentBlock`** | Contiguous run of 2+ standalone `//` lines | Contiguous run of 2+ standalone `#` lines | **Strip** |
| **`LineComment`** | Single isolated standalone `//` line | Single isolated standalone `#` line | **Strip** |
| **`InlineComment`** | `//` following code on the same line | `#` following code on the same line | **Keep** |

---

### 2. Lexical Hazard Mitigation: The Masking Strategy

Because regex parsers do not have a full grammar table, the primary failure mode is **false-positive comment detection inside string literals, template strings, and regex literals**.

Following the private unicode masking pattern used for PowerShell here-strings (`$HS_OPEN = [char]0xE000` in [`rs.ps.strip.ps1`](file:///d:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/rs.ps.strip.ps1#L101-L102)), we can establish a pre-pass mask table:

```mermaid
flowchart LR
    Raw[Raw Ingested Text] --> PrePass[1. String & Literal Masking]
    PrePass --> Classify[2. Regex Comment Span Classification]
    Classify --> Filter[3. Filter Spans by Config.Operations]
    Filter --> Merge[4. Merge Spans & Strip]
    Merge --> Unmask[5. Restore Masked Literals]
    Unmask --> Bag[6. Copy-Bag with Processing Trail]
```

#### A. JavaScript / TypeScript Masking Challenges
1. **Template Literals (Backticks `` `...` ``)**: Can span multiple lines and contain `${...}` interpolation expressions.
   - *Mask Pattern*: `` `(\\.|[^`\\])*` ``
2. **Standard Strings**: `'...'` and `"..."` with escaped quotes (`\'`, `\"`, `\\`).
3. **Regex Literals (`/.../g`) vs Division (`/`)**:
   - A naive comment scanner may mistake `/http:\/\/example.com\//g` for a line comment `//`.
   - *Heuristic Mask*: Match `/.../` only when preceded by operators, punctuation, or statement keywords (`=`, `(`, `[`, `,`, `:`, `!`, `&`, `|`, `?`, `return`, `yield`, `await`, `typeof`).

#### B. Python Masking Challenges
1. **Triple-Quoted Strings (`"""` and `'''`)**:
   - Can be prefixed with `r`, `u`, `f`, `b`, `rf`, `fr`, `rb`, `br` (case-insensitive).
   - In Python, triple quotes serve as *both* strings and docstrings/block comments.
   - *Strategy*: Distinguish **assigned/argument strings** (e.g. `query = """SELECT ..."""` or `func("""arg""")`) from **docstrings/statement blocks** by checking preceding code tokens on that line.
2. **Single-line String Literals**:
   - Prefixed `'...'` or `"..."` strings with escape handling (`\n`, `\'`, `\"`, `\\`).

---

### 3. JavaScript / TypeScript Stripper (`rs.js.strip` & `rs.ts.strip`)

JS and TS can share the same core engine or be specialized:

#### Regex Classification Logic:
1. **FrontMatter**:
   - Line 1 Shebang: `\A#![^\n]*\n?`
   - Triple-Slash Directives (TS): `(?m)^[ \t]*///[ \t]*<(?:reference|amd-|ts-)[^\n]*\n?`
2. **DocStrings (`/** ... */`)**:
   - Pattern: `/\*\*(?!\/)[\s\S]*?\*/`
   - Distinguished from standard block comments by the leading double asterisk `/**`.
3. **Block / Interior Comments (`/* ... */`)**:
   - Standalone vs Interior discrimination using the lookbehind/lookahead whitespace scan from [`rs.cs.strip.ps1`](file:///d:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/rs.cs.strip.ps1#L55-L64):
     - If only whitespace precedes on the line and only whitespace succeeds until newline $\rightarrow$ `BlockComment` (strip includes line leading indent & trailing newline).
     - Otherwise $\rightarrow$ `InteriorComment` (strip only the token).
4. **Line / Block Runs / Inline Comments (`//`)**:
   - Negative lookahead `//(?!/)` (or negative lookahead for TS directives).
   - Classify into `InlineComment` (if code precedes on line) vs standalone.
   - Standalone runs with `LineNum[i] == LineNum[i-1] + 1` promoted to `CommentBlock`.

---

### 4. Python Stripper (`rs.py.strip`)

Python comment syntax is minimal (`#`), but docstrings and block triple-quotes require careful structural heuristics.

#### Regex Classification Logic:
1. **FrontMatter**:
   - Line 1 Shebang: `\A#![^\n]*\n?`
   - Encoding Pragma (Lines 1–2): `(?m)^[ \t]*#[ \t]*-\*-[ \t]*coding:[ \t]*[-\w.]+[ \t]*-\*-[^\n]*\n?` or `(?m)^[ \t]*#[ \t]*coding[=:][ \t]*[-\w.]+[^\n]*\n?`
2. **DocStrings vs Data Strings**:
   - Match standalone `"""..."""` or `'''...'''` blocks:
     - Module-level docstring: Starts at index 0 (or immediately after shebang/encoding comments).
     - Definition docstrings: Follows `def ...:\s*` or `class ...:\s*`.
     - Standalone triple-quoted statements (not preceded by `=`, `(`, `[`, `,`, `return`, `yield`, or identifier).
3. **Line Comments & Comment Blocks (`#`)**:
   - Single standalone `#` line $\rightarrow$ `LineComment`.
   - Run of 2+ standalone `#` lines $\rightarrow$ `CommentBlock`.
   - `#` preceded by non-whitespace $\rightarrow$ `InlineComment`.

---

### 5. Robustness & Tolerance on Broken Code

Because RepoSnapshot ingests arbitrarily broken or WIP code:
- **Unclosed Strings**: If a file has an unclosed `'` or `"`, string masking should fail-open without hanging (e.g. bounded regexes with line boundaries or fallback to unmasked mode).
- **Unclosed Block Comments**: `/*` without matching `*/` or unclosed `"""` should match to EOF rather than throwing an exception.
- **Audit Receipt**:
  ```powershell
  @{
      Processor      = 'StripComments'
      Implementation = 'rs.py.strip'   # or 'rs.ts.strip' / 'rs.js.strip'
      Operations     = @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments')
      FallbackMode   = 'regex'
  }
  ```

---

### 6. Sequencer Routing & Extension Mapping

In [`default_sequencer.json`](file:///d:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/default_sequencer.json), the `StripComments` slot can expand its `Routing` table:

```json
{
  "StripComments": {
    "Group": 2, "Rank": 0, "Default": false,
    "Requires": ["file_read"],
    "Routing": [
      { "File": "rs.ps.strip.ps1", "Extensions": ["ps1", "psm1", "psd1"] },
      { "File": "rs.cs.strip.ps1", "Extensions": ["cs", "csx"] },
      { "File": "rs.js.strip.ps1", "Extensions": ["js", "mjs", "cjs", "jsx"] },
      { "File": "rs.ts.strip.ps1", "Extensions": ["ts", "mts", "cts", "tsx", "d.ts"] },
      { "File": "rs.py.strip.ps1", "Extensions": ["py", "pyw", "pyi"] }
    ]
  }
}
```

This ensures heterogeneous runs across the [`tests\languages`](file:///d:/aghado01/science-facility/utils/reposnapshot/tests/languages) test battery (containing `.js`, `.mjs`, `.ts`, `.d.ts`, `.py`, `.cs`, `.ps1`) automatically route each file to its respective processor under the unified `StripComments` capability slot.

---

### Discussion & Next Steps

When you are ready to proceed, we can:
1. **Choose single vs split implementation for JS/TS**: Determine whether to use a single unified `rs.js.strip.ps1` with TS awareness or distinct `rs.js.strip.ps1` and `rs.ts.strip.ps1` scripts.
2. **Refine Docstring vs Multi-line String heuristics in Python**: Settle on the exact boundaries for classifying triple-quotes as `DocString` vs `BlockComment` vs literal data string.
3. **Draft processor scripts and standalone test suites**: Mirroring the test structure in [`rs.cs.strip.tests.ps1`](file:///d:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/tests/rs.cs.strip.tests.ps1).