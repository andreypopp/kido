use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::num::NonZeroUsize;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use clap::{Args, Parser, Subcommand};
use ko_pane_wire::frame::Scrollback;
use ko_server::config::{self, Config, DEFAULT_LIMITS};
use ko_server::protocol;
use ko_server::server::{Server, Status, Timing};
use ko_tui::api;
use ko_tui::launch::{self, Patience};

const USAGE_ERROR: u8 = 124;
const PATIENCE: Patience = Patience {
    deadline: Duration::from_secs(5),
    retry: Duration::from_millis(10),
};
const READ_TIMEOUT: Duration = Duration::from_secs(40);

/// The ko terminal server.
#[derive(Debug, Parser)]
#[command(name = "ko")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run the ko server in the foreground.
    Server(ServerArgs),
    /// Stop the ko server.
    KillServer {
        /// The server's state directory.
        #[arg(long, value_name = "DIR")]
        server: Option<PathBuf>,
    },
    /// Print the build, protocol and terminal revisions.
    Version,
    /// Send one HTTP request to the ko server and print the response.
    ///
    /// Sends PATH, which starts with /, to the ko server and prints the response body. Query
    /// strings pass through. The command never starts a server. It exits 0 on a 2xx status. On
    /// any other status it still prints the body, writes "ko api: HTTP" and the status to stderr
    /// and exits 1. It refuses a WebSocket endpoint (/client and /panes/ID/view) and exits 2.
    Api(ApiArgs),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Limit {
    Unlimited,
    At(NonZeroUsize),
}

fn limit(value: &str, count: impl Fn(&str) -> Option<NonZeroUsize>) -> Option<Limit> {
    if value == "unlimited" {
        Some(Limit::Unlimited)
    } else {
        count(value).map(Limit::At)
    }
}

fn bytes(value: &str) -> Result<Limit, String> {
    limit(value, |value| {
        let (digits, scale) = match value.as_bytes().last() {
            Some(b'K') => (&value[..value.len() - 1], 1 << 10),
            Some(b'M') => (&value[..value.len() - 1], 1 << 20),
            Some(b'G') => (&value[..value.len() - 1], 1 << 30),
            _ => (value, 1),
        };
        let count: usize = digits.parse().ok()?;
        NonZeroUsize::new(count.checked_mul(scale)?)
            .filter(|_| count <= isize::MAX as usize / scale)
    })
    .ok_or_else(|| "invalid byte count".to_owned())
}

fn lines(value: &str) -> Result<Limit, String> {
    limit(value, |value| value.parse().ok()).ok_or_else(|| "invalid line count".to_owned())
}

fn default_limits() -> (Option<NonZeroUsize>, Option<NonZeroUsize>) {
    match DEFAULT_LIMITS.scrollback {
        Scrollback::Bounded {
            max_bytes,
            max_lines,
        } => (max_bytes, max_lines),
        Scrollback::Disabled => (None, None),
    }
}

fn shown(limit: Option<NonZeroUsize>) -> String {
    limit.map_or("unlimited".to_owned(), |limit| limit.to_string())
}

#[derive(Debug, Args)]
struct ServerArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    #[arg(
        long,
        value_name = "BYTES|unlimited",
        value_parser = bytes,
        help = format!("Scrollback limit in bytes. The default is {}", shown(default_limits().0))
    )]
    scrollback_bytes: Option<Limit>,
    #[arg(
        long,
        value_name = "N|unlimited",
        value_parser = lines,
        help = format!("Scrollback limit in lines. The default is {}", shown(default_limits().1))
    )]
    scrollback_lines: Option<Limit>,
    /// Keep no scrollback. This conflicts with the two scrollback limits.
    #[arg(long, conflicts_with_all = ["scrollback_bytes", "scrollback_lines"])]
    no_scrollback: bool,
    /// The login shell of the panes.
    #[arg(long, value_name = "PATH")]
    shell: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct ApiArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// The HTTP method. The default is GET, or POST with --input.
    #[arg(long, short = 'X', value_name = "METHOD")]
    method: Option<String>,
    /// Send the file as the request body. - reads standard input.
    #[arg(long, value_name = "FILE")]
    input: Option<PathBuf>,
    /// Print the status line and headers before the body.
    #[arg(long, short = 'i')]
    include: bool,
    /// The request path, with its query string.
    #[arg(value_name = "PATH")]
    path: String,
}

