use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};
use ko_client::api;
use ko_client::edit::Edit;
use ko_client::launch::{self, PATIENCE};
use ko_client::layout::Document;
use ko_client::remote::Remote;
use ko_client::wire::{Caller, Link};
use ko_server::agent;
use ko_server::api::Route;
use ko_server::config::{self, Config};
use ko_server::ids::PaneId;
use ko_server::protocol::{self, Cause, Row};
use ko_server::schema;
use ko_server::server::{Server, Status, Timing};
use ko_shell::{bin_dir, shell, ssh};
use ko_sys::signal::{Signal, Signals};
use ko_tui::client;

mod prompt;
mod run;
mod runtime;

const USAGE_ERROR: u8 = 124;

/// The ko terminal. Without a command, it attaches to the server and starts one if none runs.
///
/// With HOST, ko attaches over ssh to the ko server that already runs on HOST. It forwards the
/// server's unix socket through an ssh master connection, and it reconnects when the connection
/// ends. It never starts a server on HOST: run "ssh HOST ko server" for that.
#[derive(Debug, Parser)]
#[command(name = "ko")]
struct Cli {
    /// The server's state directory.
    #[arg(long, value_name = "DIR", conflicts_with = "host")]
    server: Option<PathBuf>,
    /// The host to attach to over ssh, as ssh names it.
    #[arg(value_name = "HOST")]
    host: Option<String>,
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
    /// Print the OpenAPI 3.1 description of the HTTP and WebSocket interface.
    ///
    /// The command needs no running server. The WebSocket endpoints are GET operations with a 101
    /// response and the x-ko-websocket extension, which names the schemas of their messages.
    ApiSchema {
        /// Print the schema of the client core's model and edit documents instead.
        #[arg(long, group = "schema")]
        client: bool,
        /// Print the JSON schema of the configuration file config.yaml instead.
        #[arg(long, group = "schema")]
        config: bool,
    },
    /// Send one HTTP request to the ko server and print the response.
    ///
    /// Sends PATH, which starts with /, to the ko server and prints the response body. Query
    /// strings pass through. The command never starts a server. It exits 0 on a 2xx status. On
    /// any other status it still prints the body, writes "ko api: HTTP" and the status to stderr
    /// and exits 1. It refuses a WebSocket endpoint (/client and /panes/ID/view) and exits 2.
    ///
    /// With --stream, the command upgrades a WebSocket endpoint instead and prints each text
    /// message as one line. Each non-empty line of standard input goes to the server as one text
    /// message; at the end of standard input the command sends nothing more and goes on printing.
    /// It exits 0 when the server closes the socket with the normal close
    /// code 1000. It exits 1 on any other end (another close code, no close frame, a lost
    /// connection, a binary message) and writes "ko api: closed:" and the code and reason for a
    /// close. On a refused upgrade it prints the error body and exits 1, as for a status that is
    /// not 2xx.
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
    /// Define a runtime of the current session. Panes and agents use it by name.
    Run(run::RunArgsCli),
    /// Start a pane's program inside its runtime.
    #[command(hide = true)]
    Enter(runtime::EnterArgs),
    /// Wait for a pane's runtime to be up, then run the program.
    #[command(hide = true)]
    RuntimeExec(runtime::RuntimeExecArgs),
    /// List the panes of the ko server.
    Panes(PanesArgs),
    /// Print the layout document, the sessions and windows with their splits and floats.
    Layout(LayoutArgs),
    /// Send a prompt, read from stdin, to the agent in the caller's window or session.
    Prompt(prompt::PromptArgs),
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
    /// Apply one edit to the layout, as Kido.app does for a gesture.
    ///
    /// EDIT is the JSON of one Edit of share/ko/client-model.json, such as
    /// {"type":"split","pane":"pane_1","axis":"h","new":{}}. When the layout changed meanwhile, the
    /// edit is applied again to the newer document. It prints the normalized document and what the
    /// edit made.
    Edit {
        /// The edit.
        #[arg(value_name = "EDIT")]
        edit: String,
    },
}

#[derive(Debug, Args)]
struct ServerArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR")]
    server: Option<PathBuf>,
    /// The directory of the ko shims, put first on the PATH of every pane. The default is
    /// share/ko/bin beside the installed ko, if it exists.
    #[arg(long, value_name = "DIR")]
    bin_dir: Option<PathBuf>,
    /// The configuration file, in YAML. The default is $XDG_CONFIG_HOME/ko/config.yaml, else
    /// ~/.config/ko/config.yaml.
    #[arg(long, value_name = "FILE")]
    config: Option<PathBuf>,
    /// Print the absolute socket path. Start nothing unless --ensure is set.
    #[arg(long)]
    print_socket: bool,
    /// Start the server in the background when none answers, then print its socket.
    #[arg(long, requires = "print_socket", conflicts_with_all = ["bin_dir", "config"])]
    ensure: bool,
}

