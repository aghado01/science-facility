# Profile 3: Primary Supervisor Agent Configuration (config.nu)
# Rich interactive environment with history, plugins, and supervisor CLI

$env.config = {
  show_banner: false
  use_ansi_coloring: true
  table: {
    mode: "rounded"
    index_mode: "auto"
  }
  history: {
    sync_on_enter: true
    file_format: "plaintext"
    max_size: 10000
  }
  edit_mode: "emacs"
}

$env.PROMPT_INDICATOR = {|| "para [supervisor]> " }

# Source supervisor CLI commands
use para-cli.nu *

