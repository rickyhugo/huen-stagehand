const std = @import("std");
const config = @import("config");
const parallel = @import("parallel");
const repos = @import("repos");
const tmux = @import("tmux");
const A = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;

pub const Index = usize;
pub const Source = union(enum) { repository: repos.RepoRef, bookmark: []const u8 };
pub const Session = struct { key: []const u8, name: []const u8, source: Source };
pub const Catalog = struct {
    entries: []const Session,
    by_key: std.StringHashMapUnmanaged(Index),
};

fn sourcePath(entry: Session) []const u8 {
    return switch (entry.source) {
        .repository => |ref| ref.path,
        .bookmark => |p| p,
    };
}

fn entryFor(ref: repos.RepoRef, name: []const u8) Session {
    return .{ .key = name, .name = name, .source = .{ .repository = ref } };
}

pub fn discover(io: Io, a: A, env: *const Env, cfg: *const config.Config) anyerror!Catalog {
    const roots = try config.searchRoots(io, a, env, cfg);
    const providers: []const repos.Provider = cfg.vcs_providers orelse &.{.git};
    const found = try repos.discover(io, a, .{ .roots = roots, .excluded = cfg.excluded_dirs, .providers = providers });
    const trees = try a.alloc(anyerror![]const Session, found.len);
    if (cfg.list_worktrees == true) {
        try parallel.map(io, trees, found, worktreeEntries, .{ io, a, env, providers });
    } else @memset(trees, &.{});
    var list: std.ArrayList(Session) = .empty;
    for (found, trees) |ref, entries| {
        try list.appendSlice(a, try entries);
        try list.append(a, entryFor(ref, std.fs.path.basename(ref.path)));
    }
    for (try config.bookmarkPaths(io, a, env, cfg)) |p| {
        const name = std.fs.path.basename(p);
        try list.append(a, .{ .key = name, .name = name, .source = .{ .bookmark = p } });
    }
    try deduplicate(a, list.items);
    for (list.items) |*entry| entry.key = if (cfg.display_full_path == true) sourcePath(entry.*) else entry.name;
    const modules = try a.alloc(anyerror![]const Session, list.items.len);
    if (cfg.search_submodules == true) {
        try parallel.map(io, modules, list.items, submoduleEntries, .{ io, a, cfg });
    } else @memset(modules, &.{});
    var expanded: std.ArrayList(Session) = .empty;
    for (list.items, modules) |entry, children| {
        try expanded.appendSlice(a, try children);
        try expanded.append(a, entry);
    }
    return catalog(a, expanded.items);
}

fn worktreeEntries(io: Io, a: A, env: *const Env, providers: []const repos.Provider, ref: repos.RepoRef) anyerror![]const Session {
    if (!try repos.isBare(io, a, env, ref)) return &.{};
    var entries: std.ArrayList(Session) = .empty;
    for (try repos.worktrees(io, a, ref, .registered)) |tree| {
        const tree_ref = (repos.detect(io, tree.path, providers) catch null) orelse continue;
        try entries.append(a, entryFor(tree_ref, try std.fmt.allocPrint(a, "{s}#{s}", .{ std.fs.path.basename(ref.path), tree.name })));
    }
    return entries.items;
}

fn submoduleEntries(io: Io, a: A, cfg: *const config.Config, entry: Session) anyerror![]const Session {
    if (entry.source != .repository or entry.source.repository.provider != .git) return &.{};
    var entries: std.ArrayList(Session) = .empty;
    try appendSubmodules(io, a, &entries, entry.source.repository, entry.key, cfg);
    return entries.items;
}

fn appendSubmodules(io: Io, a: A, list: *std.ArrayList(Session), ref: repos.RepoRef, parent: []const u8, cfg: *const config.Config) !void {
    const children = repos.submodules(io, a, ref, false) catch return;
    for (children) |child| {
        const name = try std.fmt.allocPrint(a, "{s}>{s}", .{ parent, std.fs.path.basename(child.ref.path) });
        var entry = entryFor(child.ref, name);
        entry.key = if (cfg.display_full_path == true) child.ref.path else name;
        if (cfg.recursive_submodules == true) try appendSubmodules(io, a, list, child.ref, entry.key, cfg);
        try list.append(a, entry);
    }
}

fn componentFromEnd(p: []const u8, depth: usize) ?[]const u8 {
    var end = p.len;
    var n: usize = 0;
    while (end > 0) {
        while (end > 0 and p[end - 1] == '/') end -= 1;
        if (end == 0) break;
        var start = end;
        while (start > 0 and p[start - 1] != '/') start -= 1;
        if (n == depth) return p[start..end];
        n += 1;
        end = start;
    }
    if (n == depth and std.fs.path.isAbsolute(p)) return "/";
    return null;
}

