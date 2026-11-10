use std::collections::BTreeMap;
use std::io::{self, IsTerminal, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{ArgGroup, Args, Subcommand};
use clap_complete::engine::ArgValueCompleter;
use ko_config::runtime::{
    self, Access, Engine, Kind, Ko, PathMap, Runtime, RuntimePi, Source, SshAgent, Volume,
};
use ko_config::values::{
    AbsPath, Argv, ConnectionArgs, Destination, Env, Init, MountDir, Operand, Prefix, Program,
    RemoteDir, RunArgs, RuntimeColor, RuntimeName, User, VolumePath,
};

use crate::{Target, assignment, fail, inside_runtime, target};

#[derive(Debug, Args)]
#[command(args_conflicts_with_subcommands = true, subcommand_negates_reqs = true)]
pub(crate) struct RunArgsCli {
    #[command(subcommand)]
    kind: Option<RunKind>,
    #[command(flatten)]
    entry: Entry,
}

#[derive(Debug, Args)]
struct Entry {
    /// The runtime's name in the current session.
    #[arg(verbatim_doc_comment, long, required = true, value_parser = |s: &str| RuntimeName::try_from(s.to_owned()), add = ArgValueCompleter::new(crate::complete::runtimes))]
    name: Option<RuntimeName>,
    /// Variables for every pane of the runtime, applied before the variables of the request.
    #[arg(verbatim_doc_comment, long, value_parser = assignment)]
    env: Vec<(String, String)>,
    /// The command to run inside the runtime.
    #[arg(last = true)]
    command: Vec<String>,
}

#[derive(Debug, Subcommand)]
enum RunKind {
    /// A runtime on an ssh host, reached through one ssh master that the first pane logs in.
    /// ko must be installed there, on the PATH of ssh commands.
    Ssh {
        #[arg(value_parser = |s: &str| Destination::try_from(s.to_owned()))]
        destination: Destination,
        #[command(flatten)]
        shared: Shared,
        /// Connection options for the master (`-p`, `-J`, `-F`, `-i`, `-l`, `-o`, ...).
        #[arg(verbatim_doc_comment, long = "ssh-arg", allow_hyphen_values = true)]
        ssh_args: Vec<String>,
        /// The directory on the remote for the forwarded socket and the token files. Default:
        /// `$XDG_RUNTIME_DIR/ko-rt/TAG`, else `/tmp/ko-rt-UID/TAG`.
        /// TAG is the name, or SESSION-NAME for a runtime that ko run defines.
        #[arg(verbatim_doc_comment, long, value_parser = |s: &str| RemoteDir::try_from(s.to_owned()))]
        dir: Option<RemoteDir>,
    },
    /// A container of Apple's `container`, which ko creates from an image or finds by name.
    Container {
        #[command(flatten)]
        shared: Shared,
        #[command(flatten)]
        options: ContainerArgs,
        /// The `container` program. Default: `container` on the PATH of the server.
        #[arg(verbatim_doc_comment, long, value_parser = |s: &str| Program::try_from(s.to_owned()))]
        program: Option<Program>,
        /// The host's agent at /var/host-services/ssh-auth.sock (`--ssh`).
        #[arg(verbatim_doc_comment, long, default_value = "none", value_parser = |s: &str| ko_server::protocol::decode::<SshAgent>(ko_server::protocol::json(&s).as_bytes()).map_err(|error| error.to_string()))]
        ssh_agent: SshAgent,
    },
    /// A Podman container on a Linux server.
    Podman {
        #[command(flatten)]
        shared: Shared,
        #[command(flatten)]
        options: ContainerArgs,
        /// The `podman` program. Default: `podman` on the PATH of the server.
        #[arg(verbatim_doc_comment, long, value_parser = |s: &str| Program::try_from(s.to_owned()))]
        program: Option<Program>,
    },
    /// A runtime on the host, for the tests of the link machinery. The server accepts it only
    /// with KO_RUNTIME_COMMAND_KIND=1 in its environment.
    Command {
        #[command(flatten)]
        shared: Shared,
        /// The argv that goes before `ko enter` in a pane's program.
        #[arg(verbatim_doc_comment, long, num_args = 1.., allow_hyphen_values = true)]
        prefix: Vec<String>,
        /// Where the runtime's socket is reached inside the runtime. Default: the host path.
        #[arg(verbatim_doc_comment, long, value_parser = |s: &str| AbsPath::try_from(s.to_owned()))]
        socket: Option<AbsPath>,
        /// A step of the start that the server runs as its own child. Exit 0 continues the start.
        #[arg(verbatim_doc_comment, long, num_args = 1.., allow_hyphen_values = true)]
        up: Option<Vec<String>>,
    },
}

#[derive(Debug, Args)]
struct Shared {
    #[command(flatten)]
    entry: Entry,
    /// The directory inside the runtime for a pane whose request names none that maps.
    #[arg(verbatim_doc_comment, long, value_parser = |s: &str| AbsPath::try_from(s.to_owned()))]
    cwd: Option<AbsPath>,
    /// A host directory that a host caller names as cwd maps to the runtime directory of the
    /// longest matching host prefix.
    #[arg(verbatim_doc_comment, long = "path", value_parser = path_map)]
    paths: Vec<PathMap>,
    /// Where pi runs for an agent in this runtime.
    #[arg(verbatim_doc_comment, long, default_value = "host", value_parser = |s: &str| ko_server::protocol::decode::<RuntimePi>(ko_server::protocol::json(&s).as_bytes()).map_err(|error| error.to_string()))]
    pi: RuntimePi,
    /// How clients draw the runtime. Default: a colour that each client derives from the name.
    #[arg(verbatim_doc_comment, long, value_parser = |s: &str| RuntimeColor::try_from(s.to_owned()))]
    color: Option<RuntimeColor>,
}

#[derive(Debug, Args)]
#[group(skip)]
#[command(group(ArgGroup::new("from").required(true).args(["from_image", "from_container"])))]
struct ContainerArgs {
    /// A container that ko creates from the image and owns: down stops it and DELETE removes it.
    #[arg(verbatim_doc_comment, long, value_parser = |s: &str| Operand::try_from(s.to_owned()))]
    from_image: Option<Operand>,
    /// A container that the user created with the runtime socket shared and manages.
    #[arg(verbatim_doc_comment, long, value_parser = |s: &str| Operand::try_from(s.to_owned()))]
    from_container: Option<Operand>,
    /// A directory of the host that the container mounts, files only: never a socket.
    #[arg(verbatim_doc_comment, long = "volume", value_parser = volume)]
    volumes: Vec<Volume>,
    /// The user of every exec, as the engine's `exec -u` takes it. Default: the image's.
    #[arg(verbatim_doc_comment, long, value_parser = |s: &str| User::try_from(s.to_owned()))]
    user: Option<User>,
    /// More arguments of the engine's `run`. ko refuses the options it owns.
    #[arg(verbatim_doc_comment, long = "run-arg", allow_hyphen_values = true)]
    run_args: Vec<String>,
    /// The command that keeps the container alive.
    #[arg(verbatim_doc_comment, long, num_args = 1.., allow_hyphen_values = true)]
    init: Option<Vec<String>>,
    /// The static Linux ko beside the server's installation, the ko on PATH, or mount=DIR.
    #[arg(verbatim_doc_comment, long, default_value = "shipped", value_parser = inner_ko)]
    ko: Ko,
}

fn path_map(s: &str) -> Result<PathMap, String> {
    let (host, runtime) = s.split_once(':').ok_or("use HOST:RUNTIME")?;
    Ok(PathMap {
        host: AbsPath::try_from(host.to_owned())?,
        runtime: AbsPath::try_from(runtime.to_owned())?,
    })
}

fn volume(s: &str) -> Result<Volume, String> {
    let (s, options) = match s.strip_suffix(":ro") {
        Some(s) => (s, Some(Access::Ro)),
        None => (s, None),
    };
    let (host, runtime) = s.split_once(':').ok_or("use HOST:RUNTIME[:ro]")?;
    Ok(Volume {
        host: VolumePath::try_from(host.to_owned())?,
        runtime: VolumePath::try_from(runtime.to_owned())?,
        options,
    })
}

fn inner_ko(s: &str) -> Result<Ko, String> {
    if let Some(dir) = s.strip_prefix("mount=") {
        return MountDir::try_from(dir.to_owned()).map(Ko::Mount);
    }
    ko_server::protocol::decode(ko_server::protocol::json(&s).as_bytes())
        .map_err(|error| error.to_string())
}

#[derive(Debug)]
enum ContainerKind {
    Apple(SshAgent),
    Podman,
}

impl ContainerArgs {
    fn definition(self, program: Option<Program>, kind: ContainerKind) -> Result<Kind, String> {
        let from = self
            .from_image
            .map(Source::Image)
            .or_else(|| self.from_container.map(Source::Container))
            .ok_or("give --from-image or --from-container")?;
        let run_args = RunArgs::try_from(self.run_args)?;
        let init = self
            .init
            .map(Init::try_from)
            .transpose()?
            .unwrap_or_default();
        let engine = match kind {
            ContainerKind::Apple(ssh_agent) => Engine::Apple(runtime::Container {
                from,
                container: program,
                volumes: self.volumes,
                user: self.user,
                run_args,
                init,
                ssh_agent,
                ko: self.ko,
            }),
            ContainerKind::Podman => Engine::Podman(runtime::Podman {
                from,
                podman: program,
                volumes: self.volumes,
                user: self.user,
                run_args,
                init,
                ko: self.ko,
            }),
        };
        Ok(Kind::Container(engine))
    }
}

impl RunArgsCli {
    fn definition(self) -> Result<(Entry, Option<Runtime>), String> {
        let Some(kind) = self.kind else {
            return Ok((self.entry, None));
        };
        let (shared, kind) = match kind {
            RunKind::Ssh {
                shared,
                destination,
                ssh_args,
                dir,
            } => (
                shared,
                Kind::Ssh(runtime::Ssh {
                    destination,
                    ssh_args: ConnectionArgs::try_from(ssh_args)?,
                    dir,
                }),
            ),
            RunKind::Command {
                shared,
                prefix,
                socket,
                up,
            } => (
                shared,
                Kind::Command(runtime::Command {
                    prefix: Prefix::try_from(prefix)?,
                    socket,
                    up: up.map(Argv::try_from).transpose()?,
                }),
            ),
            RunKind::Container {
                shared,
                options,
                program,
                ssh_agent,
            } => (
                shared,
                options.definition(program, ContainerKind::Apple(ssh_agent))?,
            ),
            RunKind::Podman {
                shared,
                options,
                program,
            } => (shared, options.definition(program, ContainerKind::Podman)?),
        };
        let mut entry = shared.entry;
        let runtime = Runtime {
            env: Env::try_from(
                std::mem::take(&mut entry.env)
                    .into_iter()
                    .collect::<BTreeMap<_, _>>(),
            )?,
            cwd: shared.cwd,
            paths: shared.paths,
            pi: shared.pi,
            color: shared.color,
            kind,
        };
        Ok((entry, Some(runtime)))
    }
}

pub(crate) fn run(args: RunArgsCli, server: Option<PathBuf>) -> ExitCode {
    if let Some(runtime) = inside_runtime() {
        return fail(
            "run",
            format!(
                "inside runtime {}; run it from a host pane",
                runtime.to_string_lossy()
            ),
        );
    }
    let (Entry { name, command, env }, runtime) = match args.definition() {
        Ok(definition) => definition,
        Err(error) => return fail("run", error),
    };
    let Some(name) = name else {
        return fail("run", "give --name");
    };
    let requested_env = env
        .into_iter()
        .map(|(name, value)| ko_server::protocol::Variable { name, value })
        .collect();
    let Target { dir, caller } = target(server);
    let Some(caller) = caller else {
        return fail("run", "needs a pane");
    };
    if !io::stdin().is_terminal() {
        return fail("run", "needs the pane's terminal");
    }
    if let Some(runtime) = runtime
        && let Err(error) =
            ko_client::api::put_runtime(&dir, Some(caller.clone()), name.clone(), &runtime)
    {
        return fail("run", ko_client::api::describe(&dir, error));
    }
    let cwd = match std::env::current_dir()
        .map_err(|error| error.to_string())
        .and_then(|path| AbsPath::try_from(path.to_string_lossy().into_owned()))
    {
        Ok(cwd) => cwd,
        Err(error) => return fail("run", error),
    };
    let escalation = ko_server::config::stop_escalation() / 2;
    let request = ko_server::protocol::VisitRequest {
        cwd,
        command: (!command.is_empty()).then_some(command),
        env: requested_env,
    };
    let mut shown = || {
        let _ = writeln!(io::stderr().lock(), "starting runtime {name}");
    };
    match ko_client::visit::visit(
        &dir,
        caller,
        &name,
        request,
        escalation,
        &crate::transport_env(),
        &mut shown,
    ) {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(message) => {
            let _ = writeln!(io::stderr().lock(), "runtime {name}: {message}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn option_help_matches_the_configuration_schema() {
        use clap::CommandFactory;
        let schema = ko_server::protocol::decode::<ko_server::vars::Loose>(
            ko_config::config::schema().as_bytes(),
        )
        .unwrap();
        let defs = &schema["$defs"];
        let cli = crate::Cli::command();
        let run = cli.find_subcommand("run").unwrap();
        let normalized = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
        for (kind, record) in [
            ("ssh", "Ssh"),
            ("container", "Container"),
            ("podman", "Podman"),
            ("command", "Command"),
        ] {
            for arg in run.find_subcommand(kind).unwrap().get_arguments() {
                let id = arg.get_id().as_str();
                let field = match id {
                    "name" | "server" | "help" | "command" => continue,
                    "env" | "cwd" | "paths" | "pi" | "color" => &defs["Runtime"]["properties"][id],
                    "from_image" => &defs["Source"]["oneOf"][0],
                    "from_container" => &defs["Source"]["oneOf"][1],
                    "volumes" => &defs["Volume"],
                    "program" => &defs[record]["properties"][kind],
                    _ => &defs[record]["properties"][id],
                };
                assert!(!field.is_null(), "{kind} {id} has no schema field");
                let help = arg
                    .get_long_help()
                    .or(arg.get_help())
                    .map(|help| normalized(&help.to_string()));
                let description = field["description"].as_str().map(normalized);
                assert_eq!(help, description, "{kind} {id}");
            }
        }
    }

    #[test]
    fn container_options_build_the_yaml_definition() {
        let cli = crate::Cli::try_parse_from([
            "ko",
            "run",
            "container",
            "--name",
            "dev",
            "--from-image",
            "I",
            "--volume",
            "/a:/b:ro",
        ])
        .unwrap();
        let Some(crate::Command::Run(args)) = cli.command else {
            panic!("not run")
        };
        assert!(
            crate::Cli::try_parse_from(["ko", "run", "--name", "a", "command", "--name", "b"])
                .is_err()
        );
        let join =
            crate::Cli::try_parse_from(["ko", "run", "--name", "dev", "--env", "A=B", "--", "sh"])
                .unwrap();
        let Some(crate::Command::Run(join)) = join.command else {
            panic!("not run")
        };
        let (entry, definition) = join.definition().unwrap();
        assert!(definition.is_none());
        assert_eq!(entry.command, ["sh"]);
        assert_eq!(entry.env, [("A".to_owned(), "B".to_owned())]);
        let (_, actual) = args.definition().unwrap();
        let file =
            std::env::temp_dir().join(format!("ko-run-definition-{}.yaml", std::process::id()));
        std::fs::write(&file, "runtimes:\n  dev:\n    container:\n      from: {image: I}\n      volumes: [{host: /a, runtime: /b, options: ro}]\n").unwrap();
        let config = ko_config::config::load(&file).unwrap();
        std::fs::remove_file(file).unwrap();
        assert_eq!(
            actual.unwrap(),
            config.runtimes[&RuntimeName::try_from("dev".to_owned()).unwrap()]
        );
    }
}
