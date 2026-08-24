# Sharding & Bin Packing

The sharding stage (`rs.core.shards.psm1`) groups and partitions entries into deterministic, bounded shard files.

## Packing Objectives & Capacity Model

- **Capacity**: Bins are sized against $\text{Quota} - \text{HeaderBytes}$.
- **Tolerance**: Bins may extend up to $\text{Quota} + \text{Tolerance}$ to prevent splitting coherent groups.
- **Atomicity**: Individual records are never split across shards. If a single record exceeds the ceiling, it is allocated to its own dedicated overflow shard.

### Objectives

1. **Minimizing Shard Count**: Calculate the lower bound of required shards.
2. **Distribution Profile**:
   - `FrontLoad`: Fills initial shards as close to the ceiling as feasible, leaving the final shard smaller.
   - `Even`: Balances byte weight across all bins as evenly as possible.

## Grouping & Sorting

- **Grouping**:
  - `Flat`: Single partition across all files.
  - `ByFileType`: Groups entries by their carried extension.
  - `ByRootDirectory`: Groups entries by their top-level directory.
- **GroupSort**: Sorts items within groups (`PathAsc` for lexical order, `PathHash` for hash-distributed order).
