Got it, I’ll use the renamed `README.md` and update that instead of recreating the old guidelines filename.

Searched for files matching `**/README.md`, 1 match

Searched for regex `Jso|JSO|jso-rpc|tmp\\jso-rpc|tmp/jso-rpc|CLAUDE_CONFIG_DIR.*tmp` (`**/tools/**`), 100 results

Read [](file:///c%3A/Users/azrie/.claude/tools)

Found it at README.md. I also noticed the scratch/changelog still point to the old filename, so I’ll update those references after I adjust the README conventions.

Read [](file:///c%3A/Users/azrie/.claude/tools/README.md)

The README still uses `tmp\jso-rpc`; I’m changing that to `tmp\rpc` and adding a concrete convention section: job directory name, stable filenames, formats, and what each file means.

Generating patch (113 lines) in [](file:///c%3A/Users/azrie/.claude/tools/README.md), [](file:///c%3A/Users/azrie/.claude/tools/_usage_scratch.md), [](file:///c%3A/Users/azrie/.claude/tools/CHANGELOG.md)

```

```

```

```

```

```

Updated the README and fixed the stale old filename references. I’m doing a quick scan for any leftover `jso-rpc` or `jso-model-usage-guidelines.md` references so the convention is consistent.

Searched for regex `jso-rpc|jso-model-usage-guidelines|tmp\\rpc|tmp/rpc` (`**/tools/**`), 6 results

Generating patch (6 lines) in [](file:///c%3A/Users/azrie/.claude/tools/README.md)

```

```

Searched for regex `jso-rpc|jso-model-usage-guidelines` (`**/tools/**`), no results

Updated README.md: default RPC artifact root is now:

```powershell
$env:CLAUDE_CONFIG_DIR\tmp\rpc
```

The convention documented there is:

```text
$env:CLAUDE_CONFIG_DIR\tmp\rpc\YYYYMMDD_HHmmss-<command-or-task>\
  request.json
  result.jsonl
  summary.json
  errors.jsonl
  stdout.txt
  stderr.txt
```

Key rules:

- One tool call/job gets one directory.
- Directory task name uses lowercase kebab-case, like `20260429_153012-find-jsonl-by-path`.
- Add a short suffix if needed: `20260429_153012-find-jsonl-by-path-a7f3`.
- `request.json` and `summary.json` are required.
- Prefer `result.jsonl` for row streams.
- Use `result.json` for one structured object.
- Use `result.txt` only for formatted human-readable text.
- Use `errors.jsonl` for warnings/errors/skipped malformed rows.
- Use UTF-8 without BOM.
- Console output should only return paths, counts, and tiny previews.

Also fixed old references from `jso-model-usage-guidelines.md` to README.md in \_usage_scratch.md and CHANGELOG.md.

Made changes.
