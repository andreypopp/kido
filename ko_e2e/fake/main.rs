use std::io::{BufRead, Read, Write};
use std::os::unix::net::UnixListener;
use std::path::Path;
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

fn mismatch_server(dir: &str) -> std::io::Result<()> {
    let listener = UnixListener::bind(Path::new(dir).join("socket"))?;
    for connection in listener.incoming() {
        let mut connection = connection?;
        if connection
            .set_read_timeout(Some(Duration::from_secs(5)))
            .is_err()
        {
            continue;
        }
        let mut head = Vec::new();
        let mut byte = [0];
        while !head.ends_with(b"\r\n\r\n") && head.len() < 16384 {
            match connection.read(&mut byte) {
                Ok(1) => head.push(byte[0]),
                _ => break,
            }
        }
        if head.is_empty() {
            continue;
        }
        let head = String::from_utf8_lossy(&head).to_ascii_lowercase();
        let (status, body) = if head.starts_with("get /version ")
            && !head.contains("\r\nko-protocol:")
            && !head.contains("\r\nko-vt:")
        {
            (
                "200 OK",
                r#"{"protocol":"1.0","vt":"different","build":"incompatible-test"}"#,
            )
        } else {
            (
                "409 Conflict",
                r#"{"kind":"vt_mismatch","protocol":"1.0","vt":"different","build":"incompatible-test","message":"terminal revision mismatch"}"#,
            )
        };
        let _ = write!(
            connection,
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
    }
    Ok(())
}

// The e2e suite copies this program under the name of what it stands for, because a foreground
// check reads the process name (a script shows its interpreter's name on macOS).
fn main() -> std::io::Result<()> {
    let mut args = std::env::args();
    let program = args.next().unwrap_or_default();
    let args: Vec<String> = args.collect();
    if let [mode, dir] = args.as_slice()
        && mode == "mismatch-server"
    {
        return mismatch_server(dir);
    }
    match name_of(&program) {
        "container" | "podman" => {
            let log = std::env::var_os("KO_FAKE_ENGINE_LOG")
                .ok_or_else(|| std::io::Error::other("no engine log"))?;
            let mut log = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(log)?;
            log.write_all(format!("{}\n", args.join(" ")).as_bytes())?;
            match args
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>()
                .as_slice()
            {
                ["system", "status"] => {}
                ["inspect", _] => {
                    emit(r#"[{"status":{"state":"running"},"configuration":{"mounts":[]}}]"#)
                }
                ["container", "inspect", _] => {
                    emit(r#"[{"State":{"Status":"running"},"Mounts":[]}]"#)
                }
                ["delete" | "rm", "--force", _] | ["stop", _] => {}
                ["run", ..] if args.iter().any(|arg| arg == "--name") => {}
                ["exec", _, _, "version"] => {
                    emit(&std::env::var("KO_FAKE_ENGINE_VERSION").map_err(std::io::Error::other)?)
                }
                ["exec", "-i", _, _, "enter", "--watch"] => {
                    std::io::copy(&mut std::io::stdin().lock(), &mut std::io::sink())?;
                }
                ["exec", "-i", _, _, "enter", "--exec"] => {}
                _ => return Err(std::io::Error::other("unexpected engine argv")),
            }
        }
        "ko-probe" => {
            emit("OUT\n");
            let _ = std::io::stdin().lock().read_line(&mut String::new());
        }
        _ => session(&args),
    }
    Ok(())
}
