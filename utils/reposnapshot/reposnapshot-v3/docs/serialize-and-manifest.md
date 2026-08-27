# Serialize & Manifest Generation

The export stages (`rs.core.serialize.psm1` and `rs.core.manifest.psm1`) write final snapshot files to disk and generate the table-of-contents manifest.

## Serializer (`rs.core.serialize.psm1`)

- **Disk Writing**: Writes `<ShardStem>_<Key>.txt` for each planned shard.
- **Plan-File Gate**: Validates that actual written bytes match the planned byte count (`PlannedSizeBytes`), throwing immediately on divergence.
- **Writer Receipts**: Byte offsets (`RowOffset`, `RowMetaEnd`, `RowContentBegin`, `RowContentEnd`) are recorded directly from the write cursor during serialization, guaranteeing offset veracity.

## Tree Manifest (`rs.core.manifest.psm1`)

`New-Manifest` is a poor-man's template engine for the tree TOC (`_tree.md`). The document pattern is `templates/tree.template.md`; canned reader notices (format, offset unit, formatting, compaction, instructions, oversized reason, tree legend) are `templates/tree.notices.json`. The psm1 interpolates run facts into that pattern; it does not own the prose.

A shard file is the header row plus the records in it — the header is the local structure of those rows. Packing settings (Grouping, GroupSort, OrderStrict, quota, tolerance, shard count) are snapshot-global and live on the tree's summary line, not inside shards.

### What the engine interpolates

- **Receipt** — payload lines, row offsets for the TOC, encoding, oversized flags.
- **Shard plan** — packing summary, group tags, plan/receipt size gate.
- **Layout** — header row verbatim (`ColumnHeader`).
- **RunContext** — provenance scalars (RunStamp, Root, GeneratorVersion, glob/mode/columns/config source). Not a nested JSON dump.
- **Family** (optional, colonel plan) — a `## Chains` section: extensions grouped by the chain they actually took. Unused pass-through (compiled spare, no corpus extension interned onto it) is omitted. A family that routes nothing reports `all files:` on the one chain. Step label is `Slot (Key)` when they differ.

### Declarations Section

Explicitly declares all format parameters to downstream consumer models:
- Format identifier (from notices).
- Offset units (UTF-8 bytes).
- File encoding (`utf-8` — no BOM; LF record terminator).
- Compaction notice (not a cipher key).
- Formatting notice (row surface).
- Byte-identical header row string.
- Hazard disclosures for any shards exceeding standard quota limits.
- Rendered ASCII directory tree and templated provenance.
- Chains, when a family was passed.
