# Nushell: Structured Data Pipelines & Session Persistence

Filter, project, and transform structured data in memory before returning results.

## Structured Transformations & Filtering
- **Row Filtering (`where`):**
  - `ls | where size > 10mb`
  - `ps | where cpu > 10`
- **Column Selection (`select`):**
  - `ls | select name size modified`
- **Single Field Extraction (`get`):**
  - `ls | get name`
- **Compact Nulls (`compact`):**
  - `[1 null 2] | compact`

## Slicing Bound Collections (THE RULE)
Never cap a first-run pipeline (do not `ls | first 5`). Store or bind the data into a variable first, then slice:
```nu
let files = (ls | sort-by size -r)
$files | select name size modified | first 5
```

## Large Payloads & Token Economy
For large or unbounded datasets, do not dump raw tables into the evaluation return. Use the disclosure ladder:
- **Census first**: `$val | shape` (see [`nu-skills read dataspection`](dataspection.md))
- **Bounded read**: `$val | read` (stashes over cap, returning retrieval tag)
- **Background quarantine**: `jobs spawn { ... }` (see [`nu-skills read jobs`](jobs.md))

## Environment & Scope Persistence
- **Set Variable**: `$env.FOO = "bar"`
- **Bulk Load Env**: `load-env { FOO: "bar", BAZ: "qux" }`
- **Change Directory**: `cd /path/to/dir`
- **Persistence**: Top-level `$env` updates, variables, and `cd` persist across `evaluate` calls in this MCP session.
