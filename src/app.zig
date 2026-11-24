const std = @import("std");
const cli = @import("cli");
const config = @import("config");
const repos = @import("repos");
const sessions = @import("sessions");
const tmux = @import("tmux");
const picker = @import("picker");
const process = @import("process");
const A = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;

pub const Failure = union(enum) {
    session_not_found: []const u8,
    unsupported_remote: []const u8,
    mark_not_found: usize,
    no_search_path,
    invalid_repository_name,
};
pub threadlocal var failure: ?Failure = null;

const App = struct {
    io: Io,
    a: A,
    scratch: A,
    env: *const Env,
    cfg: *config.Config,
    client: tmux.Client,

    fn choose(self: App, items: []const picker.Item) !?usize {
        return picker.choose(self.io, self.a, self.scratch, items, try config.pickerOptions(self.a, self.cfg));
    }

    fn start(self: App) !void {
        const startup = self.cfg.sessions orelse {
            _ = try self.client.start(self.io, self.a);
            return;
        };
        for (startup) |session| {
            const session_path = if (session.path) |p| try config.expandPath(self.io, self.a, self.env, p) else null;
            _ = try self.client.newSession(self.io, self.a, session.name, session_path);
            for (session.windows orelse continue) |window| {
                const p = if (window.path) |value| try config.expandPath(self.io, self.a, self.env, value) else null;
                _ = try self.client.newWindow(self.io, self.a, window.name, p, null);
                if (window.command) |text| _ = try self.client.sendKeys(self.io, self.a, text, null);
            }
            _ = try self.client.killWindow(self.io, self.a, ":1");
        }
        try self.client.attach(self.io, self.a, null, null);
    }

    fn kill(self: App) !void {
        const snapshot = try self.client.snapshot(self.io, self.a);
        const current = if (snapshot.current) |s| s.name else "";
        const available = try unattached(self.a, snapshot.sessions, self.cfg.session_sort_order);
        var target: ?[]const u8 = if (available.len > 0) available[0].name else null;
        if (self.cfg.default_session) |default| {
            if (!std.mem.eql(u8, default, current)) for (available) |entry| {
                if (std.mem.eql(u8, entry.name, default)) target = default;
            };
        }
        if (target) |name| _ = try self.client.switchClient(self.io, self.a, name);
        _ = try self.client.killSession(self.io, self.a, current);
    }

    fn rename(self: App, name: []const u8) !void {
        const snapshot = try self.client.snapshot(self.io, self.a);
        const current = if (snapshot.current) |s| s.name else "";
        const panes = try self.client.panes(self.io, self.a);
        if (panes.len == 0) return error.NoCurrentPane;
        const destination = try std.mem.replaceOwned(u8, self.a, panes[0].cwd, current, name);
        process.movePath(self.io, self.a, panes[0].cwd, destination) catch {};
        for (panes) |pane| {
            const pane_path = try std.mem.replaceOwned(u8, self.a, pane.cwd, current, name);
            _ = try self.client.sendKeys(self.io, self.a, try std.fmt.allocPrint(self.a, "cd {s}", .{pane_path}), pane.index);
        }
        _ = try self.client.renameSession(self.io, self.a, name);
        try self.client.attach(self.io, self.a, null, destination);
    }

    fn searchPath(self: App) !?[]const u8 {
        const roots = self.cfg.search_dirs orelse &.{};
        var items: std.ArrayList(picker.Item) = .empty;
        for (roots, 0..) |root, i| {
            if (root.depth == 0) continue;
            try items.append(self.a, .{ .id = i, .label = root.path, .preview = .{ .directory = root.path } });
        }
        if (items.items.len == 0) {
            failure = .no_search_path;
            return error.NoSearchPath;
        }
        const index = if (items.items.len == 1) items.items[0].id else (try self.choose(items.items)) orelse return null;
        return try config.expandPath(self.io, self.a, self.env, roots[index].path);
    }

    fn newRepoSession(self: App, name: []const u8, target: []const u8) ![]const u8 {
        const session_name = for (try self.client.listSessions(self.io, self.a)) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const parent = std.fs.path.basename(std.fs.path.dirname(target) orelse return error.InvalidRepositoryName);
            break try std.fmt.allocPrint(self.a, "{s}/{s}", .{ parent, name });
        } else name;
        _ = try self.client.newSession(self.io, self.a, session_name, target);
        return session_name;
    }

    fn cwd(self: App) ![]const u8 {
        return Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.a);
    }
};