fn fail(name: &str, message: impl std::fmt::Display) -> ExitCode {
    eprintln!("ko {name}: {message}");
    ExitCode::FAILURE
}

fn invoked() -> PathBuf {
    std::env::args_os()
        .next()
        .filter(|arg0| arg0.as_encoded_bytes().contains(&b'/'))
        .map(PathBuf::from)
        .or_else(|| std::env::current_exe().ok())
        .unwrap_or_else(|| PathBuf::from(OsString::from("ko")))
}

fn server(args: ServerArgs) -> ExitCode {
    let (default_bytes, default_lines) = default_limits();
    let chosen = |limit: Option<Limit>, default| match limit {
        None => default,
        Some(Limit::Unlimited) => None,
        Some(Limit::At(count)) => Some(count),
    };
    let scrollback = if args.no_scrollback {
        Scrollback::Disabled
    } else {
        Scrollback::Bounded {
            max_bytes: chosen(args.scrollback_bytes, default_bytes),
            max_lines: chosen(args.scrollback_lines, default_lines),
        }
    };
    let config = match Config::create(&invoked(), args.server, args.shell, scrollback) {
        Ok(config) => config,
        Err(message) => return fail("server", message),
    };
    let served = launch::bind(&config.dir, &config.socket, PATIENCE)
        .and_then(|listener| Server::new(config, listener, Timing::DEFAULT))
        .and_then(|mut server| {
            while server.turn()? == Status::Running {}
            Ok(())
        });
    match served {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => fail("server", error),
    }
}

fn api(args: ApiArgs) -> ExitCode {
    let body = match args.input.as_deref() {
        None => Ok(Vec::new()),
        Some(path) if path.as_os_str() == "-" => {
            let mut body = Vec::new();
            io::stdin().read_to_end(&mut body).map(|_| body)
        }
        Some(path) => std::fs::read(path),
    };
    let body = match body {
        Ok(body) => body,
        Err(error) => return fail("api", error),
    };
    let method = match (args.method, &args.input) {
        (Some(method), _) => method,
        (None, Some(_)) => "POST".to_owned(),
        (None, None) => "GET".to_owned(),
    }
    .to_ascii_uppercase();
    if !args.path.starts_with('/') {
        return fail("api", "path must start with /");
    }
    let dir = config::dir(args.server);
    match api::request(&dir, &method, &args.path, &body, PATIENCE, READ_TIMEOUT) {
        Err(api::Error::Websocket) => {
            eprintln!(
                "ko api: {} is a WebSocket endpoint; ko api sends one request and prints one response",
                args.path
            );
            ExitCode::from(2)
        }
        Err(api::Error::NoServer) => fail("api", format!("no server at {}", dir.display())),
        Err(api::Error::Failed(message)) => fail("api", message),
        Ok(response) => {
            let mut out = io::stdout().lock();
            if args.include {
                let _ = out.write_all(&response.head());
            }
            let _ = out.write_all(&response.body);
            let _ = out.flush();
            if response.status / 100 == 2 {
                ExitCode::SUCCESS
            } else {
                fail("api", format!("HTTP {}", response.status))
            }
        }
    }
}

fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            let _ = error.print();
            return if error.use_stderr() {
                ExitCode::from(USAGE_ERROR)
            } else {
                ExitCode::SUCCESS
            };
        }
    };
    match cli.command {
        Command::Server(args) => server(args),
        Command::KillServer { server } => match launch::stop(&config::dir(server), PATIENCE) {
            Ok(()) => ExitCode::SUCCESS,
            Err(message) => fail("kill-server", message),
        },
        Command::Version => {
            let mut out = io::stdout().lock();
            let _ = writeln!(out, "{}", protocol::json(&protocol::version()));
            ExitCode::SUCCESS
        }
        Command::Api(args) => api(args),
    }
}
