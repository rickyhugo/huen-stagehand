#!/usr/bin/env python3
"""Check repository initialization and listing on private tmux sockets."""

import argparse
import os
from pathlib import Path
import stat
import tempfile

from workspace import Workspace

ROOT = Path(__file__).resolve().parents[2]
TEMPLATES = ROOT / "src/repos/template"
BRANCHES = {
    "branch-empty": ("", None),
    "branch-space": ("a b", None),
    "branch-dots": ("a..b", None),
    "branch-newline": ("feature\n", None),
    "branch-qualified": ("refs/heads/custom", "refs/heads/custom"),
    "branch-reserved": ("HEAD", None),
    "branch-qualified-reserved": ("refs/heads/HEAD", None),
    "branch-feature": ("feature/branch", "refs/heads/feature/branch"),
    "branch-unicode": ("项目", "refs/heads/项目"),
    "branch-hyphen": ("-invalid", "refs/heads/-invalid"),
    "branch-quotes": ('"quoted"', 'refs/heads/"quoted"'),
    "branch-at": ("@", "refs/heads/@"),
}


def check_layout(metadata, head="refs/heads/main"):
    files = {"HEAD", "config"}
    for path in TEMPLATES.rglob("*"):
        if path.is_file() and path.name not in ("README.md", "LICENSE"):
            relative = path.relative_to(TEMPLATES)
            files.add(str(relative))
            assert (metadata / relative).read_bytes() == path.read_bytes(), relative
    assert files == {
        str(path.relative_to(metadata))
        for path in metadata.rglob("*")
        if path.is_file()
    }
    assert (metadata / "HEAD").read_text() == f"ref: {head}\n"
    assert {
        str(path.relative_to(metadata)) for path in metadata.rglob("*") if path.is_dir()
    } == {
        "info",
        "hooks",
        "objects",
        "objects/info",
        "objects/pack",
        "refs",
        "refs/heads",
        "refs/tags",
    }
    config = (metadata / "config").read_text().lower()
    assert "sha256" not in config
    assert "sharedrepository" not in config
    assert "denynonfastforwards" not in config
    for path in [metadata, *metadata.rglob("*")]:
        expected_mode = 0o755 if path.is_dir() else 0o644
        assert stat.S_IMODE(path.stat().st_mode) == expected_mode, path


def check_init(workspace, kind):
    root = workspace.root
    target = root / "search/fresh"
    metadata = target / ".git"
    if kind.startswith("existing-"):
        if kind == "existing-empty":
            metadata.mkdir(parents=True)
        elif kind == "existing-repository":
            workspace.setup("git", "init", str(target))
        else:
            workspace.setup("git", "init", str(root / "other"))
            target.mkdir()
            metadata.write_text("gitdir: " + str(root / "other/.git") + "\n")

        def contents():
            return {
                str(path.relative_to(target)): path.read_bytes()
                for path in target.rglob("*")
                if path.is_file()
            }

        before = contents()
        result = workspace.run(["stagehand", "init-repo", "fresh"])
        assert result.returncode == 1, result
        assert before == contents()
        assert not workspace.sessions()
        return

    if kind.startswith("GIT_"):
        redirect = root / "redirect"
        redirect.mkdir()
        workspace.env[kind] = str(redirect)
    if kind in ("template-config", "template-environment"):
        template = root / "template"
        (template / "hooks").mkdir(parents=True)
        (template / "hooks/post-checkout").write_text("custom hook\n")
        (template / "HEAD").write_text("ref: refs/heads/custom\n")
        workspace.env.update(
            GIT_CONFIG_COUNT="3",
            GIT_CONFIG_KEY_0="init.defaultBranch",
            GIT_CONFIG_VALUE_0="configured",
            GIT_CONFIG_KEY_1="init.templateDir",
            GIT_CONFIG_VALUE_1=str(template),
            GIT_CONFIG_KEY_2="init.defaultObjectFormat",
            GIT_CONFIG_VALUE_2="sha256",
            GIT_DEFAULT_HASH="sha256",
        )
        if kind == "template-environment":
            workspace.env["GIT_TEMPLATE_DIR"] = str(template)
    if kind == "default-branch":
        workspace.env["GIT_CONFIG_COUNT"] = "0"

    result = workspace.run(["stagehand", "init-repo", "fresh"])
    assert result.returncode == 0, result
    assert (metadata / "HEAD").read_text() == (
        "ref: refs/heads/configured\n"
        if kind.startswith("template-")
        else "ref: refs/heads/main\n"
    )
    assert (metadata / "objects/info").is_dir()
    assert (metadata / "objects/pack").is_dir()
    assert "sha256" not in (metadata / "config").read_text()
    for path in TEMPLATES.rglob("*"):
        if path.is_file() and path.name not in ("README.md", "LICENSE"):
            assert (
                metadata / path.relative_to(TEMPLATES)
            ).read_bytes() == path.read_bytes()
    assert not (metadata / "hooks/post-checkout").exists()
    if kind.startswith("GIT_"):
        assert not list((root / "redirect").iterdir())


