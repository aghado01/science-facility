No — that was me proposing a *convention*, not describing a nushell feature, and I should have been clearer. Nushell has nothing like PowerShell's `#Requires` statement (which the engine actually parses and enforces).

What nushell *does* have that's adjacent:

- **Attributes** (`@example`, `@search-terms`, `@category`, `@deprecated`) — parser-recognized annotations on `def`, since ~0.102. You can define custom ones (`def "attr requires" [...]`), and they're visible via `scope commands`, but nothing enforces them at load time — they're metadata for `help`/introspection.
- **Doc comments** — the contiguous `#` block above a `def` becomes its `help` text. Pure convention, no semantics.
- **Runtime checks** — `which tokei | is-empty` inside the command body, which is how a couple of these modules actually handle it (e.g. `with_externals` just says it in a comment; `jc` shells out and lets it fail).

So the honest options for "this module needs an external binary" are:

1. **Comment convention** (`# requires: tokei`) — `nu-modules` regexes it into a column. Zero engine support, cheap, invisible to nushell itself.
2. **Custom attribute** (`@requires tokei` on the exported command) — parser-recognized, shows up in `scope commands` for whatever introspection replaces the regex, and could be *checked* by a helper that iterates commands and `which`es each dependency. More honest, slightly more work, and it's on the command not the module.
3. **`export-env` guard** — module refuses to load / warns if the binary is missing. Enforcement, but heavy-handed for a discovery library.

I'd lean 2 if `inspect` moves to `scope commands` anyway (attributes come for free then), 1 if it stays regex-based. Sorry for the ambiguity — do you want to go a particular direction on that before deciding the tiering?

Yes — `ast` is a built-in. Let me check what it gives on this build rather than describe from memory:

Yes, and there are three distinct surfaces, each useful for a different job:

**1. `ast <code>` — the parser's tree, as data.** Three modes:
- `ast --flatten` → a token table: `content` / `shape` (`shape_internalcall`, `shape_flag`, `shape_string`, `shape_signature`, `shape_closure`, …). Note above how `export def --env "foo bar" [x: int]` comes out already tokenized — the flag, the quoted name, and the signature are *separate rows with types*. That alone kills both `inspect` regex bugs (flag-as-name, quoted names) with no regex at all.
- `ast` (default) → NUON string of the full tree (`block`, plus `error` if it didn't parse).
- `ast --json` → same tree as JSON: full `signature` records (`name`, `description`, `required_positional`, `named`, `input_output_types`…). Heavier, but it's the real thing.
- Also `nu --ide-ast <file>` from the CLI — same data for tooling outside the session.

**2. `scope commands` / `scope modules` — the *live* engine state.** For anything already `use`d, this is the authoritative view: name, `description` (first doc line — cleanly, no last-line-of-paragraph problem), `signatures` per input type with parameter names/shapes/descriptions/defaults, and an `attributes` column (empty above, but that's where `@requires` would surface if we adopt custom attributes).

**3. `view source` / `view span` / `view ir` — the other direction.** Source text or compiled IR for a given definition — handy for `nu-modules read` at command granularity rather than file granularity.

**Implication for `nu-modules inspect`:** the right design is a two-path approach —
- try `use <mod>` in a throwaway scope → read `scope commands` filtered to that module (parser-accurate, includes attributes);
- if the module won't load (e.g. `after` on Windows), fall back to `ast --flatten` on each file → walk for `export def` tokens and pull the following `shape_string`/bare-word name + `shape_signature`. Still no hand-rolled regex.

The one wrinkle: `use` inside a `def` scopes the import to that block, which is what we want — but a module with a heavy `export-env` (e.g. `background_task` shelling to `pueue`) will run it. Cheap to guard with `try`.

Also settles the earlier question: with `scope commands` giving `attributes` for free, custom `@requires` beats a comment convention — same effort, and it's parser-recognized.