fn print(io: Io, text: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, text);
}

fn inferredName(remote: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, remote, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse {
        failure = .invalid_repository_name;
        return error.InvalidRepositoryName;
    };
    var name = trimmed[slash + 1 ..];
    while (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    return name;
}

fn sessionListing(a: A, snapshot: tmux.Snapshot) ![]const u8 {
    const current = if (snapshot.current) |s| s.name else "";
    var text: std.ArrayList(u8) = .empty;
    for (snapshot.sessions) |s| {
        try text.appendSlice(a, s.name);
        if (std.mem.eql(u8, current, s.name)) try text.append(a, '*');
        try text.append(a, ' ');
    }
    if (snapshot.sessions.len == 0 and current.len == 0) try text.append(a, '*');
    try text.appendSlice(a, " \n");
    return text.toOwnedSlice(a);
}

fn unattached(a: A, list: []const tmux.SessionInfo, order: ?config.Order) ![]const tmux.SessionInfo {
    var result: std.ArrayList(tmux.SessionInfo) = .empty;
    for (list) |s| if (!s.attached) try result.append(a, s);
    if (order == .last_attached) {
        std.mem.sort(tmux.SessionInfo, result.items, {}, struct {
            fn less(_: void, lhs: tmux.SessionInfo, rhs: tmux.SessionInfo) bool {
                return std.mem.lessThan(u8, rhs.last_attached, lhs.last_attached);
            }
        }.less);
    }
    return result.toOwnedSlice(a);
}

pub fn run(io: Io, a: A, scratch: A, argv: []const []const u8, env: *const Env) anyerror!void {
    if (try cli.complete(io, a, argv, env)) return;
    const cmd = try cli.parse(a, if (argv.len > 0) argv[1..] else &.{});
    if (cmd == .help) return print(io, try cli.help(a, cmd.help));
    var cfg = try config.load(io, a, env);
    const socket = env.get("STAGEHAND_TMUX_SOCKET") orelse "default";
    const app: App = .{
        .io = io,
        .a = a,
        .scratch = scratch,
        .env = env,
        .cfg = &cfg,
        .client = .{
            .socket = socket,
            .inside_tmux = std.mem.eql(u8, env.get("TERM_PROGRAM") orelse "", "tmux"),
            .executable = tmux.serverExecutable(io, a, env.get("TMUX"), socket) orelse "tmux",
        },
    };
    const client = &app.client;
    switch (cmd) {
        .pick => {
            const catalog = try sessions.discover(io, a, env, &cfg);
            const order = cfg.session_sort_order orelse .alphabetical;
            const snapshot: tmux.Snapshot = .{ .sessions = if (order == .last_attached) try client.listSessions(io, a) else &.{}, .current = null };
            const indices = try sessions.orderedIndices(a, catalog, snapshot, order);
            const items = try a.alloc(picker.Item, indices.len);
            for (indices, items) |index, *item| {
                const key = catalog.entries[index].key;
                item.* = .{ .id = index, .label = key, .active = sessions.activeTimestamp(key, snapshot) != null };
            }
            if (try app.choose(items)) |index| try sessions.open(io, a, catalog.entries[index], client, &cfg);
        },
        .start => try app.start(),
        .switch_session => {
            const available = try unattached(a, try client.listSessions(io, a), cfg.session_sort_order);
            const catalog: ?sessions.Catalog = if (cfg.switch_filter_unknown == true) try sessions.discover(io, a, env, &cfg) else null;
            var items: std.ArrayList(picker.Item) = .empty;
            for (available, 0..) |entry, i| {
                if (catalog) |known| if (!known.by_key.contains(entry.name)) continue;
                try items.append(a, .{ .id = i, .label = entry.name, .preview = .{ .pane = .{ .client = client, .target = entry.name } } });
            }
            const index = (try app.choose(items.items)) orelse return;
            _ = try client.switchClient(io, a, try std.mem.replaceOwned(u8, a, available[index].name, ".", "_"));
        },
        .windows => {
            const windows = try client.windows(io, a, null);
            var items: std.ArrayList(picker.Item) = .empty;
            for (windows, 0..) |window, i| {
                if (window.attached) continue;
                try items.append(a, .{
                    .id = i,
                    .label = try std.fmt.allocPrint(a, "{s} {s}", .{ window.id, window.name }),
                    .preview = .{ .pane = .{ .client = client, .target = window.id } },
                });
            }
            if (items.items.len == 0) try items.append(a, .{ .id = windows.len, .label = "" });
            const index = (try app.choose(items.items)) orelse return;
            if (index < windows.len) _ = try client.selectWindow(io, a, windows[index].id);
        },
        .kill => try app.kill(),
        .sessions => {
            try print(io, try sessionListing(a, try client.listingSnapshot(io, a)));
            try io.sleep(.fromMilliseconds(100), .awake);
            _ = try client.refreshClient(io, a);
        },
        .rename => |name| try app.rename(name),
        .refresh => |requested| {
            const current = (try client.snapshot(io, a)).current orelse return;
            const name = try std.mem.replaceOwned(u8, a, std.mem.trim(u8, requested orelse current.name, " \r\n"), "'", "");
            const existing = try client.windows(io, a, name);
            const ref = (repos.detect(io, current.path, cfg.vcs_providers orelse &.{.git}) catch null) orelse return;
            const resolved = repos.resolve(io, a, ref) catch return;
            var count: usize = 0;
            for (repos.worktrees(io, a, ref, .active_other) catch &.{}) |tree| {
                const exists = for (existing) |window| {
                    if (std.mem.eql(u8, window.name, tree.name)) break true;
                } else false;
                if (!exists and tree.prunable) continue;
                count += 1;
                if (!exists) _ = try client.newWindow(io, a, tree.name, tree.path, name);
            }
            if (!resolved.bare and (try client.windows(io, a, name)).len <= count)
                _ = try client.newWindow(io, a, null, current.path, name);
        },
        .clone_repo => |args| {
            const root = if (args.path) |p| try Io.Dir.cwd().realPathFileAlloc(io, p, a) else (try app.searchPath()) orelse return;
            const name = args.name orelse try inferredName(args.repository);
            const target = if (std.fs.path.isAbsolute(name)) name else try std.fs.path.join(a, &.{ root, name });
            const previous = try client.attachedSession(io, a);
            try repos.cloneRepo(io, a, args.repository, target);
            const should_switch = switch (cfg.clone_repo_switch orelse .always) {
                .always => true,
                .never => false,
                .foreground => std.mem.eql(u8, previous, try client.attachedSession(io, a)),
            };
            const session_name = try app.newRepoSession(name, target);
            if (should_switch) try client.switchTo(io, a, session_name);
        },
        .add => |text| {
            const location = repos.parseRemote(a, text) catch |err| switch (err) {
                error.UnsupportedRemote => {
                    failure = .{ .unsupported_remote = text };
                    return err;
                },
                else => return err,
            };
            const host_dir = try std.fs.path.join(a, &.{ try config.expandPath(io, a, env, "~"), location.host });
            const target = try std.fs.path.join(a, &.{ host_dir, location.path });
            if (try repos.detect(io, target, &.{.git}) == null) {
                try repos.cloneRepo(io, a, location.url, target);
                if (try repos.detect(io, target, &.{.git}) == null) {
                    // Only succeeds when the failed clone left the directory empty.
                    Io.Dir.cwd().deleteDir(io, target) catch {};
                    return error.GitError;
                }
            }
            if (!try config.searchReaches(io, a, env, &cfg, target)) {
                const depth = std.mem.count(u8, location.path, "/") + 1;
                try config.commit(io, a, env, &cfg, .{ .add_search_dir = .{ .path = host_dir, .depth = depth } });
            }
            const name = std.fs.path.basename(target);
            try sessions.open(io, a, .{ .key = name, .name = name, .source = .{ .repository = .{ .path = target, .provider = .git } } }, client, &cfg);
        },
        .init_repo => |name| {
            const root = (try app.searchPath()) orelse return;
            const target = if (std.fs.path.isAbsolute(name)) name else try std.fs.path.join(a, &.{ root, name });
            try repos.initRepo(io, a, target, env);
            try client.switchTo(io, a, try app.newRepoSession(name, target));
        },
        .bookmark => |args| {
            const p = args.path orelse try app.cwd();
            try config.commit(io, a, env, &cfg, if (args.delete) .{ .delete_bookmark = p } else .{ .add_bookmark = p });
        },
        .marks => |marks| switch (marks) {
            .list => for (try config.validMarks(io, a, env, &cfg)) |mark| {
                const session = try sessions.fromPath(io, a, env, mark.path);
                try print(io, try std.fmt.allocPrint(a, "{d}: {s} ({s})\n", .{ mark.index, session.name, try sessions.path(io, a, session) }));
            },
            .set => |args| try config.commit(io, a, env, &cfg, .{ .set_mark = .{ .index = args.index, .path = args.path orelse try app.cwd() } }),
            .open => |index| {
                const key = try std.fmt.allocPrint(a, "{d}", .{index});
                const p = (if (cfg.marks) |map| map.get(key) else null) orelse {
                    failure = .{ .mark_not_found = index };
                    return error.MarkNotFound;
                };
                try sessions.open(io, a, try sessions.fromPath(io, a, env, p), client, &cfg);
            },
            .delete => |index| try config.commit(io, a, env, &cfg, .{ .delete_mark = index }),
            .clear => try config.commit(io, a, env, &cfg, .clear_marks),
        },
        .config => |args| switch (args) {
            .edit => |edit| {
                try config.commit(io, a, env, &cfg, .{ .settings = edit });
                try print(io, "Configuration has been stored\n");
            },
            .list => |list| {
                try print(io, try config.exportToml(a, &cfg, list.defaults));
                try print(io, "\n");
            },
        },
        .open_session => |key| {
            const catalog = try sessions.discover(io, a, env, &cfg);
            const index = catalog.by_key.get(key) orelse {
                failure = .{ .session_not_found = key };
                return error.SessionNotFound;
            };
            try sessions.open(io, a, catalog.entries[index], client, &cfg);
        },
        .help => unreachable,
    }
}

test "switch and kill sort timestamp text rather than numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try unattached(arena.allocator(), &.{
        .{ .name = "ten", .attached = false, .last_attached = "10" },
        .{ .name = "nine", .attached = false, .last_attached = "9" },
        .{ .name = "current", .attached = true, .last_attached = "99" },
    }, .last_attached);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("nine", entries[0].name);
}

