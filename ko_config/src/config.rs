use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use schemars::JsonSchema;
use schemars::generate::SchemaSettings;
use serde::{Deserialize, Serialize};

use crate::app::App;
use crate::runtime::Runtime;
use crate::server::Server;
use crate::values::RuntimeName;
use crate::yaml::{self, Problem};

/// The ko configuration file, `config.yaml`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// The runtimes that panes can run in, by name.
    #[serde(default)]
    pub runtimes: BTreeMap<RuntimeName, Runtime>,
    /// The settings of Kido.app.
    #[serde(default)]
    pub app: App,
    /// The settings of ko server.
    #[serde(default)]
    pub server: Server,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadError {
    Invalid(Problem),
    Io(String),
}

pub fn default_path(xdg_config_home: Option<&Path>, home: &Path) -> PathBuf {
    match xdg_config_home {
        Some(config) => config.join("ko/config.yaml"),
        None => home.join(".config/ko/config.yaml"),
    }
}

pub(crate) fn parse(text: &str) -> Result<Config, Problem> {
    yaml::from_str(text)
}

const MAX_BYTES: u64 = 1 << 20;

pub(crate) fn read_text(source: impl Read) -> io::Result<String> {
    let mut text = String::new();
    source.take(MAX_BYTES + 1).read_to_string(&mut text)?;
    if text.len() as u64 > MAX_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("the file is larger than {MAX_BYTES} bytes"),
        ));
    }
    Ok(text)
}

pub fn load(file: &Path) -> Result<Config, LoadError> {
    let text = match fs::File::open(file).and_then(read_text) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Config::default()),
        Err(error) => return Err(LoadError::Io(format!("{}: {error}", file.display()))),
    };
    parse(&text).map_err(LoadError::Invalid)
}

#[cfg(test)]
pub(crate) fn refusals(cases: &[(&str, &str)]) {
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|(text, message)| {
            let error = parse(text)
                .map(|_| "no error".to_owned())
                .unwrap_or_else(|p| p.to_string());
            (!error.starts_with(message))
                .then(|| format!("{text:?}\n  want {message}\n  have {error}"))
        })
        .collect();
    assert_eq!(failures, Vec::<String>::new());
}

