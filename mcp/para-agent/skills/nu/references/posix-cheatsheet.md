# Nushell: POSIX / Bash Translation Cheatsheet

| Action | POSIX / Bash | Nushell |
| :--- | :--- | :--- |
| **Set Environment Variable** | `export FOO=bar` | `$env.FOO = "bar"` |
| **Prepend to PATH** | `export PATH="/dir:$PATH"` | `$env.PATH = ($env.PATH \| prepend "/dir")` |
| **Redirect Stderr/Complete** | `cmd 2>&1` | `do { cmd } \| complete` |
| **Isolated Subshell** | `(cd dir && cmd)` | `do { cd dir; cmd }` |
| **Path Exists Check** | `[ -f file ]` | `("file" \| path exists)` |
| **JSON Extraction** | `cat f.json \| jq '.foo'` | `open f.json \| get foo` |
| **Try / Ignore Failure** | `cmd \|\| true` | `try { cmd }` |
| **Check Last Exit Code** | `echo $?` | `print $env.LAST_EXIT_CODE?` |
| **Statement Separator** | `;` (or `&&` for success-only) | `;` (for success-only: `if ($env.LAST_EXIT_CODE? == 0) { next }`) |
