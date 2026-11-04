use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::Path;
use std::sync::OnceLock;

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::de::IgnoredAny;
use serde::{Deserialize, Serialize};

use crate::ids::RuntimeName;
use crate::protocol::{AbsPath, PathMap, RuntimeKind, env_valid};
use crate::ssh::{connection_only, has_syntax};

/// The runtime configuration file: the runtimes that panes can run in, by name.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub(crate) struct Runtimes {
    pub(crate) runtimes: BTreeMap<RuntimeName, Runtime>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub(crate) struct Runtime {
    /// Variables for every pane of the runtime, applied before the variables of the request.
    #[serde(default)]
    pub(crate) env: BTreeMap<String, String>,
    /// The directory inside the runtime for a pane whose request names none that maps.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) cwd: Option<AbsPath>,
    /// A host directory that a host caller names as cwd maps to the runtime directory of the
    /// longest matching host prefix.
    #[serde(default)]
    pub(crate) paths: Vec<PathMap>,
    #[serde(flatten)]
    pub(crate) kind: Kind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum Kind {
    /// A runtime on an ssh host, reached through one ssh master that the first pane logs in.
    /// ko must be installed there, on the PATH of ssh commands.
    Ssh(Ssh),
    /// A runtime on the host, for the tests of the link machinery. The server accepts it only
    /// with KO_RUNTIME_COMMAND_KIND=1 in its environment.
    Command(Command),
    /// A container of Apple's `container`, which ko creates from an image or finds by name.
    Container(Container),
}

macro_rules! word {
    ($(#[$doc:meta])* $name:ident, $what:literal, $pattern:literal, $valid:expr) => {
        $(#[$doc])*
        #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
        #[serde(try_from = "String", into = "String")]
        pub(crate) struct $name(String);

        impl $name {
            pub(crate) fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl JsonSchema for $name {
            fn schema_name() -> Cow<'static, str> {
                stringify!($name).into()
            }

            fn json_schema(_: &mut SchemaGenerator) -> Schema {
                json_schema!({"type": "string", "pattern": $pattern, "description": $what})
            }
        }

        impl TryFrom<String> for $name {
            type Error = String;

            fn try_from(text: String) -> Result<$name, String> {
                if $valid(text.as_str()) {
                    Ok($name(text))
                } else {
                    Err(format!("{text:?} is not {}", $what))
                }
            }
        }

        impl From<$name> for String {
            fn from($name(text): $name) -> String {
                text
            }
        }
    };
}

fn operand_valid(text: &str) -> bool {
    let mut chars = text.chars();
    chars
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || "_.:/@+-".contains(c))
}

fn user_valid(text: &str) -> bool {
    !text.starts_with('-') && !text.is_empty() && !text.contains('\0')
}

fn program_valid(text: &str) -> bool {
    !text.is_empty() && !text.contains('\0')
}

word!(
    /// An image reference or a container name.
    Operand,
    "an image reference or a container name",
    "^[A-Za-z0-9][A-Za-z0-9_.:/@+-]*$",
    operand_valid
);
word!(
    /// A user as `container exec -u` takes it.
    User,
    "a user name or id",
    "^[^-\\u0000][^\\u0000]*$",
    user_valid
);
word!(
    /// A program name or path.
    Program,
    "a program name or path",
    "^[^\\u0000]+$",
    program_valid
);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Source {
    /// A container that ko creates from the image and owns: down stops it and DELETE removes it.
    Image(Operand),
    /// A container that the user created with `-v <runtime socket>:/run/ko/socket` and manages.
    Container(Operand),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Access {
    Ro,
}

/// A directory of the host that the container mounts, files only: never a socket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub(crate) struct Volume {
    pub(crate) host: AbsPath,
    pub(crate) runtime: AbsPath,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) options: Option<Access>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SshAgent {
    /// The host's agent at /var/host-services/ssh-auth.sock (`--ssh`).
    Forward,
    #[default]
    #[serde(rename = "none")]
    Off,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Ko {
    /// The static Linux ko beside the server's installation, mounted read-only at /opt/ko.
    #[default]
    Shipped,
    /// The `ko` on the PATH of the image.
    Path,
    /// Another installed layout, mounted read-only at /opt/ko.
    Mount(AbsPath),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub(crate) struct Container {
    pub(crate) from: Source,
    /// The `container` program. Default: `container` on the PATH of the server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) container: Option<Program>,
    #[serde(default)]
    pub(crate) volumes: Vec<Volume>,
    /// The user of every exec, as `container exec -u` takes it. Default: the image's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) user: Option<User>,
    /// More arguments of `container run`. ko refuses the options it owns.
    #[serde(default)]
    pub(crate) run_args: Vec<String>,
    /// The command that keeps the container alive.
    #[serde(default = "default_init")]
    pub(crate) init: Vec<String>,
    #[serde(default)]
    pub(crate) ssh_agent: SshAgent,
    #[serde(default)]
    pub(crate) ko: Ko,
}

fn default_init() -> Vec<String> {
    vec!["sleep".to_owned(), "infinity".to_owned()]
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub(crate) struct Ssh {
    /// The ssh destination as typed: `host` or `user@host`.
    pub(crate) destination: String,
    /// Connection options for the master (`-p`, `-J`, `-F`, `-i`, `-l`, `-o`, ...).
    #[serde(default)]
    pub(crate) ssh_args: Vec<String>,
    /// The directory on the remote for the forwarded socket and the token files. Default:
    /// `$XDG_RUNTIME_DIR/ko-rt/NAME`, else `/tmp/ko-rt-UID/NAME`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) dir: Option<AbsPath>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub(crate) struct Command {
    /// The argv that goes before `ko enter` in a pane's program.
    #[serde(default)]
    pub(crate) prefix: Vec<String>,
    /// Where the runtime's socket is reached inside the runtime. Default: the host path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) socket: Option<AbsPath>,
    /// An interactive step of the start. One waiting pane runs it on its own terminal and
    /// reports the result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) lead: Option<Vec<String>>,
    /// A step of the start that the server runs as its own child. Exit 0 continues the start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) up: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum LoadError {
    Invalid(String),
    Io(String),
}

impl Runtime {
    pub(crate) fn kind(&self) -> RuntimeKind {
        match self.kind {
            Kind::Ssh(_) => RuntimeKind::Ssh,
            Kind::Command(_) => RuntimeKind::Command,
            Kind::Container(_) => RuntimeKind::Container,
        }
    }
}

fn argv_error(argv: &[String]) -> Option<&'static str> {
    if argv.first().is_none_or(|program| !program.starts_with('/')) {
        Some("must start with an absolute program path")
    } else if argv.iter().any(|arg| arg.contains('\0')) {
        Some("contains a NUL")
    } else {
        None
    }
}

const OWNED_OPTIONS: [&str; 10] = [
    "-v",
    "--volume",
    "--mount",
    "--name",
    "-d",
    "--detach",
    "--rm",
    "--remove",
    "--publish-socket",
    "--ssh",
];

fn owned_option(arg: &str) -> Option<&'static str> {
    OWNED_OPTIONS.iter().copied().find(|owned| {
        let short = !owned.starts_with("--");
        arg == *owned
            || arg
                .strip_prefix(owned)
                .is_some_and(|rest| rest.starts_with('=') || (short && !arg.starts_with("--")))
    })
}

fn check(name: &RuntimeName, runtime: &Runtime, command_kind: bool) -> Result<(), String> {
    let bad = |field: &str, why: &str| Err(format!("runtime {name}: {field}: {why}"));
    for (variable, value) in &runtime.env {
        if !env_valid(variable, value) {
            return bad(&format!("env {variable:?}"), "invalid variable");
        }
    }
    match &runtime.kind {
        Kind::Ssh(ssh) => {
            if ssh.destination.contains('\0') || ssh.ssh_args.iter().any(|arg| arg.contains('\0')) {
                return bad("destination", "contains a NUL");
            }
            if let Err(why) = connection_only(&ssh.ssh_args, &ssh.destination) {
                return bad("ssh_args", &why);
            }
            if let Some(dir) = &ssh.dir {
                let shown = dir.as_path().to_string_lossy();
                if has_syntax(&shown) || shown.contains('\n') {
                    return bad("dir", "contains a colon, a percent sign or a newline");
                }
            }
        }
        Kind::Command(command) => {
            if !command_kind {
                return bad(
                    "kind",
                    "command is a test kind; set KO_RUNTIME_COMMAND_KIND=1",
                );
            }
            if command.prefix.iter().any(|arg| arg.contains('\0')) {
                return bad("prefix", "contains a NUL");
            }
            for (field, argv) in [("lead", &command.lead), ("up", &command.up)] {
                if let Some(why) = argv.as_deref().and_then(argv_error) {
                    return bad(field, why);
                }
            }
        }
        Kind::Container(container) => {
            for volume in &container.volumes {
                let paths = [volume.host.as_path(), volume.runtime.as_path()];
                if paths
                    .iter()
                    .any(|path| path.to_string_lossy().contains(':'))
                {
                    return bad("volumes", "a path contains a colon");
                }
            }
            if let Ko::Mount(dir) = &container.ko
                && dir.as_path().to_string_lossy().contains(',')
            {
                return bad("ko", "the mount directory contains a comma");
            }
            for arg in &container.run_args {
                if let Some(owned) = owned_option(arg) {
                    return bad("run_args", &format!("{owned} is set by ko"));
                }
                if arg.contains('\0') {
                    return bad("run_args", "contains a NUL");
                }
            }
            if container.init.iter().any(|arg| arg.contains('\0'))
                || container.init.first().is_none_or(String::is_empty)
            {
                return bad("init", "must be a command");
            }
        }
    }
    Ok(())
}

#[derive(Deserialize)]
struct Keys {
    runtimes: BTreeMap<String, BTreeMap<String, IgnoredAny>>,
}

// The fields of each kind, with the common ones, from the schema of a runtime: the kinds are
// the variants of its `oneOf`, and the fields of a kind are the properties of the type it names.
fn known_fields() -> &'static BTreeMap<String, BTreeSet<String>> {
    static KNOWN: OnceLock<BTreeMap<String, BTreeSet<String>>> = OnceLock::new();
    KNOWN.get_or_init(|| {
        let schema = serde_json::to_value(schemars::schema_for!(Runtime)).unwrap_or_default();
        let properties = |schema: &serde_json::Value| -> BTreeSet<String> {
            schema["properties"]
                .as_object()
                .into_iter()
                .flat_map(|fields| fields.keys().cloned())
                .collect()
        };
        let common = properties(&schema);
        schema["oneOf"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|variant| {
                let kind = variant["properties"]["kind"]["const"].as_str()?;
                let own = variant["$ref"].as_str()?.rsplit('/').next()?;
                let mut fields = properties(&schema["$defs"][own]);
                fields.extend(common.iter().cloned());
                fields.insert("kind".to_owned());
                Some((kind.to_owned(), fields))
            })
            .collect()
    })
}

fn unknown_field(text: &[u8], file: &Runtimes) -> Result<(), String> {
    let keys: Keys = serde_json::from_slice(text).map_err(|error| error.to_string())?;
    for (name, runtime) in &file.runtimes {
        let kind = serde_json::to_value(runtime.kind()).unwrap_or_default();
        let known = kind.as_str().and_then(|kind| known_fields().get(kind));
        let given = keys
            .runtimes
            .get(name.as_str())
            .into_iter()
            .flat_map(BTreeMap::keys);
        for field in given {
            if !known.is_some_and(|known| known.contains(field)) {
                return Err(format!("runtime {name}: unknown field {field:?}"));
            }
        }
    }
    Ok(())
}

fn parse(text: &[u8], command_kind: bool) -> Result<Runtimes, String> {
    let file: Runtimes = crate::protocol::decode(text).map_err(|error| error.to_string())?;
    unknown_field(text, &file)?;
    for (name, runtime) in &file.runtimes {
        check(name, runtime, command_kind)?;
    }
    Ok(file)
}

pub(crate) fn load(file: &Path, command_kind: bool) -> Result<Runtimes, LoadError> {
    let text = match fs::read(file) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Runtimes::default()),
        Err(error) => return Err(LoadError::Io(format!("{}: {error}", file.display()))),
    };
    parse(&text, command_kind)
        .map_err(|message| LoadError::Invalid(format!("{}: {message}", file.display())))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(text: &str) -> Result<Runtimes, String> {
        parse(text.as_bytes(), true)
    }

    #[test]
    fn a_command_runtime_has_the_common_fields_and_its_own() {
        let found = parsed(
            r#"{"runtimes":{"dev":{"kind":"command","env":{"A":"1"},"cwd":"/work",
            "paths":[{"host":"/h","runtime":"/r"}],"prefix":["/usr/bin/env"],
            "socket":"/run/ko","lead":["/bin/true"],"up":["/bin/true"]}}}"#,
        )
        .unwrap();
        let runtime = &found.runtimes[&"dev".parse().unwrap()];
        assert_eq!(runtime.env["A"], "1");
        assert_eq!(
            runtime.cwd.as_ref().map(AbsPath::as_path),
            Some(Path::new("/work"))
        );
        assert_eq!(runtime.paths.len(), 1);
        assert_eq!(runtime.kind(), RuntimeKind::Command);
        let Kind::Command(command) = &runtime.kind else {
            panic!("not a command");
        };
        assert_eq!(command.prefix, ["/usr/bin/env"]);
        assert_eq!(command.lead.as_deref(), Some(&["/bin/true".to_owned()][..]));
    }

    #[test]
    fn a_bad_file_or_field_is_an_error_with_its_place_or_its_runtime_and_field() {
        let cases = [
            (
                r#"{"runtimes":{"Dev":{"kind":"command"}}}"#,
                "invalid runtime name",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"podman"}}}"#,
                "unknown variant `podman`",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"ssh"}}}"#,
                "missing field `destination`",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"ssh","destination":"h","ssh_args":["-N"]}}}"#,
                "runtime dev: ssh_args: -N is not a connection option",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"ssh","destination":"h","ssh_args":["-p"]}}}"#,
                "runtime dev: ssh_args: is not a list of ssh options",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"ssh","destination":"-h"}}}"#,
                "runtime dev: ssh_args:",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"ssh","destination":"h","dir":"/a:b"}}}"#,
                "runtime dev: dir: contains a colon",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"ssh","destination":"h","destinaton":"x"}}}"#,
                "runtime dev: unknown field \"destinaton\"",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"command","prefx":[]}}}"#,
                "runtime dev: unknown field \"prefx\"",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"container","from":{"image":"x"},"imag":1}}}"#,
                "runtime dev: unknown field \"imag\"",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"command","cwd":"rel"}}}"#,
                "\"rel\" is not an absolute path",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"command","env":{"A=B":"1"}}}}"#,
                "runtime dev: env \"A=B\": invalid variable",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"command","up":[]}}}"#,
                "runtime dev: up: must start with an absolute program path",
            ),
            (
                r#"{"runtimes":{"dev":{"kind":"command","lead":["sh"]}}}"#,
                "runtime dev: lead: must start with an absolute program path",
            ),
            (
                r#"{"runtimes":"#,
                "EOF while parsing a value at line 1 column 12",
            ),
        ];
        for (text, message) in cases {
            let error = parsed(text).unwrap_err();
            assert!(error.contains(message), "{text}: {error}");
        }
    }

    #[test]
    fn an_ssh_runtime_has_a_destination_connection_options_and_a_remote_directory() {
        let found = parsed(
            r#"{"runtimes":{"dev":{"kind":"ssh","destination":"me@host","ssh_args":["-p","2222","-i","key"],
            "dir":"/srv/ko","cwd":null,"env":{"A":"1"}}}}"#,
        )
        .unwrap();
        let runtime = &found.runtimes[&"dev".parse().unwrap()];
        assert_eq!(runtime.kind(), RuntimeKind::Ssh);
        assert_eq!(runtime.cwd, None);
        let Kind::Ssh(ssh) = &runtime.kind else {
            panic!("not an ssh runtime");
        };
        assert_eq!(ssh.destination, "me@host");
        assert_eq!(ssh.ssh_args, ["-p", "2222", "-i", "key"]);
        assert_eq!(
            ssh.dir.as_ref().map(AbsPath::as_path),
            Some(Path::new("/srv/ko"))
        );
        assert_eq!(
            parsed(r#"{"runtimes":{"d":{"kind":"ssh","destination":"h"}}}"#)
                .unwrap()
                .runtimes
                .len(),
            1
        );
    }

    #[test]
    fn the_known_fields_are_the_fields_that_a_runtime_writes() {
        let full = |kind: &str| -> Vec<String> {
            let runtime = match kind {
                "ssh" => r#"{"kind":"ssh","destination":"h","ssh_args":[],"dir":"/d"}"#,
                "container" => {
                    r#"{"kind":"container","from":{"image":"x"},"container":"c","volumes":[],"user":"u","run_args":[],"init":["a"],"ssh_agent":"forward","ko":"path"}"#
                }
                _ => r#"{"kind":"command","prefix":[],"socket":"/s","lead":[],"up":[]}"#,
            };
            let mut runtime: serde_json::Value = serde_json::from_str(runtime).unwrap();
            runtime["env"] = serde_json::json!({});
            runtime["cwd"] = serde_json::json!("/c");
            runtime["paths"] = serde_json::json!([]);
            let runtime: Runtime = serde_json::from_value(runtime).unwrap();
            let written = serde_json::to_value(&runtime).unwrap();
            let mut keys: Vec<String> = written.as_object().unwrap().keys().cloned().collect();
            keys.sort();
            keys
        };
        for kind in ["ssh", "command", "container"] {
            let known: Vec<String> = known_fields()[kind].iter().cloned().collect();
            assert_eq!(full(kind), known, "{kind}");
        }
    }

    #[test]
    fn the_command_kind_needs_its_knob() {
        let text = br#"{"runtimes":{"dev":{"kind":"command"}}}"#;
        assert_eq!(
            parse(text, false),
            Err(
                "runtime dev: kind: command is a test kind; set KO_RUNTIME_COMMAND_KIND=1"
                    .to_owned()
            )
        );
        assert!(parse(text, true).is_ok());
    }

    #[test]
    fn a_container_runtime_has_defaults_and_refuses_the_options_that_ko_owns() {
        let found =
            parsed(r#"{"runtimes":{"c":{"kind":"container","from":{"image":"debian:trixie"}}}}"#)
                .unwrap();
        let Kind::Container(container) = &found.runtimes[&"c".parse().unwrap()].kind else {
            panic!("not a container");
        };
        assert_eq!(container.init, ["sleep", "infinity"]);
        assert_eq!(container.ssh_agent, SshAgent::Off);
        assert_eq!(container.ko, Ko::Shipped);
        let mounted = parsed(
            r#"{"runtimes":{"c":{"kind":"container","from":{"container":"mine"},"ko":{"mount":"/k"},"ssh_agent":"forward"}}}"#,
        )
        .unwrap();
        assert_eq!(mounted.runtimes.len(), 1);
        let bad = |extra: &str| {
            parsed(&format!(
                r#"{{"runtimes":{{"c":{{"kind":"container","from":{{"image":"x"}},{extra}}}}}}}"#
            ))
            .unwrap_err()
        };
        for arg in [
            "-v",
            "--volume=/a:/b",
            "--mount",
            "--name",
            "-d",
            "--detach",
            "--rm",
            "--remove",
            "--publish-socket",
            "--ssh",
            "-v/a:/b",
        ] {
            let error = bad(&format!(r#""run_args":["{arg}"]"#));
            assert!(error.contains("runtime c: run_args:"), "{arg}: {error}");
        }
        assert!(
            bad(r#""volumes":[{"host":"/a:b","runtime":"/c"}]"#).contains("runtime c: volumes:")
        );
        assert!(bad(r#""user":"-x""#).contains("\"-x\" is not a user name or id"));
        assert!(bad(r#""init":[]"#).contains("runtime c: init:"));
    }

    #[test]
    fn a_missing_file_is_an_empty_configuration() {
        assert_eq!(
            load(Path::new("/nonexistent/runtimes.json"), true),
            Ok(Runtimes::default())
        );
    }
}