#[derive(Debug, Args)]
struct ApiArgs {
    /// The server's state directory.
    #[arg(long, value_name = "DIR", conflicts_with = "host")]
    server: Option<PathBuf>,
    /// Send the request to the ko server on HOST, over an ssh forward that ko opens for this one
    /// request.
    #[arg(long, value_name = "HOST")]
    host: Option<String>,
    /// The HTTP method. The default is GET, or POST with --input.
    #[arg(long, short = 'X', value_name = "METHOD")]
    method: Option<String>,
    /// Send the file as the request body. - reads standard input.
    #[arg(long, value_name = "FILE")]
    input: Option<PathBuf>,
    /// Print the status line and headers before the body.
    #[arg(long, short = 'i')]
    include: bool,
    /// Upgrade a WebSocket endpoint and print each text message as one line, until the server
    /// closes the socket.
    #[arg(long, conflicts_with_all = ["method", "input", "include"])]
    stream: bool,
    /// The request path, with its query string.
    #[arg(value_name = "PATH")]
    path: String,
}

pub(crate) struct Target {
    pub(crate) dir: PathBuf,
    pub(crate) caller: Option<Caller>,
}

pub(crate) fn target(server: Option<PathBuf>) -> Target {
    let own = std::env::var_os("KO_SOCKET")
        .map(PathBuf::from)
        .and_then(|socket| socket.parent().map(std::path::Path::to_path_buf));
    let dir = config::dir(server.or_else(|| own.clone()));
    let same = |path: &std::path::Path| path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let pane = std::env::var("KO_PANE")
        .ok()
        .and_then(|pane| pane.parse::<PaneId>().ok())
        .filter(|_| own.as_deref().map(same) == Some(same(&dir)));
    let caller = pane.and_then(|pane| {
        let token = std::env::var("KO_PANE_TOKEN").ok()?.parse().ok()?;
        Some(Caller { pane, token })
    });
    Target { dir, caller }
}

pub(crate) fn complain(message: impl std::fmt::Display) {
    let _ = writeln!(io::stderr().lock(), "{message}");
}

pub(crate) fn assignment(text: &str) -> Result<(String, String), String> {
    match text.split_once('=') {
        Some((name, value)) if !name.is_empty() => Ok((name.to_owned(), value.to_owned())),
        _ => Err("want K=V".to_owned()),
    }
}

pub(crate) fn say(text: &str) {
    let _ = writeln!(io::stdout().lock(), "{text}");
}

pub(crate) fn fail_before_program(
    name: &str,
    message: impl std::fmt::Display,
    socket: &std::path::Path,
    caller: Option<&Caller>,
) -> ExitCode {
    keep_failed_pane(socket, caller);
    fail(name, message)
}

pub(crate) fn keep_failed_pane(socket: &std::path::Path, caller: Option<&Caller>) {
    if let Some(caller) = caller {
        let _ = api::patch_pane(
            socket,
            caller.clone(),
            &protocol::PanePatch {
                close: Some(protocol::Close::Keep),
            },
        );
    }
}

