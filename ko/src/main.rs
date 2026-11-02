use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::num::NonZeroUsize;
use std::os::fd::AsFd;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};
use ko_client::api;
use ko_client::launch::{self, PATIENCE};
use ko_pane_wire::frame::Scrollback;
use ko_server::config::{self, Config, DEFAULT_LIMITS};
use ko_server::protocol;
use ko_server::server::{Server, Status, Timing};
use ko_shell::{bin_dir, shell, ssh};
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
    /// Exec the primed login shell, or run a command through an interactive login shell.
    ///
    /// Without a command, ko shell execs the login shell, primed to report each command to ko.
    /// With a command, the command runs through an interactive login shell without priming, with
    /// the ko bin directory first on PATH.
    Shell {
        /// The command and its arguments, after --.
        #[arg(last = true, value_name = "CMD")]
        command: Vec<String>,
    },
    /// Run ssh, priming the remote login shell when it can.
    ///
    /// Inside a pane, ko ssh records the destination and the connection arguments as the pane
    /// variables ssh.dest and ssh.args.
    Ssh {
        /// The arguments of ssh, options included.
        #[arg(
            allow_hyphen_values = true,
            trailing_var_arg = true,
            value_name = "ARG"
        )]
        args: Vec<OsString>,
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
    /// The directory of the ko shims, put first on the PATH of every pane. The default is
    /// share/ko/bin beside the installed ko, if it exists.
    #[arg(long, value_name = "DIR")]
    bin_dir: Option<PathBuf>,
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
    let config = match Config::create(
        &invoked(),
        args.server,
        args.shell,
        args.bin_dir.or_else(|| bin_dir::of_exe(&invoked())),
        scrollback,
    ) {
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
    match api::request(&dir, &method, &args.path, &body) {
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

fn ssh(args: &[OsString]) -> ExitCode {
    let path = std::env::var("PATH").unwrap_or_default();
    let found = match bin_dir::of_exe(&invoked()) {
        Some(dir) => bin_dir::look_path_past(&path, &dir, "ssh")
            .ok_or_else(|| format!("no ssh on PATH past {}", dir.display())),
        None => bin_dir::look_path(&path, "ssh").ok_or_else(|| "ssh not found on PATH".to_owned()),
    };
    let ssh_path = match found {
        Ok(found) => found,
        Err(message) => return fail("ssh", message),
    };
    let tty = io::stdin()
        .as_fd()
        .try_clone_to_owned()
        .and_then(|fd| std::fs::File::from(fd).metadata())
        .is_ok_and(|meta| meta.file_type().is_char_device());
    let pane = std::env::var_os("KO_PANE")
        .zip(std::env::var_os("KO_SOCKET"))
        .and_then(|(id, socket)| {
            Some(ssh::Pane {
                dir: PathBuf::from(socket).parent()?.to_path_buf(),
                id: id.into_string().ok()?.parse().ok()?,
            })
        });
    let argv = ssh::prepare(&ssh_path, tty, pane.as_ref(), args);
    let Some((first, rest)) = argv.split_first() else {
        return fail("ssh", "no arguments");
    };
    fail(
        "ssh",
        std::process::Command::new(&ssh_path)
            .arg0(first)
            .args(rest)
            .exec(),
    )
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
        Command::Shell { command } => fail("shell", shell::exec(&command, &invoked())),
        Command::Ssh { args } => ssh(&args),
    }
}
