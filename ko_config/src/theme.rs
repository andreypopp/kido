use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::app::ThemePair;
use crate::config::{self, read_text};
use crate::values::ThemeName;
use crate::yaml::Problem;

const MAX_LINKS: usize = 40;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SetError {
    Name(String),
    Changed,
    Invalid(Problem),
    Io(String),
}

fn quoted(name: &ThemeName) -> String {
    format!(
        "\"{}\"",
        name.as_str().replace('\\', "\\\\").replace('"', "\\\"")
    )
}

fn body(line: &str) -> &str {
    line.trim_end_matches(['\n', '\r'])
}

fn blank(line: &str) -> bool {
    body(line).trim().is_empty()
}

fn indent(line: &str) -> usize {
    body(line).len() - body(line).trim_start_matches(' ').len()
}

fn skipped(line: &str) -> bool {
    blank(line) || body(line).trim_start().starts_with('#')
}

fn key_rest<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    body(line)
        .trim_start_matches(' ')
        .strip_prefix(key)
        .and_then(|rest| rest.strip_prefix(':'))
        .filter(|rest| rest.is_empty() || rest.starts_with(' '))
        .map(str::trim)
}

fn is_app(line: &str) -> bool {
    indent(line) == 0
        && key_rest(line, "app").is_some_and(|rest| rest.is_empty() || rest.starts_with('#'))
}

fn replace_theme(text: &str, pair: &ThemePair) -> String {
    let lines: Vec<&str> = text.split_inclusive('\n').collect();
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let block = |ind: usize, end: &str| {
        let pad = " ".repeat(ind);
        format!(
            "{pad}theme:{eol}{pad}  light: {}{eol}{pad}  dark: {}{end}",
            quoted(&pair.light),
            quoted(&pair.dark)
        )
    };
    let ends_open = lines.last().is_some_and(|last| !last.ends_with('\n'));
    let Some(app) = lines.iter().position(|line| is_app(line)) else {
        let mut out = text.to_owned();
        if ends_open {
            out.push_str(eol);
        }
        out.push_str(&format!("app:{eol}"));
        out.push_str(&block(2, if ends_open { "" } else { eol }));
        return out;
    };
    let after = lines[app + 1..]
        .iter()
        .position(|line| !skipped(line) && indent(line) == 0)
        .map_or(lines.len(), |at| app + 1 + at);
    let children = app + 1..after;
    let child = lines[children.clone()]
        .iter()
        .find(|line| !skipped(line))
        .map_or(2, |line| indent(line));
    let theme = children
        .clone()
        .find(|at| indent(lines[*at]) == child && key_rest(lines[*at], "theme").is_some());
    let (from, to, end) = match theme {
        Some(first) => {
            let mut to = first + 1;
            while to < after && (blank(lines[to]) || indent(lines[to]) > child) {
                to += 1;
            }
            while to > first + 1 && blank(lines[to - 1]) {
                to -= 1;
            }
            let last = lines[to - 1];
            (first, to, last[body(last).len()..].to_owned())
        }
        None => {
            let at = children
                .rev()
                .find(|at| !blank(lines[*at]) && indent(lines[*at]) > 0)
                .unwrap_or(app)
                + 1;
            let open = at == lines.len() && ends_open;
            (at, at, if open { String::new() } else { eol.to_owned() })
        }
    };
    let mut out: String = lines[..from].concat();
    if from == to && from == lines.len() && ends_open {
        out.push_str(eol);
    }
    out.push_str(&block(child, &end));
    out.push_str(&lines[to..].concat());
    out
}

fn resolve(path: &Path) -> io::Result<PathBuf> {
    let mut target = std::path::absolute(path)?;
    for _ in 0..MAX_LINKS {
        if let Ok(real) = fs::canonicalize(&target) {
            return Ok(real);
        }
        match fs::symlink_metadata(&target) {
            Ok(meta) if meta.file_type().is_symlink() => {
                let link = fs::read_link(&target)?;
                target = target.parent().unwrap_or(Path::new("/")).join(link);
            }
            _ => return Ok(target),
        }
    }
    Err(io::Error::other("too many levels of symbolic links"))
}

fn io_error(error: io::Error) -> SetError {
    SetError::Io(if error.raw_os_error().is_some() {
        error.kind().to_string()
    } else {
        error.to_string()
    })
}

