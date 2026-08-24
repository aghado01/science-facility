# Child `nu -n` tests for skills-corpus v1. Run:
#   nu -n mcp/nushell-mcp/tests/skills-corpus-v1.nu

const MODULES_DIR = (path self | path dirname | path dirname | path join modules)
const SKILLS_DIR = (path self | path dirname | path dirname | path join skills nushell)
const NU_LIB_DIRS = [$MODULES_DIR]

use nu-skills *

def assert-eq [left, right, msg: string] {
    if $left != $right {
        error make {msg: $"($msg): expected ($right | to nuon --raw), got ($left | to nuon --raw)"}
    }
}

def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $msg} }
}

def find-md-files [dir: string]: nothing -> list<string> {
    let pattern = ($dir | str replace -a '\' '/' | $"($in)/**/*.md" | into glob)
    try { glob $pattern } catch { [] }
}

def --env t [name: string, fn: closure] {
    try {
        do $fn
        {name: $name, ok: true, error: null}
    } catch {|e|
        {name: $name, ok: false, error: ($e.msg | lines | first | default $e.msg)}
    }
}

$env.NU_SKILL_DIR = ($SKILLS_DIR | path expand)
let ref_dir = ($SKILLS_DIR | path join references | path expand)
let expected_leaves = (find-md-files $ref_dir | length)

let results = [
    (t "nu-skills list top-level shape and appendix branch" {
        let rows = (nu-skills list)
        assert-true (($rows | length) > 0) "rows present"
        
        # Check closed row shape
        let cols = ($rows | columns | sort)
        assert-eq $cols ["kind" "n" "path" "size" "title" "topic"] "closed row shape"
        
        # Check kinds
        let kinds = ($rows | get kind | uniq | sort)
        assert-eq $kinds ["branch" "leaf"] "valid kinds"
        
        # Check appendix branch
        let app = ($rows | where topic == "appendix")
        assert-eq ($app | length) 1 "one appendix row"
        let app_row = ($app | first)
        assert-eq $app_row.kind "branch" "appendix is branch"
        assert-true ($app_row.n >= 5) "appendix has children count"
        assert-true (($app_row.size | describe) =~ "filesize") "size is filesize"
        assert-true ($app_row.size > 0B) "appendix size sum > 0"
        
        # No duplicate topics
        let topics = ($rows | get topic)
        assert-eq ($topics | length) ($topics | uniq | length) "no duplicate topics"
    })

    (t "nu-skills list appendix branch children" {
        let app_rows = (nu-skills list appendix)
        assert-true (($app_rows | length) >= 5) "at least 5 appendix leaves"
        
        for row in $app_rows {
            assert-eq $row.kind "leaf" "all appendix children are leaves"
            assert-eq $row.n 0 "leaf n is 0"
            assert-true ($row.topic | str starts-with "appendix/") "topic path-qualified"
            assert-true (not ($row.topic | str contains '\')) "topic has no backslashes"
        }
        
        let app_topics = ($app_rows | get topic)
        assert-true ("appendix/mcp" in $app_topics) "appendix/mcp present"
        assert-true ("appendix/advanced" in $app_topics) "appendix/advanced present"
        assert-true ("appendix/posix-cheatsheet" in $app_topics) "appendix/posix-cheatsheet present"
        assert-true ("appendix/parity" in $app_topics) "appendix/parity present"
        assert-true ("appendix/inspect" in $app_topics) "appendix/inspect present"
    })

    (t "nu-skills list --all matches filesystem leaf count" {
        let all_rows = (nu-skills list --all)
        assert-eq ($all_rows | length) $expected_leaves "leaf count matches filesystem"
        
        for row in $all_rows {
            assert-eq $row.kind "leaf" "all rows are leaves"
            assert-eq $row.n 0 "leaf n is 0"
            assert-true (not ($row.topic | str contains '\')) "no backslashes in topic"
            assert-true (not ($row.topic | str ends-with ".md")) "topic excludes .md"
        }
    })

    (t "nu-skills read leaf, branch, index, and tolerated extensions" {
        # Read index via bare and explicit
        let idx1 = (nu-skills)
        assert-true ($idx1 | str contains "# Nushell Agent Skill") "bare nu-skills reads SKILL.md"
        let idx2 = (nu-skills read index)
        assert-eq $idx1 $idx2 "read index matches bare"

        # Read leaf
        let jobs_doc = (nu-skills read jobs)
        assert-true ($jobs_doc | str contains "# `par` / `jobs`") "read jobs returns content"

        # Read appendix leaf
        let app_mcp = (nu-skills read appendix/mcp)
        assert-true ($app_mcp | str contains "Stock Nushell: Native Built-in MCP Server") "read appendix/mcp"

        # Tolerated .md extension
        let app_mcp_ext = (nu-skills read appendix/mcp.md)
        assert-eq $app_mcp $app_mcp_ext "tolerates .md suffix"

        # Read branch generates markdown table string
        let branch_doc = (nu-skills read appendix)
        assert-true ($branch_doc | str starts-with "# Branch: appendix") "branch doc heading"
        assert-true ($branch_doc | str contains "| appendix/mcp") "branch table contains child row"
    })

    (t "nu-skills search walks recursively and normalizes forward slashes" {
        # Search unique appendix string
        let mcp_hits = (nu-skills search "Native Built-in MCP Server")
        assert-true (($mcp_hits | length) > 0) "found search hits"
        assert-true ("appendix/mcp" in ($mcp_hits | get topic)) "hit is in appendix/mcp"

        # Search cross-topic string
        let job_hits = (nu-skills search "job spawn")
        let job_topics = ($job_hits | get topic | uniq)
        assert-true ("jobs" in $job_topics) "hits jobs steer line"
        assert-true ("appendix/advanced" in $job_topics) "hits appendix/advanced"

        # Verify no backslashes in search topics
        for hit in $job_hits {
            assert-true (not ($hit.topic | str contains '\')) "search topic normalized with forward slash"
        }
    })

    (t "nu-skills status reports recursive count" {
        let st = (nu-skills status)
        assert-eq $st.exists true "status exists"
        assert-eq $st.topic_count $expected_leaves "status topic_count matches recursive leaves"
    })

    (t "unknown topic lists --all inventory" {
        let err = (try { nu-skills read definitely-not-a-topic-xyz; "" } catch { |e| $e.msg })
        assert-true ($err | str contains "Topic 'definitely-not-a-topic-xyz' not found") "error message names topic"
        assert-true ($err | str contains "appendix/mcp") "error lists appendix leaves"
        assert-true ($err | str contains "jobs") "error lists root leaves"
    })

    (t "corpus link integrity: all cross-reference mentions resolve" {
        let all_md_files = (find-md-files $SKILLS_DIR)
        let all_topics = (nu-skills list --all | get topic)
        let all_branches = (nu-skills list | where kind == "branch" | get topic)

        for file_path in $all_md_files {
            let content = (open --raw $file_path)
            # Find all `nu-skills read <topic>`
            let read_mentions = ($content | parse -r 'nu-skills read (?P<target>[a-zA-Z0-9_\-\/]+)' | get target? | default [])
            for target in $read_mentions {
                let norm = ($target | str replace -r '\.md$' '')
                let valid = ($norm == "index" or $norm == "root" or ($norm in $all_topics) or ($norm in $all_branches))
                assert-true $valid $"In ($file_path | path basename): broken target '($target)'"
            }

            # Find all `nu-skills list <branch>`
            let list_mentions = ($content | parse -r 'nu-skills list (?P<branch>[a-zA-Z0-9_\-\/]+)' | get branch? | default [])
            for branch in $list_mentions {
                if ($branch != "--all" and $branch != "-a") {
                    let valid = ($branch in $all_branches)
                    assert-true $valid $"In ($file_path | path basename): invalid branch '($branch)' in list mention"
                }
            }
        }
    })
]

let failed = ($results | where ok == false)
let summary = {
    n: ($results | length)
    n_ok: ($results | where ok | length)
    n_err: ($failed | length)
    failed: ($failed | get name? | default [])
}
print -e ($results | select name ok error | to nuon --raw)
print -e ($summary | to nuon --raw)
if ($failed | is-empty) {
    $results | select name ok
} else {
    error make {msg: $"($failed | length) tests failed: ($failed | get name | str join ', ')"}
}
