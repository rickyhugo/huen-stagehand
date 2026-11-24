# Develop with mise

## Set up the tools

Install [mise](https://mise.jdx.dev/getting-started.html) 2026.10.17 or newer.
Install Git with your system package manager. From the repository root, run:

```sh
mise trust
mise install --locked
```

mise pins Zig 0.17.1, hk 2.12.0, jj 0.38.0, tmux 3.8, and Python 3.14.7. `mise.lock` records platform download checksums.
Rust is not part of the current toolchain.

Use `mise run` for project tasks and `mise exec --` for other development
commands. No shell activation is required. Set `MISE_AUTO_INSTALL=false` after
installation to prevent commands from installing missing tools.

hk 2.12.0 has no Intel macOS binary. Run the full shared checks on Apple Silicon
or Linux. Intel Mac source installs and archive builds do not need hk.
For source installation only, install `mise install --locked zig`, then
run `MISE_AUTO_INSTALL=false mise run install`.

Outside mise, the runtime needs Git and tmux on `PATH`. jj is optional unless a
configured repository provider uses it. No fzf, `ls`, `mv`, or Rust runtime is
required.

## Build and test

```sh
MISE_AUTO_INSTALL=false mise run build
MISE_AUTO_INSTALL=false mise run test
MISE_AUTO_INSTALL=false mise run build:release
```

These tasks run `zig build`, `zig build test`, and
`zig build -Doptimize=ReleaseFast`. `zig build test` also runs the packaging
policy tests in `scripts/package.zig`. The application is `zig-out/bin/stagehand`.

Focused checks:

```sh
MISE_AUTO_INSTALL=false mise run test:harness
MISE_AUTO_INSTALL=false mise run test:adapters
MISE_AUTO_INSTALL=false mise run test:commands
MISE_AUTO_INSTALL=false mise run test:terminal
MISE_AUTO_INSTALL=false mise run test:picker:regressions
```

Command regressions check CLI errors, configuration preservation, shell
completion, repository initialization, and literal session names. Terminal
checks run 21 real PTY/popup scenarios. The picker regression task runs 16
focused scenarios. Command and terminal tasks build the release executable.

Packaging policy tests use an independent notice list. They check real archive
writing, verification, notice installation, and negative cases against a
fixture tree. They do not compile or run the application.

## Check a change

Use [Conventional Commits](https://www.conventionalcommits.org/):
`type(scope): description`, with an optional scope and `!` for a breaking
change. Examples: `fix(picker): restore cursor position` and
`chore: update tool versions`. The hk `commit-msg` hook checks new messages.
Run `mise run hooks:setup` once per standalone clone to install the hooks.

```sh
MISE_AUTO_INSTALL=false mise run fmt
MISE_AUTO_INSTALL=false mise run fmt:check
MISE_AUTO_INSTALL=false mise run check
MISE_AUTO_INSTALL=false mise run ci
```

`hk.pkl` defines checks shared by local hooks and CI: Zig formatting, module
tests, a release build, harness isolation, packaging policy, command adapters,
CLI/repository regressions, terminal checks, and picker regressions.
`check` runs `hk check --all`. `ci` first validates hk with warnings denied,
then runs the same check. Neither task runs Rust.

To install hooks, run `mise run hooks:setup` from a standalone clone.
The task refuses linked worktrees to protect the shared Git directory.
It installs no global hooks. The launcher uses mise without shell activation.
hk applies available formatting fixes before a commit.

## Workflows and packaging

`.github/workflows/ci.yml` installs locked tools and calls `mise run ci` on
Linux x86-64 and Apple Silicon. There is no release workflow; build release
archives locally with `mise run package`.

See [packaging](packaging.md) for source installation, release commands,
and platform verification limits.

The migration-only Rust comparison tools, goldens, and ranking oracle were
removed after compatibility verification and successful native Nix builds on
all four systems. See [verification checkpoint](compatibility.md) for evidence.
