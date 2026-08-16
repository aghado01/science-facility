# Nushell: Advanced Scripting, Defs & Jobs

## Custom Commands (`def`)
```nu
def greet [name: string, --shout (-s)]: string -> string {
    let msg = $"hello ($name)"
    if $shout { $msg | str upcase } else { $msg }
}
```

## Background Jobs
- Spawn: `let job_id = (job spawn { sleep 10sec; "done" | save -f done.txt })`
- Inspect / Terminate: `job list`, `job kill <id>`

## Structured Error Handling
- Catch error object: `try { open nonexistent.txt } catch { |err| $"Handled: ($err.msg)" }`
- External command bundle: `do { external_cmd } | complete` (returns `{ stdout, stderr, exit_code }`)
