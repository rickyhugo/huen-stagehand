"""Isolated filesystem, Git configuration, and tmux server for command tests."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


class Workspace:
    def __init__(self, root, binary):
        self.root = root
        path = os.pathsep.join(
            entry
            for entry in os.environ["PATH"].split(os.pathsep)
            if not (Path(entry).name == "shims" and "mise" in Path(entry).parts)
        )
        self.tmux = shutil.which("tmux", path=path)
        if not self.tmux:
            raise RuntimeError("tmux is required")
        self.socket = "stagehand-test-" + uuid.uuid4().hex
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("STAGEHAND_", "GIT_", "JJ_", "_CLAP_"))
            and key not in ("TMUX", "TMUX_PANE", "COMPLETE")
        }
        self.env.update(
            HOME=str(root / "home"),
            XDG_CONFIG_HOME=str(root / "home/.config"),
            STAGEHAND_CONFIG_FILE=str(root / "config.toml"),
            STAGEHAND_TEST_ROOT=str(root),
            STAGEHAND_TEST_SOCKET=self.socket,
            STAGEHAND_TMUX_SOCKET=self.socket,
            STAGEHAND_REAL_TMUX=self.tmux,
            TERM_PROGRAM="tmux",
            TERM="xterm-256color",
            LC_ALL="C",
            LANG="C",
            TZ="UTC",
            NO_COLOR="1",
            COLUMNS="100",
            LINES="30",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_COUNT="1",
            GIT_CONFIG_KEY_0="init.defaultBranch",
            GIT_CONFIG_VALUE_0="main",
            JJ_CONFIG="",
        )
        for directory in ("home", "search", "bin"):
            (root / directory).mkdir()
        (root / "bin/stagehand").symlink_to(binary)
        shim = root / "bin/tmux"
        shim.write_text(
            f"#!{sys.executable}\n"
            + Path(__file__).with_name("tmux_shim.py").read_text()
        )
        shim.chmod(0o755)
        self.env["PATH"] = str(root / "bin") + os.pathsep + path
        (root / "tmux.conf").write_text(
            "set -g default-shell /bin/sh\n"
            "set -g default-command 'exec /bin/sleep 600'\n"
            "set -g base-index 1\n"
            "set -g automatic-rename off\n"
            "set -g status off\n"
        )

    def run(self, argv):
        return subprocess.run(
            argv,
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def tmux_run(self, *argv):
        return self.run(
            [self.tmux, "-f", str(self.root / "tmux.conf"), "-L", self.socket, *argv]
        )

    def setup(self, command, *args):
        result = (
            self.tmux_run(*args) if command == "tmux" else self.run([command, *args])
        )
        if result.returncode:
            raise RuntimeError(result.stderr)

    def sessions(self):
        return self.tmux_run(
            "list-sessions", "-F", "#{session_name}"
        ).stdout.splitlines()
