# nu-skills.nu - Native Nushell interactive skill & reference resource provider

# `path self` only works at parse time, so capture the module dir in a const
const SELF_DIR = (path self | path dirname)

# Resolve the anchored skill directory with fallback
def get-skill-root []: nothing -> string {
    let raw = ($env.NU_SKILL_DIR? | default ($SELF_DIR | path join "../../skills/nushell"))
    $raw | path expand
}

# Helper: normalize relative topic path with forward slashes and strip .md
def normalize-topic [rel_path: string]: nothing -> string {
    $rel_path
    | str replace -r '\.md$' ''
    | str replace -a '\' '/'
    | str replace -r '^/+' ''
    | str replace -r '/+$' ''
}

# Helper: find all .md files under a directory safely across platforms
def find-md-files [dir: string]: nothing -> list<string> {
    let pattern = ($dir | str replace -a '\' '/' | $"($in)/**/*.md" | into glob)
    try { glob $pattern } catch { [] }
}

# Helper: extract title from a markdown file (first non-empty heading or clean line)
def get-file-title [file_path: string]: nothing -> string {
    if ($file_path | path exists) {
        let lines = (open --raw $file_path | lines | where ($it !~ '^#\s*$') | where ($it | str trim | str length) > 0)
        if ($lines | is-empty) {
            ""
        } else {
            $lines | first | str replace -r '^#+\s*' '' | str trim
        }
    } else {
        ""
    }
}

# Exported as `main` — nushell forbids a module exporting a command with its own name;
# `use nu-skills` / `use nu-skills *` binds this to `nu-skills`.

# Query Nushell skill documentation and reference topics (see `nu-skills list`)
export def main [
    topic?: string # Optional topic or branch to read (e.g. jobs, search, dataspection, appendix, appendix/advanced)
]: nothing -> string {
    if ($topic == null or $topic == "") {
        nu-skills read "index"
    } else {
        nu-skills read $topic
    }
}

# List available skill reference topics and branches in a structured table
export def "nu-skills list" [
    branch?: string # Optional branch to list children of (e.g. appendix)
    --all (-a)      # List all leaves recursively, path-qualified
]: nothing -> table {
    let root = (get-skill-root)
    let ref_dir = ($root | path join "references")
    if not ($ref_dir | path exists) {
        return []
    }

    if $all {
        let files = (find-md-files $ref_dir)
        return (
            $files
            | each { |p|
                let rel = ($p | path relative-to $ref_dir)
                let topic = (normalize-topic $rel)
                let title = (get-file-title $p)
                let row_size = (ls -f $p | get size | first | default 0B)
                {
                    topic: $topic,
                    title: $title,
                    kind: "leaf",
                    n: 0,
                    size: $row_size,
                    path: $p
                }
            }
            | sort-by topic
        )
    }

    let target_dir = if ($branch == null or $branch == "") {
        $ref_dir
    } else {
        let norm_branch = (normalize-topic $branch)
        $ref_dir | path join ...($norm_branch | split row "/")
    }

    if not ($target_dir | path exists) {
        return []
    }

    let items = (ls -f $target_dir)
    $items
    | each { |row|
        let p = $row.name
        let is_dir = ($row.type == "dir")
        let rel = ($p | path relative-to $ref_dir)
        let topic = (normalize-topic $rel)

        if $is_dir {
            let child_items = (ls -f $p)
            let direct_children_count = ($child_items | length)
            let leaf_files = (find-md-files $p)
            let total_size = if ($leaf_files | is-empty) {
                0B
            } else {
                $leaf_files | each { |f| ls -f $f | get size | first | default 0B } | math sum
            }
            let dir_name = ($p | path basename)
            {
                topic: $topic,
                title: $dir_name,
                kind: "branch",
                n: $direct_children_count,
                size: $total_size,
                path: $p
            }
        } else if ($p | str ends-with ".md") {
            let title = (get-file-title $p)
            {
                topic: $topic,
                title: $title,
                kind: "leaf",
                n: 0,
                size: $row.size,
                path: $p
            }
        } else {
            null
        }
    }
    | compact
    | sort-by kind topic
}

# Read the full markdown content of a specific skill topic, branch, or index
export def "nu-skills read" [
    topic: string = "index" # Topic name or branch to read (e.g. jobs, dataspection, appendix, appendix/advanced, index)
]: nothing -> string {
    let root = (get-skill-root)
    let norm_topic = (normalize-topic $topic)

    if ($norm_topic == "index" or $norm_topic == "root" or $norm_topic == "") {
        let index_file = ($root | path join "SKILL.md")
        if ($index_file | path exists) {
            open --raw $index_file
        } else {
            error make { msg: $"SKILL.md not found in ($root)" }
        }
    } else {
        let ref_dir = ($root | path join "references")
        let parts = ($norm_topic | split row "/")
        let file_target = ($ref_dir | path join ...$parts | $"($in).md")
        let dir_target = ($ref_dir | path join ...$parts)

        if ($file_target | path exists) {
            open --raw $file_target
        } else if (($dir_target | path exists) and (($dir_target | path type) == "dir")) {
            let branch_rows = (nu-skills list $norm_topic)
            let md_table = ($branch_rows | select topic title kind n size | to md)
            $"# Branch: ($norm_topic)\n\n($md_table)\n"
        } else {
            let all_inventory = (nu-skills list --all | get topic)
            error make {
                msg: $"Topic '($topic)' not found in ($root)/references.\nAvailable topics:\n($all_inventory | each { $'  - ($in)' } | str join "\n")"
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

    let files = (find-md-files $ref_dir)
    $files
    | each { |file_path|
        let rel = ($file_path | path relative-to $ref_dir)
        let topic = (normalize-topic $rel)
        open --raw $file_path
        | lines
        | enumerate
        | where { |line| $line.item =~ $query }
        | each { |match|
            {
                topic: $topic,
                line: ($match.index + 1),
                content: ($match.item | str trim)
            }
        }
    }
    | flatten
}

# Return the anchored skill root path and recursive leaf inventory status
export def "nu-skills status" []: nothing -> record {
    let root = (get-skill-root)
    let exists = ($root | path exists)
    let count = if $exists {
        let ref_dir = ($root | path join "references")
        if ($ref_dir | path exists) {
            (find-md-files $ref_dir | length)
        } else {
            0
        }
    } else {
        0
    }

    {
        anchored_dir: $root,
        exists: $exists,
        topic_count: $count,
        env_var: ($env.NU_SKILL_DIR? | default "<unset>")
    }
}
