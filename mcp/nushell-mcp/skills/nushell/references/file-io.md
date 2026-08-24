# Nushell: Structured File I/O (`open` & `save`)

`open` automatically parses structured files (JSON, YAML, TOML, CSV, TSV, XML, SQLite) into native Nushell records and tables.

## Reading Structured Files
- **JSON:** `open package.json | get dependencies`
- **YAML:** `open config.yaml | get server.port`
- **CSV/TSV:** `open data.csv | where status == "error" | select id message`
- **SQLite Database:** `open database.sqlite | get users | where age > 21`

## Large File Discipline
For large or unknown structured files, avoid dumping the parsed output into the tool result. Census with `shape` first (`open large.json | shape`), read boundedly with `read` (see `nu-skills read dataspection`), or isolate in the background (`jobs spawn { open large.json }`, see `nu-skills read jobs`).

## Saving Structured Files
- **Save JSON:** `{ a: 1, b: 2 } | to json | save -f output.json`
- **Save CSV:** `$table | to csv | save -f output.csv`
- **Raw Text Save:** `"hello world" | save -f log.txt`