fn replace_file(target: &Path, original: &str, text: &str, mode: u32) -> Result<(), SetError> {
    let mut name = target.file_name().unwrap_or_default().to_owned();
    name.push(format!(".tmp-{}", std::process::id()));
    let temporary = target.with_file_name(name);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(&temporary)
        .map_err(io_error)?;
    let done = file
        .set_permissions(fs::Permissions::from_mode(mode))
        .and_then(|()| file.write_all(text.as_bytes()))
        .and_then(|()| file.sync_all())
        .map_err(io_error)
        .and_then(|()| match read_existing(target) {
            Ok((now, _)) if now == original => fs::rename(&temporary, target).map_err(io_error),
            Ok(_) => Err(SetError::Changed),
            Err(error) => Err(io_error(error)),
        });
    if done.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    done
}

fn read_existing(target: &Path) -> io::Result<(String, Option<u32>)> {
    match fs::metadata(target) {
        Ok(meta) => Ok((
            fs::File::open(target).and_then(read_text)?,
            Some(meta.permissions().mode() & 0o7777),
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok((String::new(), None)),
        Err(error) => Err(error),
    }
}

pub fn set_theme(path: &Path, light: &str, dark: &str) -> Result<bool, SetError> {
    let name = |text: &str| ThemeName::try_from(text.to_owned()).map_err(SetError::Name);
    let pair = ThemePair {
        light: name(light)?,
        dark: name(dark)?,
    };
    let target = resolve(path).map_err(io_error)?;
    if let Some(directory) = target.parent() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)
            .map_err(io_error)?;
    }
    let (text, existing) = read_existing(&target).map_err(io_error)?;
    let current = config::parse(&text).map_err(SetError::Invalid)?;
    if current.app.theme.pair() == pair {
        return Ok(false);
    }
    let edited = replace_theme(&text, &pair);
    let decoded = config::parse(&edited).map_err(SetError::Invalid)?;
    if decoded.app.theme.pair() != pair {
        return Err(SetError::Invalid(Problem {
            line: 1,
            column: 1,
            message: "the edit did not set app.theme to the new pair".to_owned(),
        }));
    }
    if existing.is_some() {
        fs::OpenOptions::new()
            .write(true)
            .open(&target)
            .map_err(io_error)?;
    }
    replace_file(&target, &text, &edited, existing.unwrap_or(0o600))?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::symlink;

    use super::*;

    fn pair(light: &str, dark: &str) -> ThemePair {
        ThemePair {
            light: ThemeName::try_from(light.to_owned()).unwrap(),
            dark: ThemeName::try_from(dark.to_owned()).unwrap(),
        }
    }

    fn edited(text: &str) -> String {
        replace_theme(text, &pair("A", "B"))
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/ko-theme-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_theme_block_is_replaced_and_every_other_line_stays() {
        let block = "  theme:\n    light: \"A\"\n    dark: \"B\"\n";
        assert_eq!(
            edited("# keep\napp:\n  theme: old\n  font: {size: 12}\n"),
            format!("# keep\napp:\n{block}  font: {{size: 12}}\n")
        );
        assert_eq!(
            edited("app:\n  theme:\n    light: x\n    dark: y\n  font: {size: 12}\nrest: 1\n"),
            format!("app:\n{block}  font: {{size: 12}}\nrest: 1\n")
        );
        assert_eq!(
            edited("app:\n  font: {size: 12}\n  theme: one # c\n\n  cursor: {blink: true}\n"),
            format!("app:\n  font: {{size: 12}}\n{block}\n  cursor: {{blink: true}}\n")
        );
        assert_eq!(
            edited("app:\n    theme: old\n    font: {size: 12}\n"),
            "app:\n    theme:\n      light: \"A\"\n      dark: \"B\"\n    font: {size: 12}\n"
        );
    }

    #[test]
    fn comments_and_blank_lines_inside_a_theme_block_go_with_it() {
        assert_eq!(
            edited(
                "app:\n  theme:\n    # light one\n    light: x\n\n    # dark one\n    dark: y\n\n  font: {size: 12}\n"
            ),
            "app:\n  theme:\n    light: \"A\"\n    dark: \"B\"\n\n  font: {size: 12}\n"
        );
    }

    #[test]
    fn a_theme_is_added_at_the_end_of_app_or_in_an_app_made_for_it() {
        let block = "  theme:\n    light: \"A\"\n    dark: \"B\"\n";
        assert_eq!(
            edited("runtimes: {}\napp:\n  font: {size: 12}\n\nserver: {}\n"),
            format!("runtimes: {{}}\napp:\n  font: {{size: 12}}\n{block}\nserver: {{}}\n")
        );
        assert_eq!(
            edited("app:\n  font:\n    size: 12\n# note\nserver: {}\n"),
            format!("app:\n  font:\n    size: 12\n{block}# note\nserver: {{}}\n")
        );
        assert_eq!(edited("app:\n"), format!("app:\n{block}"));
        assert_eq!(edited("app: # mine\n"), format!("app: # mine\n{block}"));
        assert_eq!(edited(""), format!("app:\n{block}"));
        assert_eq!(
            edited("# only a comment\nruntimes: {}\n"),
            format!("# only a comment\nruntimes: {{}}\napp:\n{block}")
        );
        assert_eq!(
            edited("runtimes: {}"),
            "runtimes: {}\napp:\n  theme:\n    light: \"A\"\n    dark: \"B\""
        );
    }

    #[test]
    fn a_file_without_a_final_newline_keeps_none() {
        assert_eq!(
            edited("app:\n  theme: old"),
            "app:\n  theme:\n    light: \"A\"\n    dark: \"B\""
        );
        assert_eq!(
            edited("app:\n  font: {size: 12}"),
            "app:\n  font: {size: 12}\n  theme:\n    light: \"A\"\n    dark: \"B\""
        );
    }

    #[test]
    fn crlf_lines_stay_crlf() {
        assert_eq!(
            edited("# keep\r\napp:\r\n  theme: old\r\n  font: {size: 12}\r\n"),
            "# keep\r\napp:\r\n  theme:\r\n    light: \"A\"\r\n    dark: \"B\"\r\n  font: {size: 12}\r\n"
        );
        assert_eq!(
            edited("# keep\r\n"),
            "# keep\r\napp:\r\n  theme:\r\n    light: \"A\"\r\n    dark: \"B\"\r\n"
        );
    }

    #[test]
    fn a_theme_of_another_depth_or_a_comment_is_not_the_theme_of_app() {
        let found = edited("# app:\n#   theme: no\napp:\n  font:\n    theme: nested\n");
        assert_eq!(
            found,
            "# app:\n#   theme: no\napp:\n  font:\n    theme: nested\n  theme:\n    light: \"A\"\n    dark: \"B\"\n"
        );
    }

    #[test]
    fn the_writer_creates_the_file_and_its_directory_with_private_modes() {
        let dir = scratch("create");
        let file = dir.join("nested/config.yaml");
        assert_eq!(set_theme(&file, "A", "B"), Ok(true));
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "app:\n  theme:\n    light: \"A\"\n    dark: \"B\"\n"
        );
        let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o7777;
        assert_eq!(mode(&file), 0o600);
        assert_eq!(mode(&dir.join("nested")), 0o700);
        assert_eq!(set_theme(&file, "A", "B"), Ok(false));
        let before = fs::metadata(&file).unwrap().modified().unwrap();
        assert_eq!(set_theme(&file, "A", "B"), Ok(false));
        assert_eq!(fs::metadata(&file).unwrap().modified().unwrap(), before);
        assert_eq!(
            fs::read_dir(dir.join("nested")).unwrap().count(),
            1,
            "no temporary file stays"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_default_pair_in_a_file_without_a_theme_writes_nothing() {
        let dir = scratch("default");
        let file = dir.join("config.yaml");
        assert_eq!(set_theme(&file, "kido-light", "kido-dark"), Ok(false));
        assert!(!file.exists());
        fs::write(&file, "# mine\n").unwrap();
        assert_eq!(set_theme(&file, "kido-light", "kido-dark"), Ok(false));
        assert_eq!(fs::read_to_string(&file).unwrap(), "# mine\n");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_theme_that_is_one_name_equals_the_pair_of_that_name() {
        let dir = scratch("single");
        let file = dir.join("config.yaml");
        fs::write(&file, "app:\n  theme: solarized\n").unwrap();
        assert_eq!(set_theme(&file, "solarized", "solarized"), Ok(false));
        assert_eq!(set_theme(&file, "solarized", "other"), Ok(true));
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "app:\n  theme:\n    light: \"solarized\"\n    dark: \"other\"\n"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_symlink_is_followed_and_kept_and_the_target_keeps_its_mode() {
        let dir = scratch("link");
        let target = dir.join("real.yaml");
        fs::write(&target, "# mine\n").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o640)).unwrap();
        let link = dir.join("link");
        symlink(&target, &link).unwrap();
        assert_eq!(set_theme(&link, "C", "D"), Ok(true));
        assert_eq!(fs::read_link(&link).unwrap(), target);
        assert_eq!(
            fs::metadata(&target).unwrap().permissions().mode() & 0o7777,
            0o640
        );
        assert_eq!(
            fs::read_to_string(&target).unwrap(),
            "# mine\napp:\n  theme:\n    light: \"C\"\n    dark: \"D\"\n"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_dangling_symlink_gets_its_target_created() {
        let dir = scratch("dangling");
        let target = dir.join("elsewhere/real.yaml");
        let link = dir.join("link");
        symlink(&target, &link).unwrap();
        assert_eq!(set_theme(&link, "A", "B"), Ok(true));
        assert_eq!(fs::read_link(&link).unwrap(), target);
        assert!(
            fs::read_to_string(&target)
                .unwrap()
                .contains("light: \"A\"")
        );
        symlink("relative.yaml", dir.join("again")).unwrap();
        assert_eq!(set_theme(&dir.join("again"), "A", "B"), Ok(true));
        assert!(dir.join("relative.yaml").exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_loop_of_symlinks_is_an_error() {
        let dir = scratch("loop");
        symlink(dir.join("b"), dir.join("a")).unwrap();
        symlink(dir.join("a"), dir.join("b")).unwrap();
        let error = set_theme(&dir.join("a"), "A", "B").unwrap_err();
        assert!(
            matches!(&error, SetError::Io(message) if message.ends_with("too many levels of symbolic links")),
            "{error:?}"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_read_only_file_is_an_error_and_stays_unchanged() {
        let dir = scratch("readonly");
        let file = dir.join("config.yaml");
        fs::write(&file, "# mine\n").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o444)).unwrap();
        let error = set_theme(&file, "A", "B").unwrap_err();
        assert_eq!(error, SetError::Io("permission denied".to_owned()));
        assert_eq!(fs::read_to_string(&file).unwrap(), "# mine\n");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_result_that_does_not_decode_is_not_written() {
        let dir = scratch("refused");
        let file = dir.join("config.yaml");
        for (text, message) in [
            ("app: {theme: x}\n", "duplicate key \"app\""),
            ("app: {font: {size: 12}}\n", "duplicate key \"app\""),
            ("app:\n  theme: x\n  theme: y\n", "duplicate key \"theme\""),
        ] {
            fs::write(&file, text).unwrap();
            let error = set_theme(&file, "A", "B").unwrap_err();
            let SetError::Invalid(problem) = error else {
                panic!("{text}: {error:?}");
            };
            assert!(problem.message.starts_with(message), "{text}: {problem}");
            assert_eq!(fs::read_to_string(&file).unwrap(), text);
        }
        fs::write(&file, "runtimes: [a]\n").unwrap();
        assert!(matches!(
            set_theme(&file, "A", "B"),
            Err(SetError::Invalid(_))
        ));
        assert_eq!(
            set_theme(&file, "a/b", "B"),
            Err(SetError::Name(
                "\"a/b\" is not a theme name without /, a leading dot, a comma, a colon, an equals sign or a control character"
                    .to_owned()
            ))
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_name_with_yaml_syntax_is_written_as_text_and_reads_back() {
        let dir = scratch("quoted");
        let file = dir.join("config.yaml");
        for (light, dark) in [
            ("A # B", "null"),
            ("say \"x\"", "back\\slash"),
            ("true", "123"),
        ] {
            assert_eq!(set_theme(&file, light, dark), Ok(true), "{light} {dark}");
            let found = config::load(&file).unwrap().app.theme.pair();
            assert_eq!((found.light.as_str(), found.dark.as_str()), (light, dark));
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_file_that_changed_since_it_was_read_is_not_replaced() {
        let dir = scratch("changed");
        let file = dir.join("config.yaml");
        fs::write(&file, "# edited meanwhile\n").unwrap();
        assert_eq!(
            replace_file(&file, "# what the edit started from\n", "app: {}\n", 0o600),
            Err(SetError::Changed)
        );
        assert_eq!(fs::read_to_string(&file).unwrap(), "# edited meanwhile\n");
        assert_eq!(
            fs::read_dir(&dir).unwrap().count(),
            1,
            "no temporary file stays"
        );
        assert_eq!(
            replace_file(&file, "# edited meanwhile\n", "app: {}\n", 0o600),
            Ok(())
        );
        assert_eq!(fs::read_to_string(&file).unwrap(), "app: {}\n");
        let new = dir.join("new.yaml");
        fs::write(&new, "x: 1\n").unwrap();
        assert_eq!(
            replace_file(&new, "", "app: {}\n", 0o600),
            Err(SetError::Changed)
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_empty_read_only_file_is_refused_like_any_other() {
        let dir = scratch("empty-readonly");
        let file = dir.join("config.yaml");
        fs::write(&file, "").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o444)).unwrap();
        assert!(matches!(set_theme(&file, "A", "B"), Err(SetError::Io(_))));
        assert_eq!(fs::read_to_string(&file).unwrap(), "");
        fs::remove_dir_all(dir).unwrap();
    }
}
