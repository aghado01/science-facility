# Profile 2: Para-Agent Worker Configuration (config.nu)
# Deterministic prompt and clean screen for reliable pane read/delta capture

$env.config = {
  show_banner: false
  use_ansi_coloring: true
  render_right_prompt_on_last_line: false
  table: {
    mode: "rounded"
    index_mode: "auto"
  }
  history: {
    sync_on_enter: false
    file_format: "plaintext"
    max_size: 1000
  }
}

$env.PROMPT_COMMAND = {|| "" }
$env.PROMPT_COMMAND_RIGHT = {|| "" }
$env.PROMPT_INDICATOR = {|| "nu> " }

# Source worker helpers
use helpers.nu *

