# check out file read for the NUL byte check

Good, now I've actually read it. Here's what file-read.ps1 actually does:

The NUL check is $bytes -contains 0 — it reads the entire file as a byte array via [System.IO.File]::ReadAllBytes($path), then checks whether any byte in that array is zero before doing anything else. If it finds one, it short-circuits immediately with ReadError = 'BinaryOrNulContent' on the shallow-cloned item and returns — no string allocation, no encoding, nothing downstream gets it.

A few things worth noting about the actual implementation:

ReadAllBytes for the NUL check means you're reading the full file into memory before the check fires. The defense is correctly positioned in the pipeline (before string allocation and any processing), but you're still paying the full I/O cost. The alternative would be , then a second full read — which avoids loading a large binary into memory but costs an extra syscall on the files that pass. For the expected case (repo of source files), ReadAllBytes is simpler and the rare binary slip-through doesn't matter much since the filesystem filter should have caught it already. But for repos with large vendored assets that somehow bypass the extension blacklist, ReadAllBytes on a 50MB .bin file with a non-obvious extension would be the expensive path.

**FileStream.Read with a 512-byte buffer just for the probe is the safest. But the encoding path is clean e.g. ReadAllBytes → NUL check → UTF8.GetString() on the same buffer, no second file open is fine with the max file size filter layered ontop. **

**The size gate fires before ReadAllBytes if Config.MaxSizeBytes is set — so oversized files don't even get read. That's the right order-> moving out into ingest**

rs-psstrip is genuinely two-tier — AST path with Parser::ParseInput for well-formed PS, full token classification into BlockComment/DocString/CommentBlock/LineComment/InlineComment kinds using the actual token stream and function/type body extents for the <# #> distinction. The regex fallback fires only when $errors.Count -gt 0 and it logs ParseErrors and FallbackMode = 'regex' on the output envelope. The regex fallback block for block comments in PS has an empty regex body (?s) which looks like it may be a stub or the comment-strip stripped the pattern out of the snapshot itself — worth checking in the live file.

# the gold standard for me would be AST for every language eventually, but this is not urgent nor very practical short term. you can see me recycling the regex fallback pattern for comment stripping in rs-csstrip

Right — `rs-csstrip` is entirely the regex fallback pattern, just adapted for C-family syntax (`/* */`, `///`, `//`). It's the same span-collection → sort → merge → StringBuilder reconstruction skeleton as the PS regex fallback path, which makes sense: you wrote the fallback pattern once, got it working, and reused it as the basis for the C-strip processor since there's no equivalent of `Parser::ParseInput` readily available in PowerShell for C#/JS/etc.

The architectural consequence is that `rs-csstrip` has the same fundamental limitation as the PS regex fallback — it's context-blind. The two cases where this bites:

**Strings containing comment syntax.** `"// this is not a comment"` or `/* inside a string */` — the regex has no way to know it's inside a string literal. The `block-comments` path uses `(?s)/\*.*?\*/` which will match inside strings. For source stripping destined for LLM consumption this is probably acceptable noise — a model seeing `` is not meaningfully misled — but it's worth being aware of as a known fidelity gap.

**`//` inside regex literals in JS/TS.** A line like `const re = /https?:\/\//` will have the trailing `//` matched as an inline comment by `$stripInline`'s `$rxInline`. Less common but more structurally wrong since it corrupts the actual code token.

~~The run-detection logic for `comment-blocks` (consecutive standalone comment lines getting the `CommentBlock` classification via `$cbFlags`) is identical between both strippers, which is good — that logic is non-trivial enough that having one canonical implementation would be ideal eventually. When you do add more language strippers the natural refactor is extracting `Get-CommentSpans` as a shared function in `rs.core.internals.psm1` that takes the text and a language descriptor, so each stripper is just a thin wrapper that calls it with the right patterns.~~

The AST roadmap per language is roughly: PowerShell (done), C#/Roslyn (practical but requires adding a Roslyn reference to the ISS, which complicates the `Bare`/`Core`/`Full` preset model), TypeScript/JS (Tree-sitter has a .NET binding but it's not mature), Python (same). For the medium term the regex approach with the known limitations is the right tradeoff given the use case — LLM payloads tolerate minor syntactic noise far better than a compiler would.

# i should probably introduce some kind of masking to handle exceptions like that, but for now ill just be careful with comments in my code. i eventually want to implement ps-native parsers for each language to do the AST parsing in-house

That's the right long-term direction, and it sidesteps the Roslyn/Tree-sitter dependency problem entirely — if the parsers are PS-native they load cleanly into any ISS preset without needing external assemblies registered.

The masking approach for the interim is worth sketching even if you don't implement it now. The natural seam is between `file-read` and whichever strip processor runs — a `mask` processor that scans for string literals and regex literals, replaces their interiors with a neutral placeholder (e.g. repeated `\x01` bytes at the same length to preserve offsets), runs the strip pass, then unmasks. Since all processors pass the item through as a `pscustomobject` with `Text`, a `mask`/`unmask` processor pair would slot cleanly into the chain without touching the strippers at all. The offset-preserving placeholder matters because `rs-indent`'s depth calculations are line-based and a length-changing substitution would corrupt indentation analysis on the same item downstream.

On the PS-native parser direction — the interesting thing is that PowerShell's own `Parser::ParseInput` gives you a model to study. A hand-written recursive descent parser for C-family syntax that only needs to produce a comment token stream (not a full AST) is a much smaller problem than a general parser. You don't need to correctly parse expressions, resolve types, or handle precedence — you only need to correctly track three things: string literal boundaries (including template literals for JS), block comment boundaries, and line comment boundaries. That's maybe 300-400 lines of PS for C-family, and it would eliminate the string-interior false positive problem completely. The PS AST path already proves the pattern works — the output contract is identical, so the chain doesn't care whether the spans came from `Parser::ParseInput` or your own scanner.
