# huen-stagehand

Your projects are the scenes. tmux is the stage. `stagehand` moves the sets
so you don't have to.

It's a tmux session manager written in Zig. It finds your Git and jj
repositories, worktrees, and bookmarked directories, then opens each one as a
session from a fast fuzzy picker with live pane previews.

Works on macOS and Linux. Needs tmux and Git; jj is optional.

## Install

With [mise](https://mise.jdx.dev/getting-started.html) 2026.10.17 or newer:

```sh
git clone https://github.com/rickyhugo/huen-stagehand.git
cd huen-stagehand
mise trust && mise install --locked zig
MISE_AUTO_INSTALL=false mise run install   # or: ... install -- /your/prefix
```

This puts `stagehand` in `~/.local/bin`, so make sure that's on your `PATH`.

## Quick start

Tell it where your code lives, then open the picker:

```sh
stagehand config --paths ~/code ~/work
stagehand
```

It works best as a tmux popup. Add these to `~/.tmux.conf`:

```tmux
bind C-o display-popup -E "stagehand"            # open a project
bind C-j display-popup -E "stagehand switch"     # jump to a session
bind C-w display-popup -E "stagehand windows"    # jump to a window
set -g status-right "#(stagehand sessions)"      # sessions in the status bar
```

## Commands

| Command | What it does |
| --- | --- |
| `stagehand` | Find a project and open its session |
| `switch` / `windows` | Pick a session, or a window in this one |
| `start` | Open your configured startup sessions |
| `sessions` | List sessions, with `*` on the current one |
| `kill` | Kill this session and switch to another |
| `rename NAME` | Rename the session and its directory |
| `refresh` | Create any missing worktree windows |
| `clone-repo` / `add URL` | Clone a repo and open it (`add` files it under `~/<host>/<path>`) |
| `init-repo` | Create a new repository |
| `bookmark` | Add any directory to the picker |
| `open-session` | Open a session directly, no picker |
| `marks` | Pin sessions to numbers for quick access |
| `config` | Change search paths and settings |

Use `stagehand COMMAND --help` to see the details.

## Configuration

Most settings are one command away:

```sh
stagehand config --session main
stagehand config --excluded node_modules target
stagehand config --full-path true
```

The config is a TOML file at `~/.config/stagehand/config.toml` on both macOS
and Linux. `XDG_CONFIG_HOME` moves it, and `STAGEHAND_CONFIG_FILE` points it
anywhere you like.

The file also sets search depth, repository providers, bookmarks, startup
sessions, picker colors, and key bindings:

```toml
[shortcuts]
"ctrl-k" = "delete_to_line_end"
```

## Shell completions

```sh
source <(COMPLETE=bash stagehand)   # ~/.bashrc
source <(COMPLETE=zsh stagehand)    # ~/.zshrc
COMPLETE=fish stagehand | source    # ~/.config/fish/config.fish
```

## Development

```sh
mise install --locked
mise run hooks:setup     # once, from a standalone clone (not a worktree)
mise run test            # Zig tests, about a second
mise run check           # what the pre-commit hook runs
mise run check:harness   # + real tmux/PTY/CLI harnesses, takes minutes
```

There's no hosted CI. hk runs every check locally, and the commit hook expects
[Conventional Commits](https://www.conventionalcommits.org/). Run
`check:harness` before a release, or after you change terminal, tmux, or CLI
behavior.

More in [development](docs/development.md) and [packaging](docs/packaging.md).

## Credits

Built on [jrmoulton/tmux-sessionizer](https://github.com/jrmoulton/tmux-sessionizer)
and rewritten in Zig. [MIT](LICENSE) licensed. Third-party notices ship with
every install and archive.
