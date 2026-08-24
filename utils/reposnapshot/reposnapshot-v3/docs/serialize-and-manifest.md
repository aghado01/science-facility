# Serialize & Manifest Generation

The export stages (`rs.core.serialize.psm1` and `rs.core.manifest.psm1`) write final snapshot files to disk and generate the table-of-contents manifest.

## Serializer (`rs.core.serialize.psm1`)

- **Disk Writing**: Writes `<ShardStem>_<Key>.txt` for each planned shard.
- **Plan-File Gate**: Validates that actual written bytes match the planned byte count (`PlannedSizeBytes`), throwing immediately on divergence.
- **Writer Receipts**: Byte offsets (`RowOffset`, `RowMetaEnd`, `RowContentBegin`, `RowContentEnd`) are recorded directly from the write cursor during serialization, guaranteeing offset veracity.

## Tree Manifest (`rs.core.manifest.psm1`)

`New-Manifest` renders a single markdown table-of-contents file (`_tree.md`) using a lightweight Handlebars template engine.

### Declarations Section

Explicitly declares all format parameters to downstream consumer models:
- Format identifier and wire version.
- Offset units (UTF-8 bytes).
- File encoding (`UTF-8` no BOM).
- Compaction and line ending markers.
- Byte-identical header row string.
- Hazard disclosures for any shards exceeding standard quota limits.
- Rendered ASCII directory tree and provenance summary.
