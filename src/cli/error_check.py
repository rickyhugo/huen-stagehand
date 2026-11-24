#!/usr/bin/env python3
"""Check expected CLI diagnostics and config preservation; optionally compare Rust."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
USAGE = {
    "": "stagehand [COMMAND]",
    "bookmark": "stagehand bookmark [OPTIONS] [PATH]",
    "config": "stagehand config [OPTIONS]\n       stagehand config <COMMAND>",
    "config list": "stagehand config list [OPTIONS]",
    "clone-repo": "stagehand clone-repo [OPTIONS] <REPOSITORY>",
    "marks": "stagehand marks [INDEX]\n       stagehand marks <COMMAND>",
    "marks set": "stagehand marks set [OPTIONS] [INDEX]",
    "marks open": "stagehand marks open <INDEX>",
    "help": "stagehand help [COMMAND]...",
    "config help": "stagehand config help [COMMAND]...",
    "marks help": "stagehand marks help [COMMAND]...",
}
MORE = "\nFor more information, try '--help'.\n"


def usage_error(command, message):
    more = "" if command.endswith("help") else MORE
    return f"error: {message}\n\nUsage: {USAGE[command]}\n{more}"


def invalid_utf8(command):
    return usage_error(command, "invalid UTF-8 was detected in one or more arguments")


def unrecognized(command, value):
    return usage_error(command, f"unrecognized subcommand '{value}'")


def literal_command(command, value):
    return usage_error(
        command,
        f"unexpected argument '{value}' found\n\n"
        f"  tip: subcommand '{value}' exists; to use it, remove the '--' before it",
    )


def missing_value(option):
    return f"error: a value is required for '{option}' but none was supplied\n{MORE}"


def unexpected_value(option, value, usage):
    return (
        f"error: unexpected value '{value}' for '--{option}' found; no more were expected\n\n"
        f"Usage: {usage}\n{MORE}"
    )


def similar_argument(value, suggestion, usage):
    return (
        f"error: unexpected argument '--{value}' found\n\n"
        f"  tip: a similar argument exists: '--{suggestion}'\n\n"
        f"Usage: {usage}\n{MORE}"
    )


def invalid_boolean(value, suggestion=None):
    hint = f"\n  tip: a similar value exists: '{suggestion}'\n" if suggestion else ""
    return (
        f"error: invalid value '{value}' for '--full-path <true | false>'\n"
        f"  [possible values: true, false]\n{hint}{MORE}"
    )


CONFIG_GROUP = (
    "<--paths <search paths>...|--session <default session>|--excluded <excluded dirs>...|"
    "--remove <remove dir>...|--full-path <true | false>|--search-submodules <true | false>|"
    "--recursive-submodules <true | false>|--switch-filter-unknown <true | false>|"
    "--max-depths <max depth>...|--picker-highlight-color <#rrggbb>|"
    "--picker-highlight-text-color <#rrggbb>|--picker-border-color <#rrggbb>|"
    "--picker-info-color <#rrggbb>|--picker-prompt-color <#rrggbb>|"
    "--session-sort-order <Alphabetical | LastAttached>|"
    "--clone-repo-switch <Always | Never | Foreground>|--enable-list-worktrees <true | false>>"
)


CASES = [
    ([b"bookmark", b"invalid-\xff"], invalid_utf8("bookmark")),
    ([b"bookmark", b"--", b"invalid-\xff"], invalid_utf8("bookmark")),
    ([b"config", b"--session", b"invalid-\xff"], invalid_utf8("config")),
    ([b"config", b"--session=invalid-\xff"], invalid_utf8("config")),
    ([b"config", b"-sinvalid-\xff"], invalid_utf8("config")),
    ([b"config", b"--paths", b"invalid-\xff"], invalid_utf8("config")),
    ([b"config", b"--paths=invalid-\xff"], invalid_utf8("config")),
    ([b"config", b"--excluded", b"valid", b"invalid-\xff"], invalid_utf8("config")),
    ([b"config", b"--full-path", b"\xff"], invalid_boolean("�")),
    ([b"config", b"--max-depths", b"\xff"], invalid_utf8("config")),
    ([b"config", b"--picker-border-color", b"\xff"], invalid_utf8("config")),
    ([b"clone-repo", b"--name", b"\xff", b"url"], invalid_utf8("clone-repo")),
    ([b"marks", b"set", b"--path", b"\xff"], invalid_utf8("marks set")),
    ([b"marks", b"open", b"\xff"], invalid_utf8("marks open")),
    (["help", "config", "--help"], unrecognized("config", "--help")),
    (["help", "marks", "--help"], unrecognized("marks", "--help")),
    (["help", "config", "list", "--help"], unrecognized("config list", "--help")),
    (["help", "help", "config"], unrecognized("help", "config")),
    (["config", "help", "help", "list"], unrecognized("config help", "list")),
    (["marks", "help", "help", "list"], unrecognized("marks help", "list")),
    (["--", "config"], literal_command("", "config")),
    (["config", "--", "list"], literal_command("config", "list")),
    (["config", "--", "help"], literal_command("config", "help")),
    (["config", "--", "unknown"], unrecognized("config", "unknown")),
    (["config", "--paths", "--"], missing_value("--paths <search paths>...")),
    (["config", "-p", "--"], missing_value("--paths <search paths>...")),
    (["config", "--session", "--"], missing_value("--session <default session>")),
    *[
        (
            ["config", "--full-path", "true", "--", command],
            usage_error(
                "config",
                f"the subcommand '{command}' cannot be used with '--full-path <true | false>'",
            ),
        )
        for command in ("list", "unknown")
    ],
    (
        ["config", "--session", "--help=x"],
        unexpected_value("help", "x", "stagehand config --help"),
    ),
    (
        ["config", "--paths", "--help="],
        unexpected_value("help", "", "stagehand config --help"),
    ),
    *[
        (["config", "--session", token], missing_value("--session <default session>"))
        for token in ("-hh", "-hx", "-h=x", "-ph", "--full-path=true")
    ],
    *[
        (
            ["config", "--session", "--", command],
            usage_error(
                "config",
                f"the subcommand '{command}' cannot be used with one or more of the other specified arguments",
            ),
        )
        for command in ("list", "unknown", "--help")
    ],
    (
        ["config", "--full-path", "true", "--session", "--", "list"],
        usage_error(
            "config",
            "the subcommand 'list' cannot be used with '--full-path <true | false>'",
        ),
    ),
    *[
        ([b"config", b"--full-path", value], invalid_boolean(display, suggestion))
        for value, display, suggestion in (
            (b"true\xff", "true�", "true"),
            (b"false\xff", "false�", "false"),
            (b"\xfftrue", "�true", "true"),
            (b"TRUE", "TRUE", None),
        )
    ],
    (
        ["config", "--session", "--version"],
        similar_argument(
            "version", "session", "stagehand config --session <default session>"
        ),
    ),
    (
        ["config", "--full-path", "true", "--session", "--version"],
        similar_argument(
            "version",
            "session",
            "stagehand config --full-path <true | false> --session <default session>",
        ),
    ),
    (
        ["config", "--session", "--path=x"],
        similar_argument("path", "paths", "stagehand config --paths <search paths>..."),
    ),
    *[
        (
            [*command, "--help=x"],
            unexpected_value("help", "x", usage),
        )
        for command, usage in (
            (["marks", "set", "--path"], "stagehand marks set --help [INDEX]"),
            (["clone-repo", "--name"], "stagehand clone-repo --help <REPOSITORY>"),
            (["bookmark"], "stagehand bookmark --help [PATH]"),
            (["marks", "delete"], "stagehand marks delete --help <INDEX|--all>"),
            (
                ["config", "--full-path", "true", "--session"],
                f"stagehand config --help {CONFIG_GROUP}",
            ),
            (
                ["config", "--session", "x", "--full-path", "true"],
                f"stagehand config --help {CONFIG_GROUP}",
            ),
            (["config", "--session", "x"], "stagehand config --help"),
        )
    ],
    (
        ["marks", "delete", "--all=x"],
        unexpected_value("all", "x", "stagehand marks delete <INDEX|--all>"),
    ),
    (
        ["marks", "delete", "--al=x"],
        similar_argument("al", "all", "stagehand marks delete <INDEX|--all>"),
    ),
]

SHORT_OPTIONS = [
    ([], [("h", "Print help")]),
    (
        ["config"],
        [
            (
                "p",
                "The paths to search through. Shell like expansions such as '~' are supported",
            ),
            (
                "s",
                "The default session to switch to (if available) when killing another session",
            ),
            (
                "d",
                "The maximum depth to traverse when searching for repositories in search paths, length should match the number of search paths if specified (defaults to 10)",
            ),
            ("h", "Print help"),
        ],
    ),
    (["marks"], [("h", "Print help")]),
]


# Completion candidate separator and trailing text for each shell.
SHELLS = (
    ("bash", None, ""),
    ("elvish", None, ""),
    ("fish", "\t", "\n"),
    ("powershell", "\t", "\n"),
    ("zsh", ":", ""),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", type=Path, default=ROOT / "zig-out/bin/stagehand")
    args = parser.parse_args()
    binary = args.bin.resolve(strict=True)
    failures = 0
    (ROOT / ".zig-cache").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="cli-errors-", dir=ROOT / ".zig-cache"
    ) as d:
        config = Path(d) / "config.toml"
        original = b"default_session = 'preserved'\n"
        env = os.environ | {
            "HOME": d,
            "XDG_CONFIG_HOME": d,
            "STAGEHAND_CONFIG_FILE": str(config),
            "NO_COLOR": "1",
        }
        for key in ("COMPLETE", "TMUX"):
            env.pop(key, None)
        runs = [
            (repr(case), case, {}, (2, b"", stderr.encode(), original))
            for case, stderr in CASES
        ]
        for context, options in SHORT_OPTIONS:
            for token in ("-h=x", "-h=", "-hx=y"):
                words = ["stagehand", *context, token]
                for shell, separator, end in SHELLS:
                    stdout = "\n".join(
                        token + short + (separator + about if separator else "")
                        for short, about in options
                    )
                    index = str(len(words) - 1)
                    runs.append(
                        (
                            f"{shell} {words!r}",
                            ["--", *words],
                            {"COMPLETE": shell, "_CLAP_COMPLETE_INDEX": index},
                            (0, (stdout + end).encode(), b"", original),
                        )
                    )
        for label, argv, extra_env, expected in runs:
            config.write_bytes(original)
            result = subprocess.run(
                [str(binary), *argv],
                cwd=d,
                env=env | extra_env,
                capture_output=True,
                timeout=10,
            )
            actual = (
                result.returncode,
                result.stdout,
                result.stderr,
                config.read_bytes(),
            )
            if actual != expected:
                failures += 1
                print(
                    f"FAIL {binary}: {label}\n"
                    f"  expected: {expected!r}\n  actual: {actual!r}"
                )
    print(f"{len(CASES)} CLI diagnostic/preservation cases; {failures} failures")
    print(f"{len(runs) - len(CASES)} short-option completion cases")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
