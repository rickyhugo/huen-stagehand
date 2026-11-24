const std = @import("std");
const builtin = @import("builtin");
const process = @import("process");
const A = std.mem.Allocator;
const Io = std.Io;
pub const Output = process.Output;

pub const SessionInfo = struct {
    name: []const u8,
    attached: bool,
    last_attached: []const u8,
};
pub const Current = struct { name: []const u8, path: []const u8 };
pub const Snapshot = struct { sessions: []const SessionInfo, current: ?Current };
pub const Window = struct { id: []const u8, name: []const u8, active: bool, attached: bool };
pub const Pane = struct { index: []const u8, command: []const u8, cwd: []const u8 };

fn clean(a: A, text: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, std.mem.trim(u8, text, " \r\n"), "'", "");
}

fn snapshotText(a: A, text: []const u8, literal: bool) ![]const u8 {
    if (!literal) return clean(a, text);
    const trimmed = std.mem.trim(u8, text, " \r\n");
    return if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;
}

/// Returns the binary of the server that `$TMUX` names when it serves `socket`. Running that binary
/// skips PATH wrappers such as version-manager shims, which cost hundreds of milliseconds per call,
/// and always matches the server's protocol version.
pub fn serverExecutable(io: Io, a: A, tmux_env: ?[]const u8, socket: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, tmux_env orelse return null, ',');
    if (!std.mem.eql(u8, std.fs.path.basename(fields.first()), socket)) return null;
    const pid = std.fmt.parseInt(std.c.pid_t, fields.next() orelse return null, 10) catch return null;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = switch (builtin.os.tag) {
        .macos => blk: {
            const n = proc_pidpath(pid, &buffer, buffer.len);
            break :blk if (n > 0) buffer[0..@intCast(n)] else return null;
        },
        .linux => blk: {
            var link: [32]u8 = undefined;
            const proc = std.fmt.bufPrint(&link, "/proc/{d}/exe", .{pid}) catch return null;
            break :blk buffer[0 .. Io.Dir.cwd().readLink(io, proc, &buffer) catch return null];
        },
        else => return null,
    };
    // An upgraded server keeps running from a binary that no longer exists on disk.
    Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return null;
    return a.dupe(u8, path) catch null;
}

extern "c" fn proc_pidpath(pid: std.c.pid_t, buffer: [*]u8, size: u32) c_int;

