# Tree Manifest TOC for Snapshot: `{{Title}}`

{{SummaryLine}}

Payload:
{{#each PayloadLines}}{{this}}
{{/each}}

## Declarations

- Format: {{Format}}
- Offsets: {{OffsetUnit}}
- Encoding: {{Encoding}} — no BOM; LF record terminator
- Compaction: {{Compaction}}
- Header row (first line of every shard, byte-identical): `{{ColumnHeader}}`
{{#if Hazards}}
Hazards — these shards exceed quota + tolerance and must be read whole; every
other shard is within the ceiling:
{{#each Hazards}}- `{{Key}}` {{ByteLength}} bytes — {{Reason}}
{{/each}}{{/if}}
## Instructions

{{#each Instructions}}{{this}}
{{/each}}
## Tree for `{{TreeLabel}}`

```
{{TreeLegend}}
{{TocTree}}
```

## Provenance

- RunStamp: {{RunStamp}}
- Root: {{Root}}
- GeneratorVersion: {{GeneratorVersion}}
{{#if GlobSemantics}}- GlobSemantics: {{GlobSemantics}}
{{/if}}{{#if PatternsLine}}- Patterns: {{PatternsLine}}
{{/if}}{{#if Mode}}- Mode: {{Mode}}
{{/if}}{{#if RequestedLine}}- Requested: {{RequestedLine}}
{{/if}}{{#if ColumnsLine}}- Columns: {{ColumnsLine}}
{{/if}}{{#if ConfigSource}}- ConfigSource: {{ConfigSource}}
{{/if}}{{#if Chains}}
## Chains

{{#each Chains}}- {{Line}}
{{/each}}{{/if}}
