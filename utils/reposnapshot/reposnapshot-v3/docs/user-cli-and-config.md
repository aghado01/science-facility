# User CLI & Configuration Orchestration (`rs.core.user.ps1`)

`rs.core.user.ps1` serves as the high-level, opinionated CLI entry point for the RepoSnapshot V3 pipeline. It coordinates the full end-to-end lifecycle:

$$\text{Crawl} \longrightarrow \text{Membrane} \longrightarrow \text{Ingest} \longrightarrow \text{Assemble} \longrightarrow \text{Resolve-Layout} \longrightarrow \text{New-ShardPlan} \longrightarrow \text{Invoke-Serialize} \longrightarrow \text{New-Manifest}$$

---

## 1. Configuration Resolution & Precedence

Settings arrive from three distinct sources in a strict priority hierarchy:

1. **Explicit CLI Parameters**: Direct command-line arguments (e.g. `-Root . -SelectionPatterns '*.ps1'`).
2. **Configuration Object / File**:
   - `-Config <hashtable|object>`: In-line programmatic configuration with zero file I/O.
   - `-ConfigPath <path>`: Explicit JSON configuration file.
3. **Auto-Discovered Default (`user-config.json`)**:
   - `user-config.json` located beside `rs.core.user.ps1` is automatically loaded if no explicit `-Config` or `-ConfigPath` is provided.
   - If `user-config.json` is not present, it is silently skipped.

### Precedence Model
$$\text{CLI Flags} > \text{Config (-Config or -ConfigPath)} > \text{Built-in Defaults}$$

### Mutual Exclusivity
Passing both `-Config` and an explicit `-ConfigPath` throws an immediate validation error.

---

## 2. Parameter Validation & Binding Mechanics

### Root Parameter Binding
`-Root` deliberately omits PowerShell's `[Parameter(Mandatory)]` attribute. In PowerShell, `Mandatory` causes the engine to prompt interactively *before* the script body runs, which would prevent an unbound `-Root` from being populated by `user-config.json` or `-Config`. Instead, container existence and presence checks occur immediately following config merge.

### Attribute Re-validation
PowerShell re-evaluates `[ValidateSet]` and `[ValidateRange]` attributes upon variable reassignment within the script scope. As a result, invalid enum or range values supplied in JSON configs fail fast with native PowerShell binding errors at assignment time without requiring redundant manual assertions.

---

## 3. Processor Chain Selection

Two modes, not interchangeable. The model is [Sequencing & Routing](sequencing-and-routing.md).

- **Canon (default):** `-IncludeProcessors` (or `"IncludeProcessors"` in configuration) is a **set** of sequencer slots — `StripComments`, `Indentation`, `Whitespace`, `ContentMetadata`. Array position carries no meaning; `Group`/`Rank` in `processors/default_sequencer.json` own order. `file_read` arrives via `Default` / `Requires`. A routed slot resolves per file extension; a file no route claims still runs every other stage.
- **Verbatim:** `-RunVerbatim -Processors` is a literal ordered list of processor **files** (stems, e.g. `rs.ps.strip`), identically for every file, with nothing routed. `-Processors` without `-RunVerbatim` is refused, and `-RunVerbatim` without `-Processors` is refused.

A `-Processors` entry is either a bare string key (defaults from `processors/configs/<Key>.json`) or `@{ Key; Config }`. All `processors/*.ps1` files except `chain_executor.ps1` and `bag_helpers.ps1` are registered at runtime; an unknown key fails fast.

The three chain cautions (`rs.whitespace` omitted, `rs.content_meta` not last, `Columns` requests `content_meta` with no measuring step) print **only** under verbatim. Under the sequencer they are compiler guarantees.

---

## 4. Output Conventions & Idempotence

1. **Default OutRoot**: `<Root>/.snapshot/<runstamp>/`.
2. **Collision Avoidance**: If multiple runs execute within the same second, output directories are automatically suffixed (e.g. `<runstamp>_2`).
3. **Membrane Isolation**: `.snapshot/` is included in default ignore rules (`IgnoreDefaults`), ensuring reruns over the same root never accidentally ingest previous snapshot runs.
