# Profile 1: Backend Stdio Daemon Configuration (config.nu)
# Optimized for zero visual noise, machine JSON streaming, and fast execution

$env.config = {
  show_banner: false
  use_ansi_coloring: false
  table: {
    mode: "compact"
    index_mode: "never"
  }
  history: {
    sync_on_enter: false
    file_format: "plaintext"
    max_size: 0
  }
  bracketed_paste: false
  edit_mode: "emacs"
}