fn deduplicate(a: A, entries: []Session) !void {
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    defer {
        for (groups.values()) |*group| group.deinit(a);
        groups.deinit(a);
    }
    for (entries, 0..) |entry, i| {
        const slot = try groups.getOrPut(a, entry.name);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(a, i);
    }
    for (groups.values()) |group| {
        if (group.items.len < 2) continue;
        var depth: usize = 1;
        for (group.items, 0..) |current, k| {
            var current_depth: usize = 1;
            while (componentFromEnd(sourcePath(entries[current]), current_depth)) |part| : (current_depth += 1) {
                for (group.items[0..k]) |j| {
                    const other = componentFromEnd(sourcePath(entries[j]), current_depth) orelse continue;
                    if (std.mem.eql(u8, part, other)) break;
                } else break;
            }
            depth = @max(depth, current_depth);
        }
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(a);
        for (group.items) |j| {
            const p = sourcePath(entries[j]);
            parts.clearRetainingCapacity();
            for (0..depth + 1) |n| try parts.append(a, componentFromEnd(p, n) orelse break);
            std.mem.reverse([]const u8, parts.items);
            entries[j].name = try std.mem.join(a, "/", parts.items);
        }
        for (0..group.items.len / 2) |j| {
            std.mem.swap(Session, &entries[group.items[j]], &entries[group.items[group.items.len - 1 - j]]);
        }
    }
}

fn catalog(a: A, entries: []const Session) !Catalog {
    var by_key: std.StringHashMapUnmanaged(Index) = .empty;
    var unique: std.ArrayList(Session) = .empty;
    for (entries) |entry| {
        const slot = try by_key.getOrPut(a, entry.key);
        if (slot.found_existing) {
            unique.items[slot.value_ptr.*] = entry;
        } else {
            slot.value_ptr.* = unique.items.len;
            try unique.append(a, entry);
        }
    }
    std.mem.sort(Session, unique.items, {}, struct {
        fn less(_: void, lhs: Session, rhs: Session) bool {
            return std.mem.lessThan(u8, lhs.key, rhs.key);
        }
    }.less);
    by_key.clearRetainingCapacity();
    for (unique.items, 0..) |entry, i| try by_key.put(a, entry.key, i);
    return .{ .entries = try unique.toOwnedSlice(a), .by_key = by_key };
}

pub fn activeTimestamp(key: []const u8, snapshot: tmux.Snapshot) ?i64 {
    for (snapshot.sessions) |s| {
        if (s.attached) continue;
        const timestamp = std.fmt.parseInt(i64, s.last_attached, 10) catch continue;
        if (std.mem.eql(u8, key, s.name)) return timestamp;
        if (key.len != s.name.len) continue;
        for (key, s.name) |c, d| {
            if ((if (c == '.' or c == '-') '_' else c) != d) break;
        } else return timestamp;
    }
    return null;
}

pub fn orderedIndices(a: A, entries: Catalog, snapshot: tmux.Snapshot, order: config.Order) anyerror![]const Index {
    const indices = try a.alloc(Index, entries.entries.len);
    for (indices, 0..) |*index, i| index.* = i;
    if (order == .last_attached) {
        const stamps = try a.alloc(?i64, indices.len);
        defer a.free(stamps);
        for (stamps, entries.entries) |*stamp, entry| stamp.* = activeTimestamp(entry.key, snapshot);
        std.mem.sort(Index, indices, stamps, struct {
            fn less(ctx: []const ?i64, lhs: Index, rhs: Index) bool {
                const l = ctx[lhs];
                const r = ctx[rhs];
                if (l != null and r == null) return true;
                if (l == null and r != null) return false;
                if (l != null and l.? != r.?) return l.? > r.?;
                return lhs < rhs;
            }
        }.less);
    }
    return indices;
}

pub fn fromPath(io: Io, a: A, env: *const Env, input_path: []const u8) anyerror!Session {
    const expanded = try config.expandPath(io, a, env, input_path);
    const p = try std.Io.Dir.cwd().realPathFileAlloc(io, expanded, a);
    const name = std.fs.path.basename(p);
    if (name.len == 0) return error.InvalidSessionName;
    return .{ .key = name, .name = name, .source = .{ .bookmark = p } };
}