pub fn schema() -> String {
    let schema = SchemaSettings::draft2020_12()
        .into_generator()
        .into_root_schema_for::<Config>();
    serde_json::to_string_pretty(&schema).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::{Kind, Ko, SshAgent};
    use crate::values::AbsPath;

    fn runtime(config: &Config, name: &str) -> Runtime {
        config.runtimes[&name.parse().unwrap()].clone()
    }

    #[test]
    fn a_command_runtime_has_the_common_fields_and_its_own() {
        let found = parse(
            "
runtimes:
  dev:
    env: {A: '1'}
    cwd: /work
    color: '#D08a2A'
    paths:
      - {host: /h, runtime: /r}
    command:
      prefix: [/usr/bin/env]
      socket: /run/ko
      up: [/bin/true]
",
        )
        .unwrap();
        let runtime = runtime(&found, "dev");
        assert_eq!(runtime.env.as_map()["A"], "1");
        assert_eq!(
            runtime.color.clone().map(String::from).as_deref(),
            Some("#D08a2A")
        );
        assert_eq!(runtime.cwd.as_ref().map(AbsPath::as_str), Some("/work"));
        assert_eq!(runtime.paths.len(), 1);
        assert!(matches!(runtime.kind, Kind::Command(_)));
        let Kind::Command(command) = &runtime.kind else {
            panic!("not a command");
        };
        assert_eq!(command.prefix.as_slice(), ["/usr/bin/env"]);
        assert_eq!(
            command.up.as_ref().map(|up| up.as_slice()),
            Some(&["/bin/true".to_owned()][..])
        );
    }

    #[test]
    fn a_bad_file_or_field_is_an_error_with_its_path_and_place() {
        let cases = [
            (
                "runtimes:\n  Dev:\n    command: {}\n",
                "runtimes: invalid runtime name at line 2 column 3",
            ),
            (
                "runtimes:\n  dev:\n    podman: {}\n",
                "runtimes: dev: podman: missing field `from` at line 3 column 13",
            ),
            (
                "runtimes:\n  dev:\n    env: {A: b}\n",
                "runtimes: dev: give exactly one of ssh, container, podman at line 3 column 5",
            ),
            (
                "runtimes:\n  dev:\n    ssh: {destination: h}\n    container: {from: {image: x}}\n",
                "runtimes: dev: give exactly one of ssh, container, podman at line 3 column 5",
            ),
            (
                "runtimes:\n  dev:\n    ssh: {}\n",
                "runtimes: dev: ssh: missing field `destination` at line 3 column 10",
            ),
            (
                "runtimes:\n  dev:\n    ssh:\n      destination: h\n      ssh_args: [-N]\n",
                "runtimes: dev: ssh: ssh_args: -N is not a connection option; ko owns the rest of the ssh command at line 5 column 17",
            ),
            (
                "runtimes:\n  dev:\n    ssh:\n      destination: h\n      ssh_args: [-p]\n",
                "runtimes: dev: ssh: ssh_args: is not a list of ssh options at line 5 column 17",
            ),
            (
                "runtimes:\n  dev:\n    ssh:\n      destination: h\n      ssh_args: -p\n",
                "runtimes: dev: ssh: ssh_args: invalid type: string \"-p\", expected a list at line 5 column 17",
            ),
            (
                "runtimes:\n  dev:\n    ssh: {destination: -h}\n",
                "runtimes: dev: ssh: destination: \"-h\" is not an ssh destination at line 3 column 24",
            ),
            (
                "runtimes:\n  dev:\n    ssh: {destination: h, dir: /a:b}\n",
                "runtimes: dev: ssh: dir: \"/a:b\" is not an absolute path without a colon, a percent sign or a newline at line 3 column 32",
            ),
            (
                "runtimes:\n  dev:\n    ssh: {destination: h, destinaton: x}\n",
                "runtimes: dev: ssh: unknown field `destinaton`, expected one of `destination`, `ssh_args`, `dir` at line 3 column 27",
            ),
            (
                "runtimes:\n  dev:\n    command: {cwd: rel}\n",
                "runtimes: dev: command: unknown field `cwd`, expected one of `prefix`, `socket`, `up` at line 3 column 15",
            ),
            (
                "runtimes:\n  dev:\n    cwd: rel\n    command: {}\n",
                "runtimes: dev: cwd: \"rel\" is not an absolute path at line 3 column 10",
            ),
            (
                "runtimes:\n  dev:\n    env: {A=B: '1'}\n    command: {}\n",
                "runtimes: dev: env: \"A=B\" is an invalid variable at line 3 column 10",
            ),
            (
                "runtimes:\n  dev:\n    env: [a]\n    command: {}\n",
                "runtimes: dev: env: invalid type: sequence, expected a map at line 3 column 10",
            ),
            (
                "runtimes:\n  dev:\n    command: {up: []}\n",
                "runtimes: dev: command: up: must start with an absolute program path at line 3 column 19",
            ),
            (
                "runtimes:\n  dev:\n    pi: [x]\n    command: {}\n",
                "runtimes: dev: pi: invalid type: sequence, expected an enum at line 3 column 9",
            ),
            (
                "runtimes:\n  dev:\n    container: {from: {image: x}, init: []}\n",
                "runtimes: dev: container: init: must be a command at line 3 column 41",
            ),
            (
                "runtimes:\n  dev:\n    container: {from: {image: x}, user: -x}\n",
                "runtimes: dev: container: user: \"-x\" is not a user name or id at line 3 column 41",
            ),
            (
                "runtimes:\n  dev:\n    container: {from: {image: x}, volumes: [{host: '/a:b', runtime: /c}]}\n",
                "runtimes: dev: container: volumes: [0]: host: \"/a:b\" is not an absolute path without a colon",
            ),
            (
                "runtimes:\n  dev:\n    container: {from: {image: x}, ko: {mount: '/a,b'}}\n",
                "runtimes: dev: container: ko: mount: \"/a,b\" is not an absolute path without a comma",
            ),
            (
                "runtimes:\n  dev:\n    container: {from: {podman: x}}\n",
                "runtimes: dev: container: from: unknown variant `podman`, expected `image` or `container` at line 3 column 24",
            ),
            (
                "runtimes:\n  dev:\n    container: {from: {image: x}, ssh_agent: yes}\n",
                "runtimes: dev: container: ssh_agent: unknown variant `yes`, expected `forward` or `none`",
            ),
            (
                "runtimes:\n  dev:\n    color: orange\n    command: {}\n",
                "runtimes: dev: color: \"orange\" is not an #rrggbb colour at line 3 column 12",
            ),
            (
                "runtimes: [a]\n",
                "runtimes: invalid type: sequence, expected a map at line 1 column 11",
            ),
            (
                "runtimes:\n  dev:\n    command: {}\n  dev:\n    command: {}\n",
                "duplicate key \"dev\" at line 4 column 3",
            ),
        ];
        refusals(&cases);
    }

    #[test]
    fn an_unknown_top_level_key_names_the_key_and_the_known_ones() {
        assert_eq!(
            parse("runtimez: {}\n").unwrap_err().to_string(),
            "unknown field `runtimez`, expected one of `runtimes`, `app`, `server` at line 1 column 1"
        );
        assert_eq!(
            parse("runtimes: {}\nfont_size: 12\n")
                .unwrap_err()
                .to_string(),
            "unknown field `font_size`, expected one of `runtimes`, `app`, `server` at line 2 column 1"
        );
    }

    #[test]
    fn an_ssh_runtime_has_a_destination_connection_options_and_a_remote_directory() {
        let found = parse(
            "
runtimes:
  dev:
    cwd: null
    env: {A: yes}
    ssh:
      destination: me@host
      ssh_args: [-p, 2222, -i, key]
      dir: /srv/ko
  d:
    ssh: {destination: h}
",
        )
        .unwrap();
        let runtime = runtime(&found, "dev");
        assert!(matches!(runtime.kind, Kind::Ssh(_)));
        assert_eq!(runtime.cwd, None);
        assert_eq!(runtime.env.as_map()["A"], "yes");
        let Kind::Ssh(ssh) = &runtime.kind else {
            panic!("not an ssh runtime");
        };
        assert_eq!(ssh.destination.as_str(), "me@host");
        assert_eq!(ssh.ssh_args.as_slice(), ["-p", "2222", "-i", "key"]);
        assert_eq!(ssh.dir.as_ref().map(|dir| dir.as_str()), Some("/srv/ko"));
        assert_eq!(found.runtimes.len(), 2);
    }

    #[test]
    fn a_container_runtime_has_defaults_and_refuses_the_options_that_ko_owns() {
        let found =
            parse("runtimes:\n  c:\n    container: {from: {image: 'debian:trixie'}}\n").unwrap();
        let Kind::Container(crate::runtime::Engine::Apple(container)) = runtime(&found, "c").kind
        else {
            panic!("not a container");
        };
        assert_eq!(container.init.as_slice(), ["sleep", "infinity"]);
        assert_eq!(container.ssh_agent, SshAgent::Off);
        assert_eq!(container.ko, Ko::Shipped);
        let mounted = parse(
            "runtimes:\n  c:\n    container: {from: {container: mine}, ko: {mount: /k}, ssh_agent: forward}\n",
        )
        .unwrap();
        assert_eq!(mounted.runtimes.len(), 1);
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
            let error = parse(&format!(
                "runtimes:\n  c:\n    container: {{from: {{image: x}}, run_args: ['{arg}']}}\n"
            ))
            .unwrap_err()
            .to_string();
            assert!(
                error.starts_with("runtimes: c: container: run_args: ")
                    && error.contains("is set by ko"),
                "{arg}: {error}"
            );
        }
    }

    #[test]
    fn podman_has_container_options_but_no_ssh_agent_and_is_one_kind() {
        let found = parse("runtimes:\n  dev:\n    podman:\n      from: {image: x}\n      podman: /usr/bin/podman\n      volumes: [{host: /src, runtime: /work}]\n").unwrap();
        let dev = runtime(&found, "dev");
        let Kind::Container(crate::runtime::Engine::Podman(podman)) = &dev.kind else {
            panic!("not podman")
        };
        assert_eq!(podman.init.as_slice(), ["sleep", "infinity"]);
        assert_eq!(podman.ko, Ko::Shipped);
        assert_eq!(dev.paths()[0].runtime.as_str(), "/work");
        for key in ["ssh_agent: forward", "unknown: x"] {
            assert!(
                parse(&format!(
                    "runtimes:\n  dev:\n    podman: {{from: {{image: x}}, {key}}}\n"
                ))
                .is_err()
            );
        }
        for kind in [
            "ssh: {destination: host}",
            "container: {from: {image: x}}",
            "command: {}",
        ] {
            assert!(
                parse(&format!(
                    "runtimes:\n  dev:\n    podman: {{from: {{image: x}}}}\n    {kind}\n"
                ))
                .is_err()
            );
        }
        for arg in [
            "--name=x",
            "-d",
            "--detach",
            "--init=false",
            "-v/a:/b",
            "--volume",
            "--mount",
            "--security-opt=label=nested",
            "--http-proxy=true",
            "--rm",
        ] {
            let error = parse(&format!(
                "runtimes:\n  dev:\n    podman: {{from: {{image: x}}, run_args: ['{arg}']}}\n"
            ))
            .unwrap_err()
            .to_string();
            assert!(error.contains("is set by ko"), "{arg}: {error}");
        }
        let encoded = serde_json::to_value(dev).unwrap();
        assert_eq!(encoded["podman"]["podman"], "/usr/bin/podman");
        assert!(encoded["podman"].get("ssh_agent").is_none());
    }

    #[test]
    fn an_empty_file_comments_and_a_file_without_runtimes_are_an_empty_config() {
        for text in ["", "# one\n# two\n", "runtimes:\n", "runtimes: {}\n"] {
            assert_eq!(parse(text), Ok(Config::default()), "{text:?}");
        }
        assert_eq!(
            load(Path::new("/nonexistent/config.yaml")),
            Ok(Config::default())
        );
    }

    #[test]
    fn the_default_path_is_under_the_config_home_else_the_home() {
        assert_eq!(
            default_path(Some(Path::new("/x")), Path::new("/h")),
            Path::new("/x/ko/config.yaml")
        );
        assert_eq!(
            default_path(None, Path::new("/h")),
            Path::new("/h/.config/ko/config.yaml")
        );
    }

    #[test]
    fn a_runtime_has_exactly_one_kind_and_a_null_kind_is_absent() {
        let verdict = |kinds: &str| {
            parse(&format!("runtimes:\n  dev:\n{kinds}"))
                .map(|found| found.runtimes.len())
                .map_err(|problem| problem.to_string())
        };
        assert_eq!(
            verdict("    env: {A: b}\n"),
            Err(
                "runtimes: dev: give exactly one of ssh, container, podman at line 3 column 5"
                    .to_owned()
            )
        );
        assert!(verdict("    ssh: {destination: h}\n    command: {}\n").is_err());
        assert_eq!(
            verdict("    ssh: {destination: h}\n    container:\n    command: ~\n"),
            Ok(1)
        );
        let schema: serde_json::Value = serde_json::from_str(&schema()).unwrap();
        assert_eq!(
            schema["$defs"]["Runtime"]["oneOf"][0],
            serde_json::json!({"required": ["ssh"], "properties": {"ssh": {"type": "object"}}})
        );
    }

    #[test]
    fn a_file_over_one_mebibyte_is_refused() {
        let error = read_text(io::repeat(b'#').take(MAX_BYTES + 5)).unwrap_err();
        assert_eq!(error.to_string(), "the file is larger than 1048576 bytes");
        assert_eq!(
            read_text(io::repeat(b'#').take(MAX_BYTES)).unwrap().len(),
            1 << 20
        );
    }
}
