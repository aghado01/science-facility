# Nushell: Structured Data Pipelines & Token Economy

Project, filter, and slice output data before returning to context to save context window tokens.

## Output Slicing & Projection
- **JSON Formatting:** `<pipeline> | to json` (compact: `to json -c` or `to json -r`)
- **Row Filtering (`where`):**
  - `ls | where size > 10mb`
  - `ps | where cpu > 10`
- **Column Selection (`select`):**
  - `ls | select name size modified | first 5`
- **Single Field Extraction (`get`):**
  - `ls | get name`
- **Sort & Take (`sort-by`, `first`):**
  - `ls | sort-by size -r | first 10`
- **Compact Nulls (`compact`):**
  - `[1 null 2] | compact`

## Environment & Scope Persistence
- **Set Variable:** `$env.FOO = "bar"`
- **Bulk Load Env:** `load-env { FOO: "bar", BAZ: "qux" }`
- **Change Directory:** `cd /path/to/dir`
- **Persistence:** Top-level `$env` updates and `cd` persist across `para-agent` pane turns.
