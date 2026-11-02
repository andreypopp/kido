use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::num::NonZeroUsize;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};
use ko_client::api;
use ko_client::launch::{self, PATIENCE};
use ko_client::layout::Document;
use ko_pane_wire::frame::Scrollback;
use ko_server::config::{self, Config, DEFAULT_LIMITS};
use ko_server::protocol::{self, Cause, Route, Row};
use ko_server::server::{Server, Status, Timing};
use ko_tui::client;

const USAGE_ERROR: u8 = 124;

/// The ko terminal. Without a command, it attaches to the server and starts one if none runs.
#[derive(Debug, Parser)]
#[command(name = "ko")]
struct Cli {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    #[command(subcommand)]
    command: Option<Command>,
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
    /// List the panes of the ko server.
    Panes(PanesArgs),
    /// Print the layout document, the sessions and windows with their splits and floats.
    Layout(LayoutArgs),
}

#[derive(Debug, Args)]
struct PanesArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// Print the JSON of GET /panes, not a table.
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Args)]
struct LayoutArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR", global = true)]
    server: Option<PathBuf>,
    #[command(subcommand)]
    command: Option<LayoutCommand>,
}

#[derive(Debug, Subcommand)]
enum LayoutCommand {
    /// Replace the layout with the document in FILE.
    ///
    /// FILE is JSON with a "layout" and, as the output of ko layout has it, a "revision". With a
    /// stale revision, or none, the command takes the server's current revision and sends the
    /// layout again. It prints the normalized document. - reads standard input.
    Put {
        /// The file with the document.
        #[arg(value_name = "FILE")]
        file: PathBuf,
    },
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

fn read_input(path: &std::path::Path) -> io::Result<Vec<u8>> {
    if path.as_os_str() == "-" {
        let mut body = Vec::new();
        io::stdin().read_to_end(&mut body).map(|_| body)
    } else {
        std::fs::read(path)
    }
}

fn server_failure(name: &str, dir: &std::path::Path, failure: api::Failure) -> ExitCode {
    match failure {
        api::Failure::NoServer => fail(name, format!("no server at {}", dir.display())),
        api::Failure::Failed(message) => fail(name, message),
    }
}

fn api(args: ApiArgs) -> ExitCode {
    let body = match args.input.as_deref().map(read_input).transpose() {
        Ok(body) => body.unwrap_or_default(),
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
    match api::request(&dir, &method, &args.path, &body) {
        Err(api::Error::Websocket) => {
            eprintln!(
                "ko api: {} is a WebSocket endpoint; ko api sends one request and prints one response",
                args.path
            );
            ExitCode::from(2)
        }
        Err(api::Error::Server(failure)) => server_failure("api", &dir, failure),
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

fn get(name: &str, server: Option<PathBuf>, route: &Route) -> Result<Vec<u8>, ExitCode> {
    let dir = config::dir(server);
    match api::get(&dir, route) {
        Ok(response) if response.status / 100 == 2 => Ok(response.body),
        Ok(response) => Err(fail(name, format!("HTTP {}", response.status))),
        Err(failure) => Err(server_failure(name, &dir, failure)),
    }
}

fn state(row: &Row) -> String {
    match row.dead.as_ref().map(|dead| &dead.cause) {
        None => "running".to_owned(),
        Some(Cause::Exited { code }) => format!("exited {code}"),
        Some(Cause::Signaled { signal }) => format!("signal {signal}"),
        Some(Cause::Failed { .. }) => "failed".to_owned(),
    }
}

fn panes(args: PanesArgs) -> ExitCode {
    let body = match get("panes", args.server, &Route::ListPanes) {
        Ok(body) => body,
        Err(code) => return code,
    };
    let mut out = io::stdout().lock();
    if args.json {
        let _ = out.write_all(&body);
        let _ = writeln!(out);
        return ExitCode::SUCCESS;
    }
    let rows: Vec<Row> = match protocol::decode(&body) {
        Ok(rows) => rows,
        Err(error) => return fail("panes", error),
    };
    let table: Vec<[String; 5]> =
        std::iter::once(["PANE", "PID", "STATE", "TITLE", "CWD"].map(str::to_owned))
            .chain(rows.iter().map(|row| {
                [
                    row.id.to_string(),
                    row.pid.to_string(),
                    state(row),
                    row.title.clone(),
                    row.cwd.clone(),
                ]
            }))
            .collect();
    let widths: Vec<usize> = (0..4)
        .map(|column| {
            table
                .iter()
                .map(|line| line[column].chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    for line in &table {
        let cells: Vec<String> = (0..4)
            .map(|column| format!("{:width$}", line[column], width = widths[column]))
            .collect();
        let _ = writeln!(out, "{}  {}", cells.join("  "), line[4]);
    }
    ExitCode::SUCCESS
}

fn layout(args: LayoutArgs) -> ExitCode {
    let Some(LayoutCommand::Put { file }) = args.command else {
        return match get("layout", args.server, &Route::GetLayout) {
            Ok(body) => {
                let mut out = io::stdout().lock();
                let _ = out.write_all(&body);
                let _ = writeln!(out);
                ExitCode::SUCCESS
            }
            Err(code) => code,
        };
    };
    let dir = config::dir(args.server);
    let document = read_input(&file)
        .map_err(|error| error.to_string())
        .and_then(|text| protocol::decode::<Document>(&text).map_err(|error| error.to_string()));
    let document = match document {
        Ok(document) => document,
        Err(message) => return fail("layout put", message),
    };
    match api::replace_layout(&dir, &document) {
        Ok(snapshot) => {
            let _ = writeln!(io::stdout().lock(), "{}", protocol::json(&snapshot));
            ExitCode::SUCCESS
        }
        Err(failure) => server_failure("layout put", &dir, failure),
    }
}

fn attach(server: Option<PathBuf>) -> ExitCode {
    let pager = std::env::var("PAGER")
        .ok()
        .filter(|pager| !pager.is_empty())
        .unwrap_or_else(|| "less -R +G -+F".to_owned());
    match client::run(&config::dir(server), &invoked(), &pager) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => fail("attach", message),
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
    let Some(command) = cli.command else {
        return attach(cli.server);
    };
    match command {
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
        Command::Panes(args) => panes(args),
        Command::Layout(args) => layout(args),
    }
}
