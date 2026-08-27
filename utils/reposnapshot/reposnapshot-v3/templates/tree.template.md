# Tree Manifest TOC for Snapshot: `{{Title}}`
{{SummaryLine}}
Snapshot Root: {{Root}}

{{#each Instructions}}{{this}}
{{/each}}
{{Formatting}}
{{Compaction}}
## Tree for `{{TreeLabel}}`

Payload:
{{#each PayloadLines}}{{this}}
{{/each}}

```
{{TreeLegend}}
{{TocTree}}
```