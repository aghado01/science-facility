# FileSystem Crawler & Graph

The crawler (`rs.core.crawler.psm1`) performs an exhaustive, greedy Breadth-First Search (BFS) over a root directory to produce a normalized filesystem graph.

## Design Doctrines

1. **Free Fact Stamping**:
   The crawler collects facts available without file reads (size in bytes, timestamps, filesystem attributes, paths). Content reads and hashing are left to downstream stages.
2. **Graph vs. Rollups**:
   - `Graph`: Map of `NodePath` $\to$ Node (`Files[]`, `NodeDepth`, `AbsolutePath`).
   - `Rollups`: Separate metadata layer recording aggregate statistics (`SubtreeDirCount`, `SubtreeFileCount`, `SubtreeBytes`) conditioned on the walk phase (`walked`).
3. **Path Invariants**:
   - `RootPath`: Absolute path with trailing `/`.
   - `RelativePath`: Root-relative path with forward slashes and no leading slash (e.g. `src/index.ts`).
   - `NodePath`: Directory portion with a trailing slash (e.g. `src/`), or empty string `""` for the root.
