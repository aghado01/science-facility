
The bottlenecks in [`rs.pm.strip.ps1`](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/rs.pm.strip.ps1) have been resolved.

### Changes Made

1. **Guarded Heredoc Detection & Fast-Path Marker Search** ([`rs.pm.strip.ps1:L58-L86`](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/rs.pm.strip.ps1#L58-L86)):
   - Constrained heredoc declaration recognition with `(?<![\w\$@%<>-])<<~?...` and word boundaries on bare identifiers `\\?([a-zA-Z_]\w*)\b(?![''\w])`. This stops `<<` inside `q{<<Didn't match rule>>}` and bitshift operators (`$a << 2`) from triggering false heredocs.
   - Added an ordinal vectorized substring check `if ($text.IndexOf($marker, $bodyStart, [System.StringComparison]::Ordinal) -ge 0)` before creating and executing the multiline EOF regex, eliminating hundreds of wasteful full-file scans when markers are not present.

2. **Replaced $O(N \times M)$ String Allocations with Incremental Line Counting** ([`rs.pm.strip.ps1:L163-L177`](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/rs.pm.strip.ps1#L163-L177)):
   - Replaced `($view.Substring(0, $s) -split "`n").Count` with a sequential running newline counter using `.IndexOf("`n", $lastOffset, $s - $lastOffset)`.
   - Avoids allocating millions of temporary substring and array objects in the managed heap on large files.

3. **Vectorized Character Array Masking** ([`rs.pm.strip.ps1:L38-L56`](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/rs.pm.strip.ps1#L38-L56), [`L133-L144`](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/rs.pm.strip.ps1#L133-L144)):
   - Replaced character-by-character PowerShell `for` loops with native `[System.Array]::Fill` for single-line spans and an `IndexOf("`n")`-segmented block fill helper (`_MaskSpan`) for multi-line literals and heredocs.

4. **Unit Tests & Edge Cases** ([`rs.pm.strip.tests.ps1:L226-L232`](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/tests/rs.pm.strip.tests.ps1#L226-L232)):
   - Added test assertions verifying `<<` inside `q{...}` trace literals and `$a << 2` bitshifts are not falsely parsed as heredocs and do not suppress stripping of subsequent comments.

---

### Verification & Benchmark Results

- **Unit Tests:** [`rs.pm.strip.tests.ps1`](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/processors/tests/rs.pm.strip.tests.ps1) passed **92 / 92** tests.
- **Microbenchmark on 2.68 MB [`MathGrammar.pm`](file:///D:/aipithicus/LaTeXAI/lib/LaTeXML/MathGrammar.pm):**
  - **Before:** Exceeded 180,000 ms (timed out > 3 min; killed by Colonel's 90s timeout).
  - **After:** Completed in **3,076 ms** (3.0 seconds).
- **Full End-to-End Pipeline Execution:**
  Executed [`rs.core.user.ps1`](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/rs.core.user.ps1) against `D:\aipithicus\LaTeXAI\lib\LaTeXML`:
  ```
  reposnapshot: 111 entries → 22 shards, 4596953 bytes
  RunStamp       : 20260907_150331
  Root           : D:\aipithicus\LaTeXAI\lib\LaTeXML
  OutDir         : D:\aipithicus\LaTeXAI\lib\LaTeXML\.snapshot\20260907_150331
  TreePath       : D:\aipithicus\LaTeXAI\lib\LaTeXML\.snapshot\20260907_150331\LaTeXML_tree.md
  EntryCount     : 111
  ShardCount     : 22
  TotalBytes     : 4596953
  ```
  The full crawl, membrane filter, multi-threaded ingest/processing, sharding, and serialization ran to completion cleanly with zero worker timeouts.

*(Note: When running your command, remember to pass `-ConfigPath 'D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/user-config.json'` without the trailing `\Post`)*.