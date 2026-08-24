# Nushell: Advanced Scripting & Custom Commands

## Custom Commands (`def`)
```nu
def greet [name: string, --shout (-s)]: string -> string {
    let msg = $"hello ($name)"
    if $shout { $msg | str upcase } else { $msg }
}
```

## Structured Error Handling (`try` / `catch`)
- Catch error object: `try { open nonexistent.txt } catch { |err| $"Handled: ($err.msg)" }`
- Domain failures in this console return `{ok: false, error: ...}` as data rather than throwing.

## Background Jobs & Execution
- In the augmented console, use `jobs spawn` for background execution and quarantine (see `nu-skills read jobs`).
- For running external commands with automatic stream quarantine, use `xq` (see `nu-skills read posix-cheatsheet`).

> Stock `job spawn` / `job recv` / `job kill` and `| complete`: `nu-skills read appendix/advanced`.
