use schemars::{JsonSchema, Schema, SchemaGenerator};
use serde::{Deserialize, Serialize};

use crate::values::{
    AbsPath, Argv, ConnectionArgs, Destination, Env, Init, MountDir, Operand, Prefix, Program,
    RemoteDir, RunArgs, RuntimeColor, User, VolumePath,
};

/// A directory of the host and the directory of the runtime that holds the same files.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PathMap {
    pub host: AbsPath,
    pub runtime: AbsPath,
}

/// Where an agent's pi runs when it works in a runtime.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RuntimePi {
    /// On the host. Its built-in tools and `!` commands run in the runtime through exec sessions.
    #[default]
    Host,
    /// Inside the runtime, in a pane of the runtime.
    Runtime,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(extend("oneOf" = [{"required": ["ssh"], "properties": {"ssh": {"type": "object"}}}, {"required": ["container"], "properties": {"container": {"type": "object"}}}, {"required": ["command"], "properties": {"command": {"type": "object"}}}, {"required": ["podman"], "properties": {"podman": {"type": "object"}}}]))]
struct RawRuntime {
    /// Variables for every pane of the runtime, applied before the variables of the request.
    #[serde(default)]
    env: Env,
    /// The directory inside the runtime for a pane whose request names none that maps.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cwd: Option<AbsPath>,
    /// A host directory that a host caller names as cwd maps to the runtime directory of the
    /// longest matching host prefix.
    #[serde(default)]
    paths: Vec<PathMap>,
    /// Where pi runs for an agent in this runtime.
    #[serde(default)]
    pi: RuntimePi,
    /// How clients draw the runtime. Default: a colour that each client derives from the name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    color: Option<RuntimeColor>,
    /// A runtime on an ssh host, reached through one ssh master that the first pane logs in.
    /// ko must be installed there, on the PATH of ssh commands.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ssh: Option<Ssh>,
    /// A container of Apple's `container`, which ko creates from an image or finds by name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    container: Option<Container>,
    /// A Podman container on a Linux server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    podman: Option<Podman>,
    /// A runtime on the host, for the tests of the link machinery. The server accepts it only
    /// with KO_RUNTIME_COMMAND_KIND=1 in its environment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    command: Option<Command>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "RawRuntime", into = "RawRuntime")]
pub struct Runtime {
    pub env: Env,
    pub cwd: Option<AbsPath>,
    pub paths: Vec<PathMap>,
    pub pi: RuntimePi,
    pub color: Option<RuntimeColor>,
    pub kind: Kind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    Ssh(Ssh),
    Command(Command),
    Container(Engine),
}

impl Runtime {
    pub fn lead(&self) -> Option<&[String]> {
        match &self.kind {
            Kind::Command(command) => command.lead.as_ref().map(Argv::as_slice),
            Kind::Container(_) | Kind::Ssh(_) => None,
        }
    }

    pub fn paths(&self) -> Vec<PathMap> {
        let volumes: &[Volume] = match &self.kind {
            Kind::Command(_) | Kind::Ssh(_) => &[],
            Kind::Container(engine) => engine.options().volumes,
        };
        volumes
            .iter()
            .map(|volume| PathMap {
                host: (&volume.host).into(),
                runtime: (&volume.runtime).into(),
            })
            .chain(self.paths.iter().cloned())
            .collect()
    }
}

impl JsonSchema for Runtime {
    fn schema_name() -> std::borrow::Cow<'static, str> {
        "Runtime".into()
    }

    fn json_schema(generator: &mut SchemaGenerator) -> Schema {
        RawRuntime::json_schema(generator)
    }
}

impl TryFrom<RawRuntime> for Runtime {
    type Error = &'static str;

    fn try_from(raw: RawRuntime) -> Result<Runtime, &'static str> {
        let kind = match (raw.ssh, raw.container, raw.podman, raw.command) {
            (Some(ssh), None, None, None) => Kind::Ssh(ssh),
            (None, Some(container), None, None) => Kind::Container(Engine::Apple(container)),
            (None, None, Some(podman), None) => Kind::Container(Engine::Podman(podman)),
            (None, None, None, Some(command)) => Kind::Command(command),
            _ => return Err("give exactly one of ssh, container, podman"),
        };
        Ok(Runtime {
            env: raw.env,
            cwd: raw.cwd,
            paths: raw.paths,
            pi: raw.pi,
            color: raw.color,
            kind,
        })
    }
}

