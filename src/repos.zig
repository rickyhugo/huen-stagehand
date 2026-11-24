const std = @import("std");
const config = @import("config");
const parallel = @import("parallel");
const process = @import("process");
const parsers = @import("repos/parsers.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Provider = config.VcsProvider;
pub const RepoRef = struct {
    path: []const u8,
    provider: Provider,
    git_metadata: ?[]const u8 = null,
};
pub const Search = struct {
    roots: []const config.SearchDirectory,
    excluded: ?[]const []const u8,
    providers: []const Provider,
};
pub const Resolved = struct {
    cwd: []const u8,
    metadata: []const u8,
    bare: bool,
    linked: bool,
};
pub const Worktree = struct { name: []const u8, path: []const u8, prunable: bool };
pub const WorkspaceSet = enum { active_other, registered };
pub const Submodule = struct { name: []const u8, ref: RepoRef };

pub fn discover(io: Io, a: A, search: Search) anyerror![]const RepoRef {
    var found: std.ArrayList(RepoRef) = .empty;
    var level: []const config.SearchDirectory = search.roots;
    // Visiting a whole breadth-first level at once keeps the sequential result order.
    while (level.len > 0) {
        const visits = try a.alloc(anyerror!Visit, level.len);
        defer a.free(visits);
        try parallel.map(io, visits, level, visit, .{ io, a, search });
        var next: std.ArrayList(config.SearchDirectory) = .empty;
        for (level, visits) |current, outcome| switch (try outcome) {
            .skipped => {},
            .repository => |ref| try found.append(a, ref),
            .children => |children| try next.appendSlice(a, children),
            .denied => {
                if (!std.unicode.utf8ValidateSlice(current.path)) return error.NonUtf8Path;
                var buffer: [1024]u8 = undefined;
                var writer = Io.File.stderr().writer(io, &buffer);
                try writer.interface.print("Warning: insufficient permissions to read '{s}'. Skipping directory...\n", .{current.path});
                try writer.interface.flush();
            },
        };
        level = try next.toOwnedSlice(a);
    }
    return found.toOwnedSlice(a);
}

const Visit = union(enum) {
    skipped,
    repository: RepoRef,
    children: []const config.SearchDirectory,
    denied,
};

fn visit(io: Io, a: A, search: Search, current: config.SearchDirectory) anyerror!Visit {
    if (search.excluded) |patterns| {
        if (!std.unicode.utf8ValidateSlice(current.path)) return error.NonUtf8Path;
        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, current.path, pattern) != null) return .skipped;
        }
    }
    if (try detect(io, current.path, search.providers)) |ref| {
        if (!std.unicode.utf8ValidateSlice(std.fs.path.basename(current.path))) return error.NonUtf8Path;
        return .{ .repository = ref };
    }
    if (current.depth == 0) return .skipped;
    var dir = Io.Dir.cwd().openDir(io, current.path, .{ .iterate = true }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => .skipped,
        error.AccessDenied => .denied,
        else => err,
    };
    defer dir.close(io);
    var children: std.ArrayList(config.SearchDirectory) = .empty;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        const path = try std.fs.path.join(a, &.{ current.path, entry.name });
        try children.append(a, .{ .path = path, .depth = current.depth - 1 });
    }
    return .{ .children = children.items };
}

pub fn detect(io: Io, path: []const u8, providers: []const Provider) anyerror!?RepoRef {
    // Stat probes, unlike opening each candidate, avoid the directory close that dominates discovery on macOS.
    for (providers) |provider| {
        const found = switch (provider) {
            .git => entryKind(io, path, ".git", false) != null or
                (entryKind(io, path, "HEAD", false) == .file and
                    entryKind(io, path, "objects", false) == .directory and
                    entryKind(io, path, "refs", false) == .directory),
            .jujutsu => entryKind(io, path, ".jj/repo", true) != null,
        };
        if (found) return .{ .path = path, .provider = provider };
    }
    return null;
}

fn entryKind(io: Io, dir: []const u8, name: []const u8, follow_symlinks: bool) ?Io.File.Kind {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, name }) catch return null;
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = follow_symlinks }) catch return null;
    return stat.kind;
}

