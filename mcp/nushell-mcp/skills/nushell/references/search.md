# `rg` — disciplined search returns

Wrapper occupies `rg` (`--wrapped`). `^rg` is the escape hatch. `help rg` is this contract; `rg --help` is ripgrep's text help (text mode).

Preloaded after `xq` (`config.nu`). PATH is `deps/cli` via `config.nu`. The wrapper calls `process capture rg …`, not ordinary `xq`.

## Command

```
rg [...args]
```

Injects `--json` once if absent. No other flag rewrite. Mode is decided on the **return path**: stdout that parses as rg JSON events is `json`; otherwise `text` (`-l`, `--count`, `--files`, `--help`, `--version`).

## Envelope

```
{ok, mode, n, n_files, elapsed, bytes, truncated, args, error?, tag?, findings?, spine?, text?, meta}
```

- `ok`: exit 0 or 1 (no match is `ok: true, n: 0`). Exit 2 → `ok: false`, short `error`.
- `mode`: `json | text`.
- json census from the `summary` event: `n` = `matched_lines`, `n_files` = `searches_with_match`.
- `bytes`: NUON of the findings table (json) or `stream bytes` of stdout (text), vs `par cap`. A binary capture stream is `ok: false`. Ripgrep `path.bytes` / `lines.bytes` without text is unsupported encoding (`ok: false`), never `match: ""`.
- json: `findings` iff not truncated; `spine` iff truncated. Never both.
- text: `text` iff not truncated; no spine.
- `tag` iff stashed (registry-allocated `rg:<n>` on the envelope). `jobs fetch` that tag; do not predict the suffix.

Findings rows: `{file, line, col?, kind: match|context, match}`. Context has `col: null`. Emission order, not re-sorted.

Spine: `{file, hits}`, hits desc then file asc.

Inside `jobs spawn { rg … }`: never stash; the job row is the quarantine.

Do not cap the live search. Do not call ordinary `xq`. Do not parse `^rg` text when this wrapper exists. Body around a hit: `open $file | lines | slice`.
