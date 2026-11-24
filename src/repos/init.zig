const std = @import("std");
const process = @import("process");
const A = std.mem.Allocator;
const Io = std.Io;

pub fn create(io: Io, a: A, target: []const u8, env: *const std.process.Environ.Map) anyerror!void {
    const metadata = try std.fs.path.join(a, &.{ target, ".git" });
    if (Io.Dir.cwd().statFile(io, metadata, .{ .follow_symlinks = false })) |_| {
        return error.GitError;
    } else |err| if (err != error.FileNotFound) return error.GitError;

    var reference_env = try env.clone(a);
    // gix uses explicit paths and GIT_CONFIG_COUNT, not git-config's file
    // override, Git's shell command parameters, or its test-only branch setting.
    for ([_][]const u8{
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_CONFIG",
        "GIT_CONFIG_PARAMETERS",
        "GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME",
    }) |key| _ = reference_env.swapRemove(key);

    // gix create::into writes a fixed layout before init_opts opens config.
    // Keep Git initialization, but defer all ambient configuration until that
    // layout and its fallback HEAD exist. In particular, sharedRepository must
    // not change either permissions or the generated configuration.
    var layout_env = try reference_env.clone(a);
    try layout_env.put("GIT_CONFIG_NOSYSTEM", "1");
    try layout_env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try layout_env.put("GIT_CONFIG_COUNT", "0");
    _ = layout_env.swapRemove("GIT_DEFAULT_REF_FORMAT");
    const initialized = try process.capture(io, a, .{
        .argv = &.{ "git", "init", "--quiet", "--object-format=sha1", "--template=", "--initial-branch=main", "--shared=umask", target },
        .env = &layout_env,
        .stdin = .ignore,
    });
    if (!success(initialized.term)) return error.GitError;

    // gix 0.85's fixed templates, rather than Git's ambient template directory.
    // Source and license: template/README.md and template/LICENSE.
    var dir = try Io.Dir.cwd().openDir(io, metadata, .{});
    defer dir.close(io);
    inline for (.{
        "description",
        "info/exclude",
        "hooks/docs.url",
        "hooks/applypatch-msg.sample",
        "hooks/commit-msg.sample",
        "hooks/fsmonitor-watchman.sample",
        "hooks/post-update.sample",
        "hooks/pre-applypatch.sample",
        "hooks/pre-commit.sample",
        "hooks/pre-merge-commit.sample",
        "hooks/pre-push.sample",
        "hooks/pre-rebase.sample",
        "hooks/prepare-commit-msg.sample",
    }) |path| {
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = path, .data = @embedFile("template/" ++ path) });
    }

    // Open the new repository's actual config sources only after creation,
    // matching gix init_opts. NUL termination retains invalid trailing newlines.
    const branch = try process.capture(io, a, .{
        .argv = &.{ "git", "--git-dir", metadata, "--work-tree", target, "config", "--null", "--get", "init.defaultBranch" },
        .env = &reference_env,
        .stdin = .ignore,
    });
    if (branch.term == .exited and branch.term.exited == 1) return;
    if (!success(branch.term) or !std.mem.endsWith(u8, branch.stdout, "\x00")) return error.GitError;
    const value = branch.stdout[0 .. branch.stdout.len - 1];
    if (std.mem.eql(u8, value, "main")) return;

    // gix Category::LocalBranch does not prefix an already-qualified name.
    // Its branch_name validation rejects HEAD but accepts leading hyphens in
    // the short name; use full-ref validation, not check-ref-format --branch.
    const qualified = if (std.mem.startsWith(u8, value, "refs/heads/")) value else try std.fmt.allocPrint(a, "refs/heads/{s}", .{value});
    if (std.mem.eql(u8, qualified, "refs/heads/HEAD") or std.mem.indexOfScalar(u8, qualified, 0) != null)
        return error.GitError;
    const valid = try process.capture(io, a, .{
        .argv = &.{ "git", "check-ref-format", qualified },
        .env = &layout_env,
        .stdin = .ignore,
    });
    if (!success(valid.term)) return error.GitError;

    // init_opts replaces HEAD only after validation, with reflog writes disabled.
    try dir.writeFile(io, .{ .sub_path = "HEAD", .data = try std.fmt.allocPrint(a, "ref: {s}\n", .{qualified}) });
}

fn success(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 0;
}
