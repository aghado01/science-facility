# Assemble & In-Memory Intermediate Representation (IR)

The assemble stage (`rs.core.assemble.psm1`) collates processor dispatch outputs into the in-memory Intermediate Representation (IR).

## Purpose & Boundaries

Assemble is a cross-item collation stage, not a chain processor. It does not perform content mutation or compute row-level values.

### Invariant Sequence

1. **Adapt**: Adapt track output to entry candidates (e.g. Code track is 1 → 1; Thread track explodes exchanges).
2. **Route**: Partition entries between payload `Entries` and `Diagnostics` based on `EntryRouting` policy.
3. **Derive**: Count observed elements across valid entries into `Header.Elements`.
4. **Stamp**: Attach `RunContext`, `EntryCount`, and `Elements` into `Header`.

## Open Element Model

Entries in the IR are open property bags carrying:
- **Core guaranteed properties**: `RelativePath`, `NodePath`, `LastWriteUtc`, `Content`.
- **Carried downstream properties**: `Extension`, `SizeBytes`. Carried for planning/grouping stages but omitted from the element count.
- **Dynamic enrichment elements**: Any property attached by a chain processor (e.g., `ContentMeta`, `Processing`).

`Header.Elements` records the observed presence count for all dynamic elements across valid payload entries.

## Entry Routing Policies

- **`LeanPayload` (Default)**: Items carrying a `ReadError` (e.g., binary files or I/O exceptions) are diverted to `Diagnostics.Routed` rather than emitted as empty entries in `Entries`.
- **`KeepContentless`**: Items with `ReadError` are retained in `Entries` with their error property intact, explicitly declaring the reason for empty content.
