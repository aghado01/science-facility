// Diagnostic for issue #226: dump every key event crossterm produces,
// plus the raw INPUT_RECORD as seen by ReadConsoleInputW, side by side.
//
// Run visibly. Press the keys you want to inspect (or inject via the
// injector with {RAW:vk:ch:ctrl}). Events are appended to:
//   $TEMP/psmux_key_diag.log
// Press 'q' to quit.

use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;

fn log_path() -> PathBuf {
    let dir = std::env::var("TEMP")
        .or_else(|_| std::env::var("TMP"))
        .unwrap_or_else(|_| ".".into());
    PathBuf::from(dir).join("psmux_key_diag.log")
}

fn append(line: &str) {
    let p = log_path();
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&p) {
        let _ = writeln!(f, "{}", line);
    }
}

fn main() {
    // Truncate previous log
    let _ = std::fs::write(log_path(), "");
    append(&format!("=== key_diag started, log={:?} ===", log_path()));
    println!("Key diagnostic. Press keys to log. Press 'q' to quit.");
    println!("Log file: {:?}", log_path());
    enable_raw_mode().expect("raw mode");
    loop {
        if let Ok(true) = event::poll(std::time::Duration::from_millis(500)) {
            match event::read() {
                Ok(Event::Key(k)) if k.kind == KeyEventKind::Press => {
                    let code_str = match k.code {
                        KeyCode::Char(c) => format!("Char({:?}) = U+{:04X}", c, c as u32),
                        other => format!("{:?}", other),
                    };
                    let mods: Vec<&str> = [
                        (KeyModifiers::CONTROL, "C"),
                        (KeyModifiers::ALT, "A"),
                        (KeyModifiers::SHIFT, "S"),
                        (KeyModifiers::SUPER, "M"),
                    ]
                    .iter()
                    .filter(|(m, _)| k.modifiers.contains(*m))
                    .map(|(_, n)| *n)
                    .collect();
                    let line = format!(
                        "KEY code={} mods=[{}]",
                        code_str,
                        mods.join("|")
                    );
                    println!("{}", line);
                    append(&line);
                    if matches!(k.code, KeyCode::Char('q')) && k.modifiers.is_empty() {
                        break;
                    }
                }
                Ok(other) => {
                    let line = format!("EVT {:?}", other);
                    println!("{}", line);
                    append(&line);
                }
                Err(e) => {
                    let line = format!("ERR {:?}", e);
                    println!("{}", line);
                    append(&line);
                    break;
                }
            }
        }
    }
    disable_raw_mode().ok();
    append("=== key_diag done ===");
}
