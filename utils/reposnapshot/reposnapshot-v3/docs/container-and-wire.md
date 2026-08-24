# Container & Wire Layout (PSR)

The container module (`rs.core.container.psm1`) implements the Piped Snapshot Row (`psr`) serialization grammar.

## Grammar & Specification

The layout and schema are governed by `contracts/container.spec.jsonc`. The container module interprets this specification to format, measure, and serialize header and record rows.

### Row Grammar

A row is a single physical line consisting of items separated by single spaces:

$$\text{RowBytes} = \sum \text{ItemBytes} + (\text{ItemCount} - 1) + \text{TerminatorBytes}$$

- **Header Row**: Declares the schema columns and types. Byte-identical across every shard in a run.
- **Record Row**: Projects an IR entry onto the resolved schema columns.

## Content Codec

The content codec enforces the single-physical-line invariant by replacing newlines with the literal two-character token `\n`:

- **Substitution**: Pure symbol substitution (`LF`, `CRLF`, `CR`, `NEL`, `LS`, `PS`, `VT`, `FF` $\to$ `\n`).
- **Whitespace Separation**: Spacing around line marks (` \n `) is prepared upstream by the `pad-breaks` processor in `rs-whitespace.ps1`, preserving separation across symbol boundaries.
- **Controls**: Strips non-tab C0 controls and DEL (`0x7F`). Tabs and backslashes are preserved literally.

## Layout Resolution & Invariance

`Resolve-Layout` compiles the schema once per run. This layout object is used by:
1. `Measure-Row` (in `rs.core.shards` for bin sizing).
2. `Build-Row` (in `rs.core.serialize` for disk emission).
3. `HeaderRowText` (in `rs.core.manifest` for declarations).

Because measuring and rendering evaluate the exact same item definitions, planned sizes and emitted byte lengths are mathematically identical.
