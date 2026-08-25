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

## 3. Processor Chain Normalization

The `-Processors` parameter (or `"Processors"` array in configuration) accepts:
- **Bare string keys** (e.g. `'rs-psstrip'`): Automatically resolves defaults from `processors/configs/<Key>.json`.
- **Step descriptor objects** (e.g. `@{ Key = 'rs-indent'; Config = @{ TargetUnit = 4 } }`): Merges caller overrides on top of the JSON defaults.

### Chain Manifest & Guards
1. **Manifest Discovery**: All `processors/*.ps1` files (excluding framework infrastructure `chain-executor.ps1` and `bag-helpers.ps1`) are registered at runtime. Any requested processor key lacking a script file fails fast with known alternatives.
2. **Invariants & Cautions**:
   - **`rs-whitespace`**: Warns if omitted, as its `pad-breaks` op maintains standard token separation for the wire codec.
   - **`rs-content_meta`**: Warns if placed anywhere other than the very tail of the mutator chain, preventing downstream mutators from invalidating computed line/char/word metrics.
   - **`content_meta` Wire Request**: Warns if `content_meta` is enabled in `Columns` but `rs-content_meta` is not in the chain.

---

## 4. Output Conventions & Idempotence

1. **Default OutRoot**: `<Root>/.snapshot/<runstamp>/`.
2. **Collision Avoidance**: If multiple runs execute within the same second, output directories are automatically suffixed (e.g. `<runstamp>_2`).
3. **Membrane Isolation**: `.snapshot/` is included in default ignore rules (`IgnoreDefaults`), ensuring reruns over the same root never accidentally ingest previous snapshot runs.
