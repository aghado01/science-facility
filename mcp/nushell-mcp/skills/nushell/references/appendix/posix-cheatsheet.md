# Stock Nushell: Native POSIX Equivalents

Displaced from `posix-cheatsheet`; console equivalent: `nu-skills read posix-cheatsheet`.

Canonical Nushell translations for file search, stream inspection, and redirection without the console's `rg` and `xq` modules.

| POSIX Action | Stock Nushell Equivalent | Notes |
| :--- | :--- | :--- |
| **Grep file contents** | `open file.txt \| lines \| where $it =~ "pat"` or `find "pat"` | Search in file lines; in console use `rg` |
| **Head / Tail lines** | `open --raw file \| lines \| first 5` / `last 5` | Line slicing on an opened file |
| **Redirect Stderr / Complete** | `do { cmd } \| complete` | See `nu-skills read appendix/advanced` |
| **Prepend to PATH** | `$env.PATH = ($env.PATH \| prepend "/dir")` | See `nu-skills read appendix/parity` |
