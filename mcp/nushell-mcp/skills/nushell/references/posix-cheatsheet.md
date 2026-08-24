# Nushell: POSIX / Bash Translation Cheatsheet

| Action | POSIX / Bash | Nushell Console | Notes / Stock |
| :--- | :--- | :--- | :--- |
| **Set Environment Variable** | `export FOO=bar` | `$env.FOO = "bar"` | Persists across `evaluate` |
| **Prepend to PATH** | `export PATH="/dir:$PATH"` | `$env.PATH = ($env.PATH \| split row (char esep) \| prepend "/dir" \| uniq)` | Stock: `nu-skills read appendix/parity` |
| **Run & Quarantine Ext Cmd** | `cmd 2>&1` | `xq cmd` | Stock `\| complete`: `nu-skills read appendix/advanced` |
| **Isolated Subshell** | `(cd dir && cmd)` | `do { cd dir; cmd }` | Block-scoped env/dir |
| **Path Exists Check** | `[ -f file ]` | `("file" \| path exists)` | Returns boolean |
| **JSON Extraction** | `cat f.json \| jq '.foo'` | `open f.json \| get foo` | Auto-parses structured JSON |
| **Try / Ignore Failure** | `cmd \|\| true` | `try { cmd }` | Catches exceptions |
| **Check Last Exit Code** | `echo $?` | `print $env.LAST_EXIT_CODE?` | Diagnostic check |
| **Statement Separator** | `;` (or `&&` for success) | `;` (or `if ($env.LAST_EXIT_CODE? == 0) { ... }`) | Sequential execution |
| **Read Raw Text File** | `cat file.txt` | `open --raw file.txt` | Returns raw string |
| **Head / Tail Lines on File** | `head -n 5 file` / `tail -n 5` | `let l = (open --raw file \| lines); $l \| first 5` | Stock: `nu-skills read appendix/posix-cheatsheet` |
| **Search / Grep Pattern** | `grep "pat"` | Files: `rg "pat"`; In-memory: `where col =~ "pat"` | Stock file grep: `nu-skills read appendix/posix-cheatsheet` |
| **Sed Substitution** | `sed 's/old/new/g'` | `str replace --all 'old' 'new'` | In-memory string replacement |
| **Tee to File** | `cmd \| tee out.txt` | `cmd \| tee { save out.txt }` | Passthrough stream copy |