test "clone inference trims trailing slash and repeated git suffix" {
    try std.testing.expectEqualStrings("project", try inferredName("host/team/project.git.git/"));
    try std.testing.expectError(error.InvalidRepositoryName, inferredName("project"));
}

test "session listing retains asterisk, trailing spaces, and empty server marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("* \n", try sessionListing(a, .{ .current = null, .sessions = &.{} }));
    try std.testing.expectEqualStrings("current* fallback  \n", try sessionListing(a, .{
        .current = .{ .name = "current", .path = "/current" },
        .sessions = &.{
            .{ .name = "current", .attached = true, .last_attached = "1" },
            .{ .name = "fallback", .attached = false, .last_attached = "0" },
        },
    }));
    try std.testing.expectEqualStrings("quo'te,ui*  \n", try sessionListing(a, .{
        .current = .{ .name = "quo'te,ui", .path = "/current" },
        .sessions = &.{.{ .name = "quo'te,ui", .attached = true, .last_attached = "1" }},
    }));
}

fn expectCall(index: usize, args: []const []const u8) !void {
    const actual = process.calls.items[index].request.argv;
    try std.testing.expectEqualStrings("tmux", actual[0]);
    try std.testing.expectEqualStrings("-L", actual[1]);
    try std.testing.expectEqualStrings("stagehand-app-fixture", actual[2]);
    try std.testing.expectEqual(args.len + 3, actual.len);
    for (args, actual[3..]) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn fixtureApp(a: A, cfg: *config.Config, env: *const Env) App {
    return .{ .io = std.testing.io, .a = a, .scratch = std.testing.allocator, .env = env, .cfg = cfg, .client = .{ .socket = "stagehand-app-fixture", .inside_tmux = true } };
}

test "fixture startup creates windows, sends command, kills initial window, replaces attach" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{ .sessions = &.{.{ .name = "startup", .windows = &.{.{ .name = "editor", .command = "vim" }} }} };
    process.reset(a, &.{});
    try std.testing.expectError(error.Replaced, fixtureApp(a, &cfg, &env).start());
    try expectCall(0, &.{ "new-session", "-d", "-s", "startup" });
    try expectCall(1, &.{ "new-window", "-n", "editor" });
    try expectCall(2, &.{ "send-keys", "vim", "Enter" });
    try expectCall(3, &.{ "kill-window", "-t", ":1" });
    try expectCall(4, &.{"attach-session"});
}