pub fn resolve(io: Io, a: A, ref: RepoRef) anyerror!Resolved {
    switch (ref.provider) {
        .git => {
            const metadata = if (ref.git_metadata) |hint|
                try Io.Dir.cwd().realPathFileAlloc(io, hint, a)
            else
                try gitMetadata(io, a, ref.path);
            const common = try gitCommonDirectory(io, a, metadata);
            const common_config = try std.fs.path.join(a, &.{ common, "config" });
            const configured_bare = try process.capture(io, a, .{
                .argv = &.{ "git", "--git-dir", metadata, "--work-tree", metadata, "config", "--file", common_config, "--type=bool", "--get", "core.bare" },
                .cwd = metadata,
                .stdin = .ignore,
            });
            const dotgit = try std.fs.path.join(a, &.{ ref.path, ".git" });
            const bare = if (success(configured_bare.term)) blk: {
                const value = line(configured_bare.stdout);
                if (std.mem.eql(u8, value, "true")) break :blk true;
                if (std.mem.eql(u8, value, "false")) break :blk false;
                return error.InvalidBoolean;
            } else !exists(io, dotgit);
            const linked_metadata = !std.mem.eql(u8, common, metadata);
            var cwd = if (bare and !linked_metadata) metadata else ref.path;
            if (!bare) {
                const configured = try process.capture(io, a, .{
                    .argv = &.{ "git", "--git-dir", metadata, "--work-tree", metadata, "config", "--null", "--show-origin", "--path", "--get-all", "core.worktree" },
                    .cwd = metadata,
                    .stdin = .ignore,
                });
                var override: ?[]const u8 = null;
                var records = std.mem.splitScalar(u8, if (success(configured.term)) configured.stdout else "", 0);
                while (records.next()) |origin| {
                    const value = records.next() orelse break;
                    if (!std.mem.startsWith(u8, origin, "file:")) continue;
                    const source = try std.fs.path.resolve(a, &.{ metadata, origin["file:".len..] });
                    if (!std.mem.startsWith(u8, source, metadata) or
                        source.len <= metadata.len or source[metadata.len] != std.fs.path.sep) continue;
                    override = value;
                }
                if (override) |value| {
                    cwd = try std.fs.path.resolve(a, &.{ metadata, value });
                } else if (!exists(io, dotgit) and std.mem.eql(u8, std.fs.path.basename(metadata), ".git")) {
                    cwd = std.fs.path.dirname(metadata).?;
                }
            }
            return .{
                .cwd = cwd,
                .metadata = metadata,
                .bare = bare,
                .linked = (!bare or linked_metadata) and isFile(io, dotgit),
            };
        },
        .jujutsu => {
            const marker = try std.fs.path.join(a, &.{ ref.path, ".jj/repo" });
            if (!exists(io, marker)) return error.GitError;
            const root = line(try jj(io, a, ref.path, &.{"root"}));
            _ = try jj(io, a, ref.path, &.{ "log", "--no-graph", "--limit", "0", "-r", "@", "-T", "\"\"" });
            const repo_path = try std.fs.path.join(a, &.{ root, ".jj/repo" });
            const linked = isFile(io, repo_path);
            const metadata = if (linked) blk: {
                const pointer = try Io.Dir.cwd().readFileAlloc(io, repo_path, a, .unlimited);
                break :blk try std.fs.path.resolve(a, &.{ std.fs.path.dirname(repo_path).?, line(pointer) });
            } else repo_path;
            const bare = jj(io, a, ref.path, &.{
                "log", "--no-graph", "-r", "@", "-T", "self.empty() ++ \"\\0\" ++ self.parents().map(|parent| parent.root()).join(\"\\0\")",
            }) catch "";
            return .{
                .cwd = root,
                .metadata = metadata,
                .bare = std.mem.eql(u8, bare, "true\x00true"),
                .linked = linked,
            };
        },
    }
}

pub fn isBare(io: Io, a: A, env: *const std.process.Environ.Map, ref: RepoRef) anyerror!bool {
    if (ref.provider == .git and env.get("GIT_COMMON_DIR") == null and env.get("GIT_OBJECT_DIRECTORY") == null) {
        if (gitBare(io, a, ref)) |bare| return bare else |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => {},
        }
    }
    return (try resolve(io, a, ref)).bare;
}

