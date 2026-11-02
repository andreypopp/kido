use std::io::{BufRead, Write};
use std::time::Duration;

fn name_of(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn emit(text: &str) {
    let mut out = std::io::stdout();
    let _ = out.write_all(text.as_bytes());
    let _ = out.flush();
}

fn session(args: &[String]) {
    emit(&format!("SSH-ARGS:{}\n", args.join(" ")));
    for line in std::io::stdin().lock().lines().map_while(Result::ok) {
        match line.trim() {
            "prompt" => emit("\x1b]133;A\x07"),
            "run" => emit("\x1b]133;C;cmdline_url=sleep 45\x07"),
            "agent" => emit("\x1b]7501;state=idle:app=claude-code\x07\x1b]2;Remote Claude\x07"),
            "exit" => return,
            _ => {}
        }
    }
}

// The e2e suite copies this program under the name of what it stands for, because a foreground
// check reads the process name (a script shows its interpreter's name on macOS).
fn main() {
    let mut args = std::env::args();
    let program = args.next().unwrap_or_default();
    let args: Vec<String> = args.collect();
    match name_of(&program) {
        "ko-probe" => {
            emit("OUT\n");
            std::thread::sleep(Duration::from_secs(1));
        }
        _ => session(&args),
    }
}