pub fn path(io: Io, a: A, entry: Session) anyerror![]const u8 {
    const ref = switch (entry.source) {
        .bookmark => |p| return p,
        .repository => |ref| ref,
    };
    const resolved = try repos.resolve(io, a, ref);
    return if (resolved.bare) resolved.cwd else try std.Io.Dir.cwd().realPathFileAlloc(io, resolved.cwd, a);
}

pub fn open(io: Io, a: A, entry: Session, client: *const tmux.Client, cfg: *const config.Config) anyerror!void {
    const cwd = try path(io, a, entry);
    const name = try std.mem.replaceOwned(u8, a, entry.name, ".", "_");
    for (try client.listSessions(io, a)) |s| {
        if (std.mem.eql(u8, s.name, name)) break;
    } else {
        _ = try client.newSession(io, a, name, cwd);
        const configured = if (cfg.session_configs) |configs| configs.get(name) else null;
        const script = (if (configured) |item| item.create_script else null) orelse try std.fs.path.join(a, &.{ sourcePath(entry), ".stagehand-create" });
        if (std.Io.Dir.cwd().access(io, script, .{})) |_| {
            _ = try client.sendKeys(io, a, script, try std.fmt.allocPrint(a, "{s}:{{start}}.{{top}}", .{name}));
        } else |_| {}
    }
    try client.switchTo(io, a, name);
}

test "duplicate groups share ancestor depth, not shortest unique suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries = [_]Session{
        .{ .key = "test", .name = "test", .source = .{ .bookmark = "/search/path/to/proj1/test" } },
        .{ .key = "test", .name = "test", .source = .{ .bookmark = "/search/path/to/proj2/test" } },
        .{ .key = "test", .name = "test", .source = .{ .bookmark = "/other/path/to/projects/proj2/test" } },
    };
    try deduplicate(a, &entries);
    try std.testing.expectEqualStrings("projects/proj2/test", entries[0].name);
    try std.testing.expectEqualStrings("to/proj2/test", entries[1].name);
    try std.testing.expectEqualStrings("to/proj1/test", entries[2].name);
}

test "ancestor components include exactly one root and identical paths retain Rust root joining" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/", componentFromEnd("/a/x", 2).?);
    try std.testing.expect(componentFromEnd("/a/x", 3) == null);
    var entries = [_]Session{
        .{ .key = "x", .name = "x", .source = .{ .bookmark = "/a/x" } },
        .{ .key = "x", .name = "x", .source = .{ .bookmark = "/a/x" } },
    };
    try deduplicate(a, &entries);
    try std.testing.expectEqualStrings("//a/x", entries[0].name);
    try std.testing.expectEqualStrings("//a/x", entries[1].name);
}

test "catalog sorts visible keys and retains final replacement at stable index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try catalog(arena.allocator(), &.{
        .{ .key = "z", .name = "old", .source = .{ .bookmark = "/z" } },
        .{ .key = "a", .name = "a", .source = .{ .bookmark = "/a" } },
        .{ .key = "z", .name = "new", .source = .{ .bookmark = "/new" } },
    });
    try std.testing.expectEqual(@as(usize, 0), result.by_key.get("a").?);
    try std.testing.expectEqualStrings("new", result.entries[result.by_key.get("z").?].name);
}

test "full path keys remain distinct from tmux names and survive picker ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try catalog(a, &.{
        .{ .key = "/z/project.one", .name = "project.one", .source = .{ .bookmark = "/z/project.one" } },
        .{ .key = "/a/other", .name = "other", .source = .{ .bookmark = "/a/other" } },
    });
    const index = result.by_key.get("/z/project.one").?;
    _ = try orderedIndices(a, result, .{ .current = null, .sessions = &.{} }, .last_attached);
    try std.testing.expectEqual(index, result.by_key.get("/z/project.one").?);
    try std.testing.expectEqualStrings("project.one", result.entries[index].name);
    try std.testing.expectEqualStrings("/z/project.one", sourcePath(result.entries[index]));
}

test "default picker timestamps are numeric and active dots and hyphens normalize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try catalog(a, &.{
        .{ .key = "a.b", .name = "a.b", .source = .{ .bookmark = "/a" } },
        .{ .key = "c-d", .name = "c-d", .source = .{ .bookmark = "/c" } },
        .{ .key = "e", .name = "e", .source = .{ .bookmark = "/e" } },
    });
    const snapshot: tmux.Snapshot = .{ .current = null, .sessions = &.{
        .{ .name = "a_b", .attached = false, .last_attached = "9" },
        .{ .name = "c_d", .attached = false, .last_attached = "10" },
        .{ .name = "e", .attached = true, .last_attached = "100" },
    } };
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, try orderedIndices(a, entries, snapshot, .last_attached));
}
