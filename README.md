# huen-stagehand

A tmux project and session manager written in Zig. The executable is `stagehand`.

- Find Git and jj repositories, worktrees, and bookmarked directories.
- Open projects as sessions with a built-in fuzzy picker.
- Switch sessions and windows with pane previews.
- Configure startup sessions, worktree windows, shortcuts, and indexed marks.

Runs on macOS and Linux. Requires tmux and Git; jj is optional.

## Install

Install [mise](https://mise.jdx.dev/getting-started.html) 2026.10.17 or newer,
then build from source:

```sh
git clone https://github.com/rickyhugo/huen-stagehand.git
cd huen-stagehand
mise trust
mise install --locked zig
MISE_AUTO_INSTALL=false mise run install
```

This uses pinned Zig 0.17.1. The installer places `stagehand` in
`$HOME/.local/bin` and notices in `$HOME/.local/share/licenses/stagehand`.
Add `$HOME/.local/bin` to `PATH`.

To use another prefix:

```sh
MISE_AUTO_INSTALL=false mise run install -- /your/prefix
```

Release archives, when published, are available on the
[releases page](https://github.com/rickyhugo/huen-stagehand/releases).
See [packaging](docs/packaging.md) for targets and checksum verification.

## Quick start

Set the directories to search, then open the picker:

```sh
stagehand config --paths ~/code ~/work
stagehand
```

Add popup bindings to `~/.tmux.conf`:

```tmux
bind C-o display-popup -E "stagehand"
bind C-j display-popup -E "stagehand switch"
bind C-w display-popup -E "stagehand windows"
```

## Commands

| Command | Purpose |
| --- | --- |
| `stagehand` | Find a project and open its session |
| `stagehand switch` | Pick another session |
| `stagehand windows` | Pick a window in the current session |
| `stagehand start` | Open configured startup sessions |
| `stagehand sessions` | List sessions, marking the current one with `*` |
| `stagehand kill` | Kill the current session and switch to another |
| `stagehand rename NAME` | Rename the active session and its directory |
| `stagehand refresh` | Create missing worktree windows |
| `stagehand clone-repo` | Clone a repository and open its session |
| `stagehand add URL` | Clone a repository to `~/<host>/<path>`, add `~/<host>` to the search paths if needed, and open its session |
| `stagehand init-repo` | Create a repository |
| `stagehand bookmark` | Add a directory to the project picker |
| `stagehand open-session` | Open a session directly |
| `stagehand marks` | Manage sessions accessible by index |
| `stagehand config` | Change search paths and other settings |

Run `stagehand --help` or `stagehand COMMAND --help` for arguments and options.

To show sessions in the tmux status bar:

```tmux
set -g status-right "#(stagehand sessions)"
```

## Configuration

Use `stagehand config` for common settings:

```sh
stagehand config --session main
stagehand config --excluded node_modules target
stagehand config --full-path true
```

Default configuration paths:

- Linux: `~/.config/stagehand/config.toml`
- macOS: `~/Library/Application Support/stagehand/config.toml`

Set `STAGEHAND_CONFIG_FILE` to use an explicit path. The configuration supports
search depth, repository providers, bookmarks, startup sessions, picker colors,
and custom key bindings.

For example, add this to the TOML file:

```toml
[shortcuts]
"ctrl-k" = "delete_to_line_end"
```

## Shell completions

Add the matching line to your shell configuration:

```bash
# Bash (~/.bashrc)
source <(COMPLETE=bash stagehand)
```

```zsh
# Zsh (~/.zshrc)
source <(COMPLETE=zsh stagehand)
```

```fish
# Fish (~/.config/fish/config.fish)
COMPLETE=fish stagehand | source
```

## Development

```sh
mise install --locked
mise run hooks:setup
mise run build
mise run test
mise run ci
```

Mise pins the development tools. hk runs shared local and CI checks for
formatting, Zig tests, command behavior, terminal handling, and packaging.
The commit hook enforces [Conventional Commits](https://www.conventionalcommits.org/).

Full hk checks run on Linux and Apple Silicon. Intel macOS supports source
and archive builds; the pinned hk version has no Intel macOS binary.

See [development](docs/development.md) and [packaging](docs/packaging.md).

## Credits and license

Derived from [jrmoulton/tmux-sessionizer](https://github.com/jrmoulton/tmux-sessionizer),
with the application rewritten in Zig.
Licensed under [MIT](LICENSE). Third-party notices accompany installed binaries
and release archives.
