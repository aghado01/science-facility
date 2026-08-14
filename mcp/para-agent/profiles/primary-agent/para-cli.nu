# Profile 3: Primary Supervisor CLI Utilities (para-cli.nu)

# List all multiplexer sessions and panes with structured table output
def "para-panes" [] {
  let raw = (tmux list-panes -a -F "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_pid}\t#{pane_dead}" | complete)
  if ($raw.exit_code != 0) {
    print "No active tmux/psmux sessions found."
    return []
  }
  $raw.stdout 
    | lines 
    | where ($it | str trim | str length) > 0
    | split column "\t" session window pane command cwd pid dead
    | into int window pane pid
}

# List all sessions
def "para-sessions" [] {
  let raw = (tmux list-sessions -F "#{session_name}\t#{session_windows}\t#{session_attached}" | complete)
  if ($raw.exit_code != 0) {
    return []
  }
  $raw.stdout
    | lines
    | where ($it | str trim | str length) > 0
    | split column "\t" session windows attached
    | into int windows attached
}

# Peek at the visible content of a pane
def "para-peek" [handle: string] {
  tmux capture-pane -t $handle -p | complete | get stdout
}