def check_listing(workspace, name):
    search = str(workspace.root / "search")
    workspace.setup("tmux", "new-session", "-d", "-s", name, "-c", search)
    result = workspace.run(["stagehand", "sessions"])
    assert result.returncode == 0, result
    assert result.stdout == name + "*  \n", repr(result.stdout)


def check_config_sources(workspace, kind):
    global_config = workspace.root / "global-config"
    global_config.write_text("[init]\n defaultBranch = configured\n")
    config_only = workspace.root / "config-only"
    config_only.write_text("" if kind == "config-only-empty" else "[unclosed\n")
    workspace.env.update(
        GIT_CONFIG_COUNT="0",
        GIT_CONFIG_GLOBAL=str(global_config),
        GIT_CONFIG=str(config_only),
    )
    expected, status = "refs/heads/configured", 0
    if kind == "config-global-invalid":
        global_config.write_text("[unclosed\n")
        expected, status = "refs/heads/main", 1
    elif kind == "config-count-invalid":
        workspace.env["GIT_CONFIG_COUNT"] = "not a count"
        expected, status = "refs/heads/main", 1
    elif kind == "config-global-include":
        included = workspace.root / "included-config"
        included.write_text("[init]\n defaultBranch = configured\n")
        global_config.write_text(f"[include]\n path = {included}\n")
    elif kind == "config-environment-overrides-global":
        workspace.env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_VALUE_0="environment")
        expected = "refs/heads/environment"
    result = workspace.run(["stagehand", "init-repo", "fresh"])
    assert result.returncode == status, result
    check_layout(workspace.root / "search/fresh/.git", expected)
    assert len(workspace.sessions()) == (0 if status else 1)


def check_branch(workspace, kind):
    value, expected = BRANCHES.get(kind, ("main", "refs/heads/main"))
    workspace.env["GIT_CONFIG_VALUE_0"] = value
    if kind == "test-default-branch":
        workspace.env["GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME"] = "wrong"
    elif kind == "config-parameters":
        workspace.env["GIT_CONFIG_PARAMETERS"] = "'init.defaultBranch=wrong'"
    elif kind == "config-parameters-invalid":
        workspace.env["GIT_CONFIG_PARAMETERS"] = "not quoted"
    elif kind == "shared-group":
        workspace.env.update(
            GIT_CONFIG_COUNT="2",
            GIT_CONFIG_KEY_1="core.sharedRepository",
            GIT_CONFIG_VALUE_1="group",
        )
    result = workspace.run(["stagehand", "init-repo", "fresh"])
    assert result.returncode == (0 if expected else 1), result
    check_layout(workspace.root / "search/fresh/.git", expected or "refs/heads/main")
    assert len(workspace.sessions()) == (1 if expected else 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/stagehand")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    os.umask(0o022)
    cases = [
        "existing-empty",
        "existing-repository",
        "existing-pointer",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "template-config",
        "template-environment",
        "default-branch",
    ]
    config_cases = [
        "config-only-empty",
        "config-only-invalid",
        "config-global-invalid",
        "config-count-invalid",
        "config-global-include",
        "config-environment-overrides-global",
    ]
    branch_cases = list(BRANCHES) + [
        "test-default-branch",
        "config-parameters",
        "config-parameters-invalid",
        "shared-group",
    ]
    failures = 0
    for case in (
        cases + config_cases + branch_cases + ["quo'te,ui", "'edge'", " a 'b,c "]
    ):
        with tempfile.TemporaryDirectory(prefix="stagehand-commands-") as directory:
            workspace = Workspace(Path(directory).resolve(), binary)
            try:
                (workspace.root / "config.toml").write_text(
                    "[[search_dirs]]\npath = '"
                    + str(workspace.root / "search")
                    + "'\ndepth = 1\n"
                )
                if case in cases:
                    check_init(workspace, case)
                elif case in config_cases:
                    check_config_sources(workspace, case)
                elif case in branch_cases:
                    check_branch(workspace, case)
                else:
                    check_listing(workspace, case)
                print(f"PASS {case}")
            except (AssertionError, OSError) as error:
                failures += 1
                print(f"FAIL {case}: {error}")
            finally:
                workspace.tmux_run("kill-server")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