pub const Client = struct {
    socket: []const u8,
    inside_tmux: bool,
    executable: []const u8 = "tmux",

    fn argv(self: *const Client, a: A, args: []const []const u8) ![]const []const u8 {
        return std.mem.concat(a, []const u8, &.{ &.{ self.executable, "-L", self.socket }, args });
    }

    fn execute(self: *const Client, io: Io, a: A, args: []const []const u8) !Output {
        return process.capture(io, a, .{ .argv = try self.argv(a, args) });
    }

    pub fn snapshot(self: *const Client, io: Io, a: A) anyerror!Snapshot {
        return self.readSnapshot(io, a, false);
    }

    pub fn listingSnapshot(self: *const Client, io: Io, a: A) anyerror!Snapshot {
        // Other commands keep Rust's historical apostrophe stripping via snapshot().
        return self.readSnapshot(io, a, true);
    }

    /// The sessions part of `snapshot`, for callers that never read the current session.
    pub fn listSessions(self: *const Client, io: Io, a: A) anyerror![]const SessionInfo {
        return self.readSessions(io, a, false);
    }

    fn readSessions(self: *const Client, io: Io, a: A, literal: bool) anyerror![]const SessionInfo {
        const output = try self.execute(io, a, &.{ "list-sessions", "-F", "'#{session_name},#{session_attached},#{session_last_attached}'" });
        var list: std.ArrayList(SessionInfo) = .empty;
        var lines = std.mem.tokenizeScalar(u8, output.stdout, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitBackwardsScalar(u8, try snapshotText(a, line, literal), ',');
            const timestamp = fields.next() orelse continue;
            const attached = fields.next() orelse continue;
            const name = fields.rest();
            try list.append(a, .{ .name = name, .attached = !std.mem.eql(u8, attached, "0"), .last_attached = timestamp });
        }
        return list.toOwnedSlice(a);
    }

    fn readSnapshot(self: *const Client, io: Io, a: A, literal: bool) anyerror!Snapshot {
        const list = try self.readSessions(io, a, literal);
        const name = try snapshotText(a, (try self.execute(io, a, &.{ "display-message", "-p", "'#S'" })).stdout, literal);
        const cwd = try snapshotText(a, (try self.execute(io, a, &.{ "display-message", "-p", "'#{session_path}'" })).stdout, literal);
        return .{ .sessions = list, .current = if (name.len == 0) null else .{ .name = name, .path = cwd } };
    }

    pub fn windows(self: *const Client, io: Io, a: A, session: ?[]const u8) anyerror![]const Window {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "list-windows", "-F", "'#{window_id},#{window_name},#{window_active},#{window_attached}'" });
        if (session) |s| try args.appendSlice(a, &.{ "-t", s });
        const output = try self.execute(io, a, args.items);
        var result: std.ArrayList(Window) = .empty;
        var lines = std.mem.tokenizeScalar(u8, output.stdout, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitBackwardsScalar(u8, try clean(a, line), ',');
            const attached = fields.next() orelse continue;
            const active = fields.next() orelse continue;
            const prefix = fields.rest();
            const separator = std.mem.indexOfScalar(u8, prefix, ',') orelse continue;
            const id = prefix[0..separator];
            const name = prefix[separator + 1 ..];
            try result.append(a, .{ .id = id, .name = name, .active = std.mem.eql(u8, active, "1"), .attached = std.mem.eql(u8, attached, "1") });
        }
        return result.toOwnedSlice(a);
    }

    pub fn panes(self: *const Client, io: Io, a: A) anyerror![]const Pane {
        const output = try self.execute(io, a, &.{ "list-windows", "-F", "'#{window_index}.#{pane_index},#{pane_current_command},#{pane_current_path}'" });
        var result: std.ArrayList(Pane) = .empty;
        var lines = std.mem.tokenizeScalar(u8, output.stdout, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, try clean(a, line), ',');
            const index = fields.next() orelse continue;
            const command = fields.next() orelse continue;
            const cwd = fields.next() orelse continue;
            try result.append(a, .{ .index = index, .command = command, .cwd = cwd });
        }
        return result.toOwnedSlice(a);
    }

    pub fn capture(self: *const Client, io: Io, a: A, target: []const u8) anyerror![]const u8 {
        const output = try self.execute(io, a, &.{ "capture-pane", "-ep", "-t", target });
        return if (output.term.success()) output.stdout else "";
    }

    pub fn attachedSession(self: *const Client, io: Io, a: A) anyerror![]const u8 {
        return (try self.execute(io, a, &.{ "list-sessions", "-F", "#{session_name}", "-f", "#{session_attached}" })).stdout;
    }

    pub fn newSession(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8) anyerror!Output {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "new-session", "-d" });
        if (name) |n| try args.appendSlice(a, &.{ "-s", n });
        if (path) |p| try args.appendSlice(a, &.{ "-c", p });
        return self.execute(io, a, args.items);
    }

    pub fn newWindow(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8, session: ?[]const u8) anyerror!Output {
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, "new-window");
        if (name) |n| try args.appendSlice(a, &.{ "-n", n });
        if (path) |p| try args.appendSlice(a, &.{ "-c", p });
        if (session) |s| try args.appendSlice(a, &.{ "-t", s });
        return self.execute(io, a, args.items);
    }

    pub fn killSession(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output {
        return self.execute(io, a, &.{ "kill-session", "-t", name });
    }
    pub fn killWindow(self: *const Client, io: Io, a: A, target: []const u8) anyerror!Output {
        return self.execute(io, a, &.{ "kill-window", "-t", target });
    }
    pub fn selectWindow(self: *const Client, io: Io, a: A, target: []const u8) anyerror!Output {
        return self.execute(io, a, &.{ "select-window", "-t", target });
    }
    pub fn renameSession(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output {
        return self.execute(io, a, &.{ "rename-session", name });
    }
    pub fn sendKeys(self: *const Client, io: Io, a: A, text: []const u8, target: ?[]const u8) anyerror!Output {
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, "send-keys");
        if (target) |t| try args.appendSlice(a, &.{ "-t", t });
        try args.appendSlice(a, &.{ text, "Enter" });
        return self.execute(io, a, args.items);
    }
    pub fn switchClient(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output {
        const output = try self.execute(io, a, &.{ "switch-client", "-t", name });
        return if (output.term.success()) output else self.execute(io, a, &.{ "attach-session", "-t", name });
    }
    pub fn switchTo(self: *const Client, io: Io, a: A, name: []const u8) anyerror!void {
        if (!self.inside_tmux) try self.attach(io, a, name, null);
        if (!(try self.switchClient(io, a, name)).term.success()) try self.attach(io, a, name, null);
    }
    pub fn attach(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8) anyerror!noreturn {
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, "attach-session");
        if (name) |n| try args.appendSlice(a, &.{ "-t", n });
        if (path) |p| try args.appendSlice(a, &.{ "-c", p });
        return process.replace(io, .{ .argv = try self.argv(a, args.items) });
    }
    pub fn refreshClient(self: *const Client, io: Io, a: A) anyerror!Output {
        return self.execute(io, a, &.{ "refresh-client", "-S" });
    }
    pub fn start(self: *const Client, io: Io, a: A) anyerror!Output {
        return self.execute(io, a, &.{});
    }
};

test "socket selector always precedes command" {
    const a = std.testing.allocator;
    const client: Client = .{ .socket = "stagehand-test-only", .inside_tmux = true };
    const args = try client.argv(a, &.{ "new-session", "-d" });
    defer a.free(args);
    try std.testing.expectEqualSlices([]const u8, &.{ "tmux", "-L", "stagehand-test-only", "new-session", "-d" }, args);
}

test "server executable comes from the TMUX pid only for the same socket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const own = try std.fmt.allocPrint(a, "/tmp/tmux-1/fixture,{d},0", .{std.c.getpid()});
    const path = serverExecutable(io, a, own, "fixture") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expectEqual(null, serverExecutable(io, a, own, "default"));
    try std.testing.expectEqual(null, serverExecutable(io, a, "/tmp/tmux-1/fixture,not-a-pid,0", "fixture"));
    try std.testing.expectEqual(null, serverExecutable(io, a, null, "fixture"));
}
