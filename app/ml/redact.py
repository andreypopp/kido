"""Redact secrets and private names before a context leaves the Mac."""

from __future__ import annotations

import re

_NAME = (
    r"(?i:(?:[a-z0-9.-]+[_-])?"
    r"(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|key))"
)
_ENV = r"\b[A-Z0-9_.-]*(?:PASSWORD|PASSWD|SECRET|TOKEN|KEY)[A-Z0-9_.-]*\b"
_ASSIGNMENT = re.compile(
    rf"(?<![A-Za-z0-9_])([\"']?(?:{_NAME}|{_ENV})[\"']?)"
    r"(\s*[:=]\s*)([\"']?)([^\s\"',;]{4,})"
)
_PEM = re.compile(r"-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----", re.S)
_URL = re.compile(r"(?i)\b(https?://)([^/\s:@]+):([^/\s@]+)@")
_BEARER = re.compile(r"(?i)\bBearer\s+([A-Za-z0-9._~+/=-]{8,})")
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")
_SK = re.compile(r"\bsk-[A-Za-z0-9_-]{8,}")
_GITHUB = re.compile(r"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{8,}")
_SLACK = re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{8,}")
_AWS = re.compile(r"\bAKIA[0-9A-Z]{16}\b")
_EMAIL = re.compile(r"(?<![:/\w])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
_HOME = re.compile(r"(?<![A-Za-z0-9_.-])/Users/[A-Za-z0-9._-]+")
_LONG = re.compile(
    r"(?<![A-Za-z0-9])(?P<hex>[0-9A-Fa-f]{32,})(?![A-Za-z0-9])"
    r"|(?<![A-Za-z0-9+/])(?P<base64>[A-Za-z0-9+/]{40,}={0,2})(?![A-Za-z0-9+/=])"
)
_WRAPPED = re.compile(
    r"(?P<left>[A-Za-z0-9+/]{20,})(?P<newline>\r?\n)(?P<right>[A-Za-z0-9+/]{20,})"
)


def _mask(match: re.Match[str], prefix: str, fill: str) -> str:
    return prefix + fill * (len(match.group(0)) - len(prefix))


def _mask_block(text: str) -> str:
    return "".join("\n" if character == "\n" else "x" for character in text)


def redact(text: str, *, user: str, home: str = "/Users") -> str:
    """Replace private values. Newlines and line count never change."""
    text = _PEM.sub(lambda match: _mask_block(match.group(0)), text)
    text = _URL.sub(
        lambda match: match.group(1)
        + "x" * len(match.group(2))
        + ":"
        + "x" * len(match.group(3))
        + "@",
        text,
    )
    if home != "/Users":
        text = re.sub(rf"(?<![A-Za-z0-9_.-]){re.escape(home)}(?=/|$)", "~", text)
    text = _HOME.sub("~", text)
    text = _EMAIL.sub("user@example.com", text)
    text = _JWT.sub(lambda match: "A" * len(match.group(0)), text)
    text = _LONG.sub(
        lambda match: ("0" if match.group("hex") else "z") * len(match.group(0)), text
    )
    text = _WRAPPED.sub(_mask_wrapped, text)
    text = _BEARER.sub(lambda match: _mask(match, "Bearer ", "x"), text)
    text = _SK.sub(lambda match: _mask(match, "sk-", "x"), text)
    text = _GITHUB.sub(
        lambda match: _mask(match, match.group(0)[: match.group(0).index("_") + 1], "x"), text
    )
    text = _SLACK.sub(
        lambda match: _mask(match, match.group(0)[: match.group(0).index("-") + 1], "x"), text
    )
    text = _AWS.sub(lambda match: _mask(match, "AKIA", "X"), text)

    def assignment(match: re.Match[str]) -> str:
        key, separator, quote, value = match.groups()
        return key + separator + quote + "x" * len(value)

    text = _ASSIGNMENT.sub(assignment, text)
    if user:
        text = re.sub(
            rf"(?i)(?<![A-Za-z0-9_]){re.escape(user)}(?![A-Za-z0-9_])",
            "user",
            text,
        )
    return text


def _mask_wrapped(match: re.Match[str]) -> str:
    left = match.group("left")
    right = match.group("right")
    fill = "0" if all(character in "0123456789abcdefABCDEF" for character in left + right) else "z"
    return fill * len(left) + match.group("newline") + fill * len(right)
