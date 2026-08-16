# nu-skills.nu - Native Nushell interactive skill & reference resource provider

# `path self` only works at parse time, so capture the module dir in a const
const SELF_DIR = (path self | path dirname)

# Resolve the anchored skill directory with fallback
def get-skill-root []: nothing -> string {
    let raw = ($env.NU_SKILL_DIR? | default ($SELF_DIR | path join "../../skills/nushell"))
    $raw | path expand
}

# Exported as `main` — nushell forbids a module exporting a command with its own name;
# `use nu-skills` / `use nu-skills *` binds this to `nu-skills`.

# Query Nushell skill documentation and reference topics
export def main [
    topic?: string # Optional topic to read directly (e.g. gotchas, posix-cheatsheet, pipelines, file-io, data-analysis, advanced, parity, mcp, sessions)
]: nothing -> string {
    if ($topic == null or $topic == "") {
        nu-skills read "index"
    } else {
        nu-skills read $topic
    }
}

# List all available skill reference topics in a structured table
export def "nu-skills list" []: nothing -> table {
    let root = (get-skill-root)
    let ref_dir = ($root | path join "references")
    if not ($ref_dir | path exists) {
        return []
    }
    
    ls ($ref_dir | path join "*.md" | into glob)
    | each { |row|
        let stem = ($row.name | path parse | get stem)
        let first_line = (open --raw $row.name | lines | where ($it !~ '^#\s*$') | first 1 | default [""] | get 0 | str replace -r '^#+\s*' '')
        {
            topic: $stem,
            title: $first_line,
            size: $row.size,
            modified: $row.modified,
            path: $row.name
        }
    }
}

# Read the full markdown content of a specific skill topic or index
export def "nu-skills read" [
    topic: string = "index" # Topic name to read (e.g., gotchas, posix-cheatsheet, pipelines, file-io, data-analysis, advanced, parity, mcp, sessions, index)
]: nothing -> string {
    let root = (get-skill-root)
    
    if ($topic == "index" or $topic == "root" or $topic == "") {
        let index_file = ($root | path join "SKILL.md")
        if ($index_file | path exists) {
            open --raw $index_file
        } else {
            error make { msg: $"SKILL.md not found in ($root)" }
        }
    } else {
        let target = ($root | path join "references" $"($topic).md")
        if ($target | path exists) {
            open --raw $target
        } else {
            let available = (nu-skills list | get topic)
            error make {
                msg: $"Topic '($topic)' not found in ($root)/references.\nAvailable topics:\n($available | each { $'  - ($in)' } | str join "\n")"
            }
        }
    }
}

# Search across all skill references for a pattern or keyword
export def "nu-skills search" [
    query: string # Text or regex pattern to search for across references
]: nothing -> table {
    let root = (get-skill-root)
    let ref_dir = ($root | path join "references")
    if not ($ref_dir | path exists) {
        return []
    }

    ls ($ref_dir | path join "*.md" | into glob)
    | each { |row|
        let stem = ($row.name | path parse | get stem)
        open --raw $row.name
        | lines
        | enumerate
        | where { |line| $line.item =~ $query }
        | each { |match|
            {
                topic: $stem,
                line: ($match.index + 1),
                content: ($match.item | str trim)
            }
        }
    }
    | flatten
}

# Return the anchored skill root path and inventory status
export def "nu-skills status" []: nothing -> record {
    let root = (get-skill-root)
    let exists = ($root | path exists)
    let count = if $exists {
        let ref_dir = ($root | path join "references")
        if ($ref_dir | path exists) { (ls ($ref_dir | path join "*.md" | into glob) | length) } else { 0 }
    } else { 0 }

    {
        anchored_dir: $root,
        exists: $exists,
        topic_count: $count,
        env_var: ($env.NU_SKILL_DIR? | default "<unset>")
    }
}
