# Instructions

## Tooling and hooks

- Run `mise run hooks:setup` in a standalone clone to install `hk` pre-commit and commit-msg hooks.
- Commits use Conventional Commit titles (`Builtins.check_conventional_commit`).

## Checks

- Fast checks (also run on pre-commit): `mise run check` (`hk validate`, `zig fmt`, `python-ast`, `shellcheck`, and `zig build test`).
- Full PTY, tmux, and CLI harnesses: `mise run check:harness`.
