use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::Path;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::ids::RuntimeName;
use crate::protocol::{AbsPath, PathMap, RuntimeKind, env_valid};

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
    /// A runtime on the host, for the tests of the link machinery. The server accepts it only
    /// with KO_RUNTIME_COMMAND_KIND=1 in its environment.
    Command(Command),
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
            Kind::Command(_) => RuntimeKind::Command,
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

fn check(name: &RuntimeName, runtime: &Runtime, command_kind: bool) -> Result<(), String> {
    let bad = |field: &str, why: &str| Err(format!("runtime {name}: {field}: {why}"));
    for (variable, value) in &runtime.env {
        if !env_valid(variable, value) {
            return bad(&format!("env {variable:?}"), "invalid variable");
        }
    }
    let Kind::Command(command) = &runtime.kind;
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
    Ok(())
}

fn parse(text: &[u8], command_kind: bool) -> Result<Runtimes, String> {
    let file: Runtimes = crate::protocol::decode(text).map_err(|error| error.to_string())?;
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
        let Kind::Command(command) = &runtime.kind;
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
                r#"{"runtimes":{"dev":{"kind":"ssh"}}}"#,
                "unknown variant `ssh`",
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
    fn a_missing_file_is_an_empty_configuration() {
        assert_eq!(
            load(Path::new("/nonexistent/runtimes.json"), true),
            Ok(Runtimes::default())
        );
    }
}
