11:43 PM, 8/16/2026


doccer
 provides the exact mathematical blueprint for this architecture.

Even without making C# doccer a runtime dependency for Node-based mdnav, we can port its interval algebra, mask mechanics, and carrier discipline directly into mdnav's ESM engine.

Looking at 

SpanSet.cs
, 

GapCadence.cs
, and 

RewriteMaterialization.cs
, the structural patterns map onto mdnav with precision:

1. The Core Port: Normalized Interval Sets (SpanSet)
In 

SpanSet.cs
, a SpanSet is a normalized, sorted list of disjoint half-open intervals $[s_i, e_i)$ where $e_i < s_{i+1}$.

In mdnav.mjs, we replace loose regex slicing with $O(N + M)$ two-pointer interval operations:

javascript
class SpanSet {
  constructor(spans = []) {
    this.spans = SpanSet.normalize(spans);
  }
  // Linear O(N + M) two-pointer intersection
  intersect(other) {
    const out = [];
    let i = 0, j = 0;
    while (i < this.spans.length && j < other.spans.length) {
      const a = this.spans[i], b = other.spans[j];
      const s = Math.max(a[0], b[0]), e = Math.min(a[1], b[1]);
      if (s < e) out.push([s, e]);
      if (a[1] < b[1]) i++; else j++;
    }
    return new SpanSet(out);
  }
  // Linear O(N + M) set subtraction (masking)
  subtract(other) {
    const out = [];
    let j = 0;
    for (const [start, end] of this.spans) {
      let cursor = start;
      while (j < other.spans.length && other.spans[j][1] <= cursor) j++;
      let scan = j;
      while (scan < other.spans.length && other.spans[scan][0] < end) {
        const cut = other.spans[scan];
        if (cut[0] > cursor) out.push([cursor, Math.min(cut[0], end)]);
        cursor = Math.max(cursor, cut[1]);
        if (cursor >= end) break;
        scan++;
      }
      if (cursor < end) out.push([cursor, end]);
    }
    return new SpanSet(out);
  }
  union(other) { /* ... merges and normalizes ... */ }
  complement(totalLen) { return new SpanSet([[0, totalLen]]).subtract(this); }
}
2. Hierarchical Masking: The Multi-Layer Collector
With SpanSet, the environment hierarchy becomes deterministic:

Source Buffer [0, Len)
 ├── Layer 0: Primary Inert Masks
 │    ├── FrontmatterMask:   [0, endOfFrontmatter)
 │    ├── CodeFenceMask:     ∪ [fenceStart, fenceEnd)
 │    ├── HTMLBlockMask:     ∪ [tagOpenStart, tagCloseEnd)
 │    └── MathBlockMask:     ∪ [$$start, $$end)
 │
 ├── Layer 1: Structural Scan (Mask-Aware)
 │    Query Space: Total \ PrimaryInertMasks
 │    → Discover Headings (H1..H6), Setext, Thematic Breaks (---, ***, ___)
 │
 └── Layer 2: Sub-span Content & Noise Census
      ├── Blockquotes, Lists, Tables, Paragraphs
      └── Inline Noise: Data-URIs, Presigned URLs, Inline Tags
Why this resolves the fence-blindness and multi-line problems:
Zero leakage into code: Headings and noise scanners only search within Total \ CodeFenceMask. Fenced code can never emit false headings or be corrupted by noise cleaners.
Zero leakage into HTML: Multi-line HTML blocks (<div...>, <details>, <!-- -->) form solid intervals. Slicing or unwrapping them is a pure interval difference.
3. Materialization: Projection via Slice Programs (Doccer RewritePlan style)
Instead of mutating strings with regex .replace() or string concatenation that can shift offsets, materialization uses pure buffer slicing:

Section Selection: Anchor $H0002$ defines a bounding span $[S, E)$.
Filter Construction: If caller requests strip: ["html", "data-uri"], construct ExclusionMask = HTMLMask ∪ DataUriMask.
Execution: Compute ActiveSpans = SpanSet([[S, E]]).subtract(ExclusionMask).
Hydration: Slices from the immutable Buffer are concatenated: $$\text{Output} = \bigoplus_{[s, e] \in \text{ActiveSpans}} \text{Buffer}[s \dots e)$$
If an elided span is large ($\ge 1 \text{ KiB}$), an addressable placeholder <!-- mdnav: elided data-uri 404 KiB @s..e --> is injected into the stream at that gap.
Byte fidelity is 100% guaranteed for all unstripped prose and code.
4. Cadence as a Geometric Metric (Doccer GapCadence style)
In 

GapCadence.cs
, cadence is measured over gap sequences $\Delta_k = \text{start}_{k+1} - \text{start}_k$:

$$\text{Mean} = \mu = \frac{1}{N}\sum \Delta_k, \quad \sigma = \sqrt{\frac{1}{N}\sum (\Delta_k - \mu)^2}, \quad \text{CV} = \frac{\sigma}{\mu}$$

$\text{CV} < 0.6 \land \text{SpanCoverage} > 0.6 \implies$ Delimiter Candidate (evenly spaced across document).
$\text{CV} > 1.0 \implies$ Localized burst / decoration (pull quotes, aside blocks).
This stays purely observational and domain-neutral.

5. Architectural Blueprint for mdnav MCP
Adopting doccer's patterns, mdnav can be structured into clean, focused modules under d:\aghado01\science-facility\mcp\mdnav:

d:\aghado01\science-facility\mcp\mdnav\
 ├── package.json              (zero runtime dependencies, Node >= 18)
 ├── server.mjs                (MCP stdio protocol runner: tools/list & tools/call)
 ├── cli.mjs                   (CLI entry point for console & shell scripts)
 ├── core/
 │    ├── span-set.mjs         (Interval algebra: union, intersect, subtract, complement)
 │    ├── cadence.mjs          (Gap statistics, CV, and delimiter candidate calculation)
 │    ├── scanner.mjs          (O(N) line table, primary masks, ATX/Setext/Breaks, block elements)
 │    ├── noise.mjs            (Fence-masked data-uri, HTML, presigned URLs)
 │    ├── indexer.mjs          (Document index, virtual database store, mtime/digest caching)
 │    └── materializer.mjs     (Declarative slice programs & projection stream)
 └── test/
      └── acceptance.mjs       (Tests covering interval math, fence masking, MCP tools, and CLI)
This makes mdnav a robust, virtual Markdown database engine that powers high-efficiency MCP tool calls for general agent coding while providing the underlying bedrock for doc-dive.