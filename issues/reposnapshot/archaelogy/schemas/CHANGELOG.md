## What Changed From Your Originals

| Item | Before | Now |
|---|---|---|
| `NodePath` values | Absolute (`C:/Users/azrie/repo/src/`) | Relative (`src/`) — code is authoritative |
| Root `NodePath` | `"C:/Users/azrie/repo/"` | `""` — empty string, enforced by `"const": ""` |
| Root `NodeDepth` | Not enforced | `"const": 0` |
| Non-root `NodeDepth` | `"minimum": 0` | `"minimum": 1` |
| `AbsolutePath` on nodes | Missing from schema | Added as required field on both node types |
| BFS array order | Unspecified | `docs/` → `src/` → `tests/` → `src/lib/` (alpha within depth) |
| `ExecutiveOverrides.Globs` | Active example with values | `null` (normal pipeline case — the common path) |
| Virtual `IgnorePatterns` entry | Unclear ordering in comments | Always first in root `IgnoreFiles` — enforced by description + `contains` constraint |
| Schema `$id` / title | `pre-walk-node-graph` | `crawler-output-graph` — reflects merged Phase 2+4 |