impl From<Runtime> for RawRuntime {
    fn from(runtime: Runtime) -> RawRuntime {
        let (mut ssh, mut container, mut podman, mut command) = (None, None, None, None);
        match runtime.kind {
            Kind::Ssh(kind) => ssh = Some(kind),
            Kind::Container(Engine::Apple(kind)) => container = Some(kind),
            Kind::Container(Engine::Podman(kind)) => podman = Some(kind),
            Kind::Command(kind) => command = Some(kind),
        }
        RawRuntime {
            env: runtime.env,
            cwd: runtime.cwd,
            paths: runtime.paths,
            pi: runtime.pi,
            color: runtime.color,
            ssh,
            container,
            podman,
            command,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    /// A container that ko creates from the image and owns: down stops it and DELETE removes it.
    Image(Operand),
    /// A container that the user created with the runtime socket shared and manages.
    Container(Operand),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Access {
    Ro,
}

/// A directory of the host that the container mounts, files only: never a socket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Volume {
    pub host: VolumePath,
    pub runtime: VolumePath,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<Access>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SshAgent {
    /// The host's agent at /var/host-services/ssh-auth.sock (`--ssh`).
    Forward,
    #[default]
    #[serde(rename = "none")]
    Off,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Ko {
    /// The static Linux ko beside the server's installation, mounted read-only at /opt/ko.
    #[default]
    Shipped,
    /// The `ko` on the PATH of the image.
    Path,
    /// Another installed layout, mounted read-only at /opt/ko.
    Mount(MountDir),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Container {
    pub from: Source,
    /// The `container` program. Default: `container` on the PATH of the server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container: Option<Program>,
    #[serde(default)]
    pub volumes: Vec<Volume>,
    /// The user of every exec, as the engine's `exec -u` takes it. Default: the image's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<User>,
    /// More arguments of the engine's `run`. ko refuses the options it owns.
    #[serde(default)]
    pub run_args: RunArgs,
    /// The command that keeps the container alive.
    #[serde(default)]
    pub init: Init,
    /// The host's agent at /var/host-services/ssh-auth.sock (`--ssh`).
    #[serde(default)]
    pub ssh_agent: SshAgent,
    /// The static Linux ko beside the server's installation, the ko on PATH, or mount=DIR.
    #[serde(default)]
    pub ko: Ko,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Podman {
    pub from: Source,
    /// The `podman` program. Default: `podman` on the PATH of the server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub podman: Option<Program>,
    #[serde(default)]
    pub volumes: Vec<Volume>,
    /// The user of every exec, as the engine's `exec -u` takes it. Default: the image's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<User>,
    /// More arguments of the engine's `run`. ko refuses the options it owns.
    #[serde(default)]
    pub run_args: RunArgs,
    /// The command that keeps the container alive.
    #[serde(default)]
    pub init: Init,
    /// The static Linux ko beside the server's installation, the ko on PATH, or mount=DIR.
    #[serde(default)]
    pub ko: Ko,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Ssh {
    pub destination: Destination,
    /// Connection options for the master (`-p`, `-J`, `-F`, `-i`, `-l`, `-o`, ...).
    #[serde(default)]
    pub ssh_args: ConnectionArgs,
    /// The directory on the remote for the forwarded socket and the token files. Default:
    /// `$XDG_RUNTIME_DIR/ko-rt/NAME`, else `/tmp/ko-rt-UID/NAME`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dir: Option<RemoteDir>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Command {
    /// The argv that goes before `ko enter` in a pane's program.
    #[serde(default)]
    pub prefix: Prefix,
    /// Where the runtime's socket is reached inside the runtime. Default: the host path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socket: Option<AbsPath>,
    /// An interactive step of the start. One waiting pane runs it on its own terminal and
    /// reports the result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lead: Option<Argv>,
    /// A step of the start that the server runs as its own child. Exit 0 continues the start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub up: Option<Argv>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Engine {
    Apple(Container),
    Podman(Podman),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContainerOptions<'a> {
    pub from: &'a Source,
    pub ko: &'a Ko,
    pub user: &'a Option<User>,
    pub volumes: &'a [Volume],
    pub run_args: &'a RunArgs,
    pub init: &'a Init,
}

impl Engine {
    pub fn options(&self) -> ContainerOptions<'_> {
        match self {
            Engine::Apple(s) => ContainerOptions {
                from: &s.from,
                ko: &s.ko,
                user: &s.user,
                volumes: &s.volumes,
                run_args: &s.run_args,
                init: &s.init,
            },
            Engine::Podman(s) => ContainerOptions {
                from: &s.from,
                ko: &s.ko,
                user: &s.user,
                volumes: &s.volumes,
                run_args: &s.run_args,
                init: &s.init,
            },
        }
    }
}