pub(crate) fn fail(name: &str, message: impl std::fmt::Display) -> ExitCode {
    complain(format_args!("ko {name}: {message}"));
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
    if args.print_socket {
        let socket = std::path::absolute(config::dir(args.server))
            .map_err(|error| error.to_string())
            .and_then(|dir| {
                if args.ensure {
                    launch::attach(&dir, &invoked(), None, PATIENCE).map(|(socket, _)| socket)
                } else {
                    config::socket_path(&dir)
                }
            });
        return match socket {
            Ok(socket) => {
                let _ = writeln!(io::stdout().lock(), "{}", socket.display());
                ExitCode::SUCCESS
            }
            Err(message) => fail("server", message),
        };
    }
    let config = match Config::create(
        &invoked(),
        args.server,
        args.bin_dir.or_else(|| bin_dir::of_exe(&invoked())),
        args.config,
    ) {
        Ok(config) => config,
        Err(message) => return fail("server", message),
    };
    if let Err(error) = agent::publish(&config.dir, std::env::var_os("SSH_AUTH_SOCK").as_deref()) {
        complain(format_args!("ko server: SSH_AUTH_SOCK: {error}"));
    }
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

pub(crate) fn server_message(dir: &std::path::Path, failure: api::Failure) -> String {
    match failure {
        api::Failure::NoServer => format!("no server at {}", dir.display()),
        api::Failure::Failed(message) => message,
    }
}

fn server_failure(name: &str, dir: &std::path::Path, failure: api::Failure) -> ExitCode {
    fail(name, server_message(dir, failure))
}

pub(crate) fn table(rows: &[Vec<String>]) {
    let widths: Vec<usize> = (0..rows.first().map_or(0, Vec::len))
        .map(|column| {
            rows.iter()
                .map(|row| row.get(column).map_or(0, |cell| cell.chars().count()))
                .max()
                .unwrap_or(0)
        })
        .collect();
    let mut out = io::stdout().lock();
    for row in rows {
        let line: Vec<String> = row
            .iter()
            .enumerate()
            .map(|(at, cell)| match widths.get(at) {
                Some(width) if at + 1 < row.len() => format!("{cell:width$}"),
                _ => cell.clone(),
            })
            .collect();
        let _ = writeln!(out, "{}", line.join("  "));
    }
}

fn stream(link: Link) -> ExitCode {
    let mut out = io::stdout().lock();
    let ended = api::forward(link, io::stdin().as_fd(), |text| {
        writeln!(out, "{text}").and_then(|()| out.flush())
    });
    match ended {
        Ok(Some((1000, _))) => ExitCode::SUCCESS,
        Ok(Some((code, reason))) => fail("api", format!("closed: {code} {reason}")),
        Ok(None) => fail("api", "closed: no close frame"),
        Err(error) => fail("api", error),
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
    let remote = match args.host.as_deref().map(open_remote).transpose() {
        Ok(remote) => remote,
        Err(code) => return code,
    };
    let Target { dir, caller } = match &remote {
        Some((remote, _)) => Target {
            dir: remote.dir().to_path_buf(),
            caller: None,
        },
        None => target(args.server),
    };
    let response = if args.stream {
        match api::stream(&dir, caller, &args.path) {
            Ok(Ok(link)) => return stream(link),
            Ok(Err(response)) => Ok(response),
            Err(error) => Err(error),
        }
    } else {
        api::request(&dir, caller, &method, &args.path, &body)
    };
    match response {
        Err(api::Error::Websocket) => {
            complain(format_args!(
                "ko api: {} is a WebSocket endpoint; ko api sends one request and prints one response",
                args.path
            ));
            ExitCode::from(2)
        }
        Err(api::Error::NotWebsocket) => {
            fail("api", format!("{} is not a WebSocket endpoint", args.path))
        }
        Err(api::Error::Server(failure)) => match &remote {
            Some((remote, _)) => fail(remote.host(), remote.unreachable()),
            None => server_failure("api", &dir, failure),
        },
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

fn ssh_binary() -> Result<PathBuf, String> {
    let path = std::env::var("PATH").unwrap_or_default();
    match bin_dir::of_exe(&invoked()) {
        Some(dir) => bin_dir::look_path_past(&path, &dir, "ssh")
            .ok_or_else(|| format!("no ssh on PATH past {}", dir.display())),
        None => config::look_path(&path, "ssh").ok_or_else(|| "ssh not found on PATH".to_owned()),
    }
}

fn open_remote(host: &str) -> Result<(Remote, Signals), ExitCode> {
    let signals = Signals::install(&[
        Signal::Hup,
        Signal::Term,
        Signal::Int,
        Signal::Quit,
        Signal::Child,
    ])
    .map_err(|error| fail(host, error))?;
    let ssh = ssh_binary().map_err(|message| fail(host, message))?;
    Remote::open(host, &ssh, &config::dir(None), &signals)
        .map(|remote| (remote, signals))
        .map_err(|error| fail(host, error))
}

fn ssh(args: &[OsString]) -> ExitCode {
    let ssh_path = match ssh_binary() {
        Ok(found) => found,
        Err(message) => return fail("ssh", message),
    };
    let tty = io::stdin()
        .as_fd()
        .try_clone_to_owned()
        .and_then(|fd| std::fs::File::from(fd).metadata())
        .is_ok_and(|meta| meta.file_type().is_char_device());
    let Target { dir, caller } = target(None);
    let pane = caller.map(|caller| ssh::Pane { dir, caller });
    let terminfo = bin_dir::terminfo_entry(&invoked());
    let argv = ssh::prepare(tty, pane.as_ref(), args, terminfo.as_deref());
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

fn get(name: &str, server: Option<PathBuf>, route: &Route) -> Result<Vec<u8>, ExitCode> {
    let Target { dir, caller } = target(server);
    match api::get(&dir, caller, route) {
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
    let body = match get("panes", args.server, &Route::ListPanes {}) {
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
    let mut lines = vec![
        ["PANE", "PID", "STATE", "RUNTIME", "TITLE", "CWD"]
            .map(str::to_owned)
            .to_vec(),
    ];
    lines.extend(rows.iter().map(|row| {
        vec![
            row.id.to_string(),
            row.pid
                .map_or_else(|| "-".to_owned(), |pid| pid.to_string()),
            state(row),
            row.runtime
                .as_ref()
                .map_or_else(|| "-".to_owned(), ToString::to_string),
            row.title.clone(),
            row.cwd.clone(),
        ]
    }));
    table(&lines);
    ExitCode::SUCCESS
}

fn layout(args: LayoutArgs) -> ExitCode {
    let file = match args.command {
        None => {
            return match get("layout", args.server, &Route::GetLayout {}) {
                Ok(body) => {
                    let mut out = io::stdout().lock();
                    let _ = out.write_all(&body);
                    let _ = writeln!(out);
                    ExitCode::SUCCESS
                }
                Err(code) => code,
            };
        }
        Some(LayoutCommand::Edit { edit }) => return layout_edit(args.server, &edit),
        Some(LayoutCommand::Put { file }) => file,
    };
    let Target { dir, caller } = target(args.server);
    let document = read_input(&file)
        .map_err(|error| error.to_string())
        .and_then(|text| protocol::decode::<Document>(&text).map_err(|error| error.to_string()));
    let document = match document {
        Ok(document) => document,
        Err(message) => return fail("layout put", message),
    };
    match api::replace_layout(&dir, caller, &document) {
        Ok(snapshot) => {
            let _ = writeln!(io::stdout().lock(), "{}", protocol::json(&snapshot));
            ExitCode::SUCCESS
        }
        Err(failure) => server_failure("layout put", &dir, failure),
    }
}

fn layout_edit(server: Option<PathBuf>, edit: &str) -> ExitCode {
    let edit = match protocol::decode::<Edit>(edit.as_bytes()) {
        Ok(edit) => edit,
        Err(error) => return fail("layout edit", error),
    };
    let Target { dir, caller } = target(server);
    match api::edit_layout(&dir, caller, &edit) {
        Ok(edited) => {
            let _ = writeln!(io::stdout().lock(), "{}", protocol::json(&edited));
            ExitCode::SUCCESS
        }
        Err(failure) => server_failure("layout edit", &dir, failure),
    }
}

pub(crate) fn inside_runtime() -> Option<OsString> {
    std::env::var_os("KO_RUNTIME").filter(|runtime| !runtime.is_empty())
}

fn attach(server: Option<PathBuf>, host: Option<String>) -> ExitCode {
    if let Some(runtime) = inside_runtime() {
        complain(format_args!(
            "ko: inside runtime {}; attach from the host",
            runtime.to_string_lossy()
        ));
        return ExitCode::FAILURE;
    }
    let pager = std::env::var("PAGER")
        .ok()
        .filter(|pager| !pager.is_empty())
        .unwrap_or_else(|| "less -R +G -+F".to_owned());
    let attached = match &host {
        None => client::run(&config::dir(server), &invoked(), &pager),
        Some(host) => {
            ssh_binary().and_then(|ssh| client::run_remote(host, &ssh, &config::dir(None), &pager))
        }
    };
    match attached {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => fail(host.as_deref().unwrap_or("attach"), message),
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
        return attach(cli.server, cli.host);
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
        Command::ApiSchema {
            client: false,
            config: true,
        } => {
            say(&ko_config::config::schema());
            ExitCode::SUCCESS
        }
        Command::ApiSchema {
            client: false,
            config: false,
        } => {
            say(&schema::openapi());
            ExitCode::SUCCESS
        }
        Command::ApiSchema { client: true, .. } => match ko_client::schema::client_model() {
            Ok(document) => {
                let _ = writeln!(io::stdout().lock(), "{document}");
                ExitCode::SUCCESS
            }
            Err(message) => fail("api-schema", message),
        },
        Command::Api(args) => api(args),
        Command::Shell { command } => {
            let error = shell::exec(&command, &invoked());
            let target = target(None);
            fail_before_program(
                "shell",
                error,
                &target.dir.join("socket"),
                target.caller.as_ref(),
            )
        }
        Command::Ssh { args } => ssh(&args),
        Command::Enter(args) => runtime::enter(args),
        Command::RuntimeExec(args) => runtime::runtime_exec(args),
        Command::Run(args) => run::run(args),
        Command::Panes(args) => panes(args),
        Command::Layout(args) => layout(args),
        Command::Prompt(args) => prompt::prompt(args),
    }
}