fn gitBare(io: Io, a: A, ref: RepoRef) !bool {
    const metadata = if (ref.git_metadata) |hint| hint else try gitMetadata(io, a, ref.path);
    const pointer = try std.fs.path.join(a, &.{ metadata, "commondir" });
    const bytes = Io.Dir.cwd().readFileAlloc(io, pointer, a, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const common = if (bytes) |value|
        try std.fs.path.resolve(a, &.{ metadata, std.mem.trimEnd(u8, value, "\r\n") })
    else
        metadata;
    for ([_][]const u8{ "objects", "refs" }) |part| {
        const stat = try Io.Dir.cwd().statFile(io, try std.fs.path.join(a, &.{ common, part }), .{});
        if (stat.kind != .directory) return error.NotDir;
    }
    if (!isFile(io, try std.fs.path.join(a, &.{ metadata, "HEAD" }))) return error.GitError;
    const path = try std.fs.path.join(a, &.{ common, "config" });
    const contents = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    return (try parsers.configBare(contents)) orelse !exists(io, try std.fs.path.join(a, &.{ ref.path, ".git" }));
}

pub fn worktrees(io: Io, a: A, ref: RepoRef, set: WorkspaceSet) anyerror![]const Worktree {
    if (ref.provider == .jujutsu and set == .registered) {
        // Preserve the captured linked-workspace NotDir failure.
        const index = try std.fs.path.join(a, &.{ ref.path, ".jj/repo/workspace_store/index" });
        const bytes = try Io.Dir.cwd().readFileAlloc(io, index, a, .unlimited);
        return parsers.workspaceStore(a, bytes);
    }
    const repo = try resolve(io, a, ref);
    var result: std.ArrayList(Worktree) = .empty;
    switch (ref.provider) {
        .git => {
            const common = try gitCommonDirectory(io, a, repo.metadata);
            const admin = try std.fs.path.join(a, &.{ common, "worktrees" });
            var dir = Io.Dir.cwd().openDir(io, admin, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return &.{},
                else => return err,
            };
            defer dir.close(io);
            var entries = dir.iterate();
            while (try entries.next(io)) |entry| {
                const pointer = try std.fs.path.join(a, &.{ admin, entry.name, "gitdir" });
                if (!isFile(io, pointer)) continue;
                const bytes = Io.Dir.cwd().readFileAlloc(io, pointer, a, .unlimited) catch "";
                const path = parsers.worktreePath(a, pointer, bytes) catch "";
                try result.append(a, .{
                    .name = try a.dupe(u8, entry.name),
                    .path = path,
                    .prunable = path.len == 0 or !exists(io, path),
                });
            }
            std.mem.sort(Worktree, result.items, {}, struct {
                fn less(_: void, lhs: Worktree, rhs: Worktree) bool {
                    return std.mem.lessThan(u8, lhs.name, rhs.name);
                }
            }.less);
        },
        .jujutsu => {
            const current = try jjWorkspaceName(io, a, repo.cwd);
            const names = try jj(io, a, ref.path, &.{ "workspace", "list", "-T", "name.substr(0, name.len()) ++ \"\\0\"" });
            var split = std.mem.splitScalar(u8, names, 0);
            while (split.next()) |name| {
                if (name.len == 0 or std.mem.eql(u8, name, current)) continue;
                const option = try std.fmt.allocPrint(a, "--name={s}", .{name});
                const path = line(jj(io, a, ref.path, &.{ "workspace", "root", option }) catch continue);
                const other: RepoRef = .{ .path = path, .provider = .jujutsu };
                const opened = resolve(io, a, other) catch continue;
                const actual_name = jjWorkspaceName(io, a, opened.cwd) catch continue;
                try result.append(a, .{ .name = actual_name, .path = opened.cwd, .prunable = false });
            }
        },
    }
    return result.toOwnedSlice(a);
}

pub fn submodules(io: Io, a: A, ref: RepoRef, recursive: bool) anyerror![]const Submodule {
    if (ref.provider == .jujutsu) return &.{};
    const repo = try resolve(io, a, ref);
    var result: std.ArrayList(Submodule) = .empty;
    try appendSubmodules(io, a, repo, "", recursive, &result);
    return result.toOwnedSlice(a);
}

pub fn cloneRepo(io: Io, a: A, remote: []const u8, target: []const u8) anyerror!void {
    _ = a;
    try Io.Dir.cwd().createDirPath(io, target);
    _ = try process.inherit(io, .{
        .argv = &.{ "git", "clone", remote, target },
        .cwd = std.fs.path.dirname(target) orelse return error.GitError,
    });
}

pub const initRepo = @import("repos/init.zig").create;
pub const parseRemote = parsers.remote;

fn appendSubmodules(io: Io, a: A, repo: Resolved, prefix: []const u8, recursive: bool, result: *std.ArrayList(Submodule)) anyerror!void {
    const file = try std.fs.path.join(a, &.{ repo.cwd, ".gitmodules" });
    var source = [2][]const u8{ "--file", file };
    const regular = if (Io.Dir.cwd().statFile(io, file, .{ .follow_symlinks = false })) |stat| stat.kind != .sym_link else |_| false;
    if (repo.bare or !regular) {
        const blob = for ([_][]const u8{ ":.gitmodules", "HEAD:.gitmodules" }) |candidate| {
            const probe = try process.capture(io, a, .{
                .argv = &.{ "git", "--git-dir", repo.metadata, "--work-tree", repo.metadata, "rev-parse", "--verify", candidate },
                .cwd = repo.metadata,
                .stdin = .ignore,
            });
            if (success(probe.term)) break candidate;
        } else return;
        source = .{ "--blob", blob };
    }
    const output = try process.capture(io, a, .{
        .argv = &.{
            "git",          "--git-dir",               repo.metadata, "--work-tree", repo.metadata, "config", "--null", source[0], source[1],
            "--get-regexp", "^submodule\\..*\\.path$",
        },
        .cwd = repo.metadata,
        .stdin = .ignore,
    });
    if (output.term == .exited and output.term.exited == 1) return;
    if (!success(output.term)) return error.GitError;
    for (try parsers.submoduleEntries(a, output.stdout)) |module| {
        const path = try std.fs.path.resolve(a, &.{ repo.cwd, module.path });
        const dotgit = try std.fs.path.join(a, &.{ path, ".git" });
        const sub: RepoRef = .{
            .path = path,
            .provider = .git,
            .git_metadata = if (exists(io, dotgit)) null else try std.fs.path.join(a, &.{
                try gitCommonDirectory(io, a, repo.metadata), "modules", module.name,
            }),
        };
        const opened = resolve(io, a, sub) catch continue;
        if (opened.bare) continue;
        const basename = std.fs.path.basename(opened.cwd);
        const name = if (prefix.len == 0) basename else try std.fmt.allocPrint(a, "{s}>{s}", .{ prefix, basename });
        if (recursive) appendSubmodules(io, a, opened, name, true, result) catch {};
        try result.append(a, .{ .name = name, .ref = .{ .path = opened.cwd, .provider = .git, .git_metadata = opened.metadata } });
    }
}

fn gitMetadata(io: Io, a: A, path: []const u8) ![]const u8 {
    const dotgit = try std.fs.path.join(a, &.{ path, ".git" });
    const metadata = if (isFile(io, dotgit)) blk: {
        const pointer = try Io.Dir.cwd().readFileAlloc(io, dotgit, a, .unlimited);
        break :blk try parsers.gitdir(a, path, pointer);
    } else if (exists(io, dotgit)) dotgit else blk: {
        const head = try std.fs.path.join(a, &.{ path, "HEAD" });
        if (isFile(io, head)) break :blk path;
        return error.GitError;
    };
    return Io.Dir.cwd().realPathFileAlloc(io, metadata, a);
}

fn gitCommonDirectory(io: Io, a: A, metadata: []const u8) ![]const u8 {
    const common = line(try checked(io, a, &.{
        "git", "--git-dir", metadata, "--work-tree", metadata, "rev-parse", "--path-format=absolute", "--git-common-dir",
    }, metadata));
    return Io.Dir.cwd().realPathFileAlloc(io, common, a);
}

fn jj(io: Io, a: A, cwd: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "jj", "--ignore-working-copy", "--no-pager", "--color=never" });
    try argv.appendSlice(a, args);
    return checked(io, a, argv.items, cwd);
}

fn jjWorkspaceName(io: Io, a: A, cwd: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ cwd, ".jj/working_copy/checkout" });
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    return parsers.checkoutName(bytes);
}

fn checked(io: Io, a: A, argv: []const []const u8, cwd: ?[]const u8) ![]const u8 {
    const output = try process.capture(io, a, .{ .argv = argv, .cwd = cwd, .stdin = .ignore });
    if (!success(output.term)) return error.GitError;
    return output.stdout;
}

fn success(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 0;
}

fn line(bytes: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isFile(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

test {
    _ = parsers;
    _ = @import("repos/tests.zig");
}
