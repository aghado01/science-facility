# Stock Nushell: Native Background Jobs & Process Completion

Displaced from `advanced`; console equivalent: [`nu-skills read jobs`](../jobs.md) (for jobs) and [`nu-skills read posix-cheatsheet`](../posix-cheatsheet.md) (for `xq`).

Canonical Nushell includes native background job control and command completion primitives.

## Background Jobs (`job spawn`, `job recv`, `job kill`)
- **Spawn**: `let job_id = (job spawn { sleep 10sec; "done" | save -f done.txt })`
- **List**: `job list`
- **Receive**: `job recv` (receives from thread mailbox; takes no job ID argument)
- **Terminate**: `job kill <id>`

## Parallel Iteration (`par-each`)
- `[1 2 3] | par-each --threads 4 { |it| $it * 2 }`

## External Command Completion (`complete`)
- External command bundle: `do { external_cmd } | complete` or `^external_cmd | complete`
- Returns a structured record: `{ stdout, stderr, exit_code }`