test "fixture absent startup sessions invokes tmux without a command" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{};
    process.reset(a, &.{});
    try fixtureApp(a, &cfg, &env).start();
    try expectCall(0, &.{});
}

test "fixture kill chooses configured available fallback before killing current" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{ .default_session = "ten", .session_sort_order = .last_attached };
    process.reset(a, &.{
        .{ .stdout = "'current,1,100'\n'nine,0,9'\n'ten,0,10'\n" },
        .{ .stdout = "'current'\n" },
        .{ .stdout = "'/work/current'\n" },
    });
    try fixtureApp(a, &cfg, &env).kill();
    try expectCall(3, &.{ "switch-client", "-t", "ten" });
    try expectCall(4, &.{ "kill-session", "-t", "current" });
}

test "fixture kill missing default uses lexical timestamp fallback" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{ .default_session = "absent", .session_sort_order = .last_attached };
    process.reset(a, &.{
        .{ .stdout = "'current,1,100'\n'nine,0,9'\n'ten,0,10'\n" },
        .{ .stdout = "'current'\n" },
        .{ .stdout = "'/work/current'\n" },
    });
    try fixtureApp(a, &cfg, &env).kill();
    try expectCall(3, &.{ "switch-client", "-t", "nine" });
}

test "fixture rename ignores failed move, replaces every path occurrence, sends cd before rename" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{};
    process.reset(a, &.{
        .{ .stdout = "'old,1,10'\n" },
        .{ .stdout = "'old'\n" },
        .{ .stdout = "'/work/old/old'\n" },
        .{ .stdout = "'1.0,sleep,/work/old/old'\n'2.0,vim,/work/old/old/sub'\n" },
    });
    try std.testing.expectError(error.Replaced, fixtureApp(a, &cfg, &env).rename("new"));
    try std.testing.expectEqual(.move, process.calls.items[4].kind);
    const moved = process.calls.items[4].request.argv;
    try std.testing.expectEqual(@as(usize, 2), moved.len);
    try std.testing.expectEqualStrings("/work/old/old", moved[0]);
    try std.testing.expectEqualStrings("/work/new/new", moved[1]);
    try expectCall(5, &.{ "send-keys", "-t", "1.0", "cd /work/new/new", "Enter" });
    try expectCall(6, &.{ "send-keys", "-t", "2.0", "cd /work/new/new/sub", "Enter" });
    try expectCall(7, &.{ "rename-session", "new" });
    try expectCall(8, &.{ "attach-session", "-c", "/work/new/new" });
    try std.testing.expectEqual(@as(usize, 9), process.calls.items.len);
}
