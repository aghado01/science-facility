Reasonable instinct, and the codebase's own conventions plus PowerShell's class quirks make the answer "yes in three places, no in one, and never at a module boundary." Assessment:

**Where a class earns its place (state + an invariant to protect, or a hot method):**

- **`Layout`** (in `rs.core.container`) — the strongest case. The whole point of the container brief is *one grammar site*: header row, `Measure-Row`, `Render-Row`, `Measure-Content`/`Encode-Content` must share one column table and one codec table. A class makes that structural rather than disciplinary — the table is instance state, the three callers are methods on it. Bonus that matters here: PS class method calls are roughly an order of magnitude cheaper than function invocations, and `MeasureRow` runs once per entry across the corpus. That's the hot path.
- **`ShardWriter`** (in `rs.core.serialize`) — genuinely stateful and sequential: open stream, cursor, header written, rows appended, receipt accumulated, close. `Open / WriteHeader / WriteRow / Close` with the cursor as instance state is cleaner than threading `[ref]` cursors or a state hashtable through functions.
- **Small data holders inside the packer** — a `Bin` with `Fill`, `Count`, `Items[]` is a struct-shaped class; fine and cheap.

**Where I'd keep a function:**

- **The packer's public surface.** `(sizes[], headerBytes, quota, tolerance, orderStrict, maxFiles) → assignment` is a pure function over arrays; a class buys nothing except a place to hang helpers, and it costs the tests a `using module`. Strict vs flexible is two internal functions and a switch, not a strategy hierarchy. Keep it callable from a synthetic-vector test with zero ceremony.
- **Manifest** — model build + template expand are transformations over values; the LTS template engine is already function-shaped and adapts fine.
- **Plan / receipt / IR** — property bags (`PSCustomObject`/`[ordered]`) per house convention, because `contracts.tests` reads them against `schema/*.json` and because they cross module boundaries.

**The PowerShell-specific costs to design around** (all real, all avoidable if the types stay internal):

- Types don't cross `Import-Module`; a consumer that wants to *name* the type needs `using module` with a literal path as its first statement, and class definitions don't reliably reload with `-Force` — a known dev/test friction. Passing an *instance* as an opaque object works everywhere.
- Class methods don't honor `-Verbose`/preference variables the way functions do, can't stream to the pipeline, need explicit `return`.
- None of the ISS/runspace pain applies — export runs in the main session, unlike processors.

So the pattern I'd recommend: **class internal, functions at the boundary.** `rs.core.container` defines `Layout` and exports `New-Layout` (returns the instance) plus thin `Measure-Row` / `Render-Row` / `Measure-HeaderRow` wrappers that delegate to methods — shards and serialize call functions and pass the layout as an opaque object; no `using module` anywhere outside the defining file; tests stay plain-PS. Same for `ShardWriter` inside serialize (`New-ShardWriter` or just an internal `[ShardWriter]::new()` in the emission loop, never exported). The packer stays a function with `Bin` as a private helper type.

That gives you the state encapsulation where state actually exists, keeps the god-object concern at bay (each class owns one thing's state, and instances evaporate with the run), and doesn't fight the module/contract conventions already in place.