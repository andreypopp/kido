from redact import redact

USER = "alice"
HOME = "/Users/alice"


def run(text: str) -> str:
    return redact(text, user=USER, home=HOME)


def test_openai_key_keeps_prefix_and_length() -> None:
    secret = "sk-" + "a1" * 20
    out = run(f"export OPENAI_KEY={secret}")
    assert out == "export OPENAI_KEY=" + "x" * 43
    assert secret not in out


def test_anthropic_and_project_keys() -> None:
    anthropic = "sk-ant-api03-" + "b" * 32
    project = "sk-proj-" + "c" * 40
    out = run(f"{anthropic} {project}")
    assert out == "sk-" + "x" * (len(anthropic) - 3) + " sk-" + "x" * (len(project) - 3)


def test_github_and_slack_and_aws() -> None:
    github = "ghp_" + "b" * 36
    slack = "xoxb-" + "1" * 20
    aws = "AKIA" + "Q" * 16
    out = run(f"{github} {slack} {aws}")
    assert out == "ghp_" + "x" * 36 + " xoxb-" + "x" * 20 + " AKIA" + "X" * 16


def test_jwt_and_bearer() -> None:
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl"
    out = run(f"Authorization: Bearer {jwt}")
    assert out == "Authorization: Bearer " + "x" * len(jwt)
    assert "eyJ" not in out


def test_assignments_keep_key_and_quotes() -> None:
    out = run('password="hunter2" token=abcdefgh key: 12345678')
    assert out == 'password="xxxxxxx" token=xxxxxxxx key: xxxxxxxx'


def test_env_and_yaml_and_json_assignments() -> None:
    out = run('DATABASE_PASSWORD=hunter2\ndb_password: hunter2\n"api_key": "abcdefgh"')
    assert out == 'DATABASE_PASSWORD=xxxxxxx\ndb_password: xxxxxxx\n"api_key": "xxxxxxxx"'


def test_pem_block_is_masked_and_keeps_lines() -> None:
    block = "-----BEGIN PRIVATE KEY-----\nMIIE\nabc\n-----END PRIVATE KEY-----"
    out = run(f"before\n{block}\nafter")
    assert out.splitlines() == [
        "before",
        "x" * 27,
        "xxxx",
        "xxx",
        "x" * 25,
        "after",
    ]
    assert "BEGIN" not in out


def test_url_credentials_are_masked() -> None:
    out = run("fetch https://alice:hunter2@example.com/path")
    assert out == "fetch https://xxxxx:xxxxxxx@example.com/path"


def test_emails_and_home_paths() -> None:
    out = run("mail alice@example.org, see /Users/alice/secret/plan.md")
    assert out == "mail user@example.com, see ~/secret/plan.md"


def test_user_name_everywhere() -> None:
    out = run("alice owns alice-project; ALICE agrees")
    assert out == "user owns user-project; user agrees"


def test_hex_and_base64_keep_length_and_class() -> None:
    hex_run = "a1" * 20
    b64 = "QWxhZGRpbjpvcGVuIHNlc2FtZQ" + "A" * 20
    out = run(f"{hex_run} {b64}")
    assert out == "0" * 40 + " " + "z" * len(b64)


def test_wrapped_tokens_are_masked_and_newline_kept() -> None:
    left = "a1" * 10
    right = "b2" * 10
    out = run(f"{left}\n{right}")
    assert out == "0" * 20 + "\n" + "0" * 20
    out = run("z" * 24 + "\n" + "Q" * 24)
    assert out == "z" * 24 + "\n" + "z" * 24


def test_short_tokens_and_prose_stay_unchanged() -> None:
    text = "deadbeef is short. the key lies here. monkey=banana. mailto: hi"
    assert run(text) == text


def test_line_structure_is_kept() -> None:
    text = "a\nsk-" + "c" * 20 + "\n\tb\r\nend"
    out = run(text)
    assert out.splitlines() == ["a", "sk-" + "x" * 20, "\tb", "end"]
    assert out.count("\n") == text.count("\n")


def test_redaction_is_idempotent() -> None:
    text = (
        "sk-"
        + "a1" * 20
        + " QWxhZGRpbjpvcGVuIHNlc2FtZQ"
        + "A" * 20
        + " DATABASE_PASSWORD=hunter2 /Users/alice/x alice@example.org"
    )
    once = run(text)
    assert run(once) == once


def test_gitlab_npm_pypi_google_and_stripe_keys() -> None:
    values = [
        "glpat-" + "a" * 20,
        "npm_" + "b" * 36,
        "pypi-" + "c" * 20,
        "AIza" + "d" * 35,
        "sk_live_" + "e" * 20,
    ]
    out = run(" ".join(values))
    assert out == (
        "glpat-" + "x" * 20
        + " npm_" + "x" * 36
        + " pypi-" + "x" * 20
        + " AIza" + "x" * 35
        + " sk_live_" + "x" * 20
    )
    assert out == run(out)
