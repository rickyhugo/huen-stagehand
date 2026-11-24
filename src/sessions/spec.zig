const std = @import("std");
const sessions = @import("sessions");
const config = @import("config");
const tmux = @import("tmux");
const fake = @import("process");
const client: tmux.Client = .{ .socket = "stagehand-session-fixture", .inside_tmux = true };

test "listing ordinary and linked checkouts does not spawn Git with worktrees enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.createDirPath(io, "main/.git/objects");
    try directory.dir.createDirPath(io, "main/.git/refs");
    try directory.dir.createDirPath(io, "main/.git/worktrees/topic");
    try directory.dir.createDirPath(io, "topic");
    try directory.dir.writeFile(io, .{ .sub_path = "main/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try directory.dir.writeFile(io, .{ .sub_path = "main/.git/config", .data = "[core]\nrepositoryformatversion = 0\nbare = false\n[remote \"origin\"]\nurl = https://example.com/repo.git\n[hook \"pre-commit\"]\ncommand = \"test \\\"${HK:-1}\\\" = 0 || mise x -- hk run pre-commit\"\n" });
    try directory.dir.writeFile(io, .{ .sub_path = "topic/.git", .data = "gitdir: ../main/.git/worktrees/topic\n" });
    try directory.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/topic/HEAD", .data = "ref: refs/heads/topic\n" });
    try directory.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/topic/commondir", .data = "../..\n" });
    const root = try directory.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    const cfg: config.Config = .{
        .search_dirs = &.{.{ .path = root, .depth = 1 }},
        .list_worktrees = true,
    };
    fake.reset(a, &.{});
    const result = sessions.discover(io, a, &env, &cfg);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    const catalog = try result;
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
    try std.testing.expectEqualStrings("main", catalog.entries[0].key);
    try std.testing.expectEqualStrings("topic", catalog.entries[1].key);
}

fn expectArgs(index: usize, args: []const []const u8) !void {
    const request = fake.calls.items[index].request;
    try std.testing.expectEqual(args.len + 3, request.argv.len);
    try std.testing.expectEqualStrings("-L", request.argv[1]);
    try std.testing.expectEqualStrings("stagehand-session-fixture", request.argv[2]);
    for (args, request.argv[3..]) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "opening bookmark normalizes periods, keeps hyphens, sends nonexecutable script only on creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = ".stagehand-create", .data = "echo ignored" });
    const path = try directory.dir.realPathFileAlloc(std.testing.io, ".", a);
    const entry: sessions.Session = .{ .key = "/visible/key", .name = "project.one-two", .source = .{ .bookmark = path } };
    const cfg: config.Config = .{};
    fake.reset(a, &.{});
    try sessions.open(std.testing.io, a, entry, &client, &cfg);
    try std.testing.expectEqual(@as(usize, 4), fake.calls.items.len);
    try expectArgs(1, &.{ "new-session", "-d", "-s", "project_one-two", "-c", path });
    try expectArgs(2, &.{ "send-keys", "-t", "project_one-two:{start}.{top}", try std.fs.path.join(a, &.{ path, ".stagehand-create" }), "Enter" });
    try expectArgs(3, &.{ "switch-client", "-t", "project_one-two" });

    fake.reset(a, &.{.{ .stdout = "'project_one-two,0,9'\n" }});
    try sessions.open(std.testing.io, a, entry, &client, &cfg);
    try std.testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try expectArgs(1, &.{ "switch-client", "-t", "project_one-two" });
}

test "configured creation script is keyed by normalized session name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "custom-script", .data = "" });
    const path = try directory.dir.realPathFileAlloc(std.testing.io, ".", a);
    const script = try std.fs.path.join(a, &.{ path, "custom-script" });
    var configs: std.StringHashMapUnmanaged(config.SessionConfig) = .empty;
    try configs.put(a, "project_one", .{ .create_script = script });
    const cfg: config.Config = .{ .session_configs = configs };
    const entry: sessions.Session = .{ .key = "project.one", .name = "project.one", .source = .{ .bookmark = path } };
    fake.reset(a, &.{});
    try sessions.open(std.testing.io, a, entry, &client, &cfg);
    try expectArgs(2, &.{ "send-keys", "-t", "project_one:{start}.{top}", script, "Enter" });
}

test "opening an existing comma session does not recreate it or rerun its script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = ".stagehand-create", .data = "echo should-not-run" });
    const path = try directory.dir.realPathFileAlloc(std.testing.io, ".", a);
    const entry: sessions.Session = .{ .key = "a,b", .name = "a,b", .source = .{ .bookmark = path } };
    const cfg: config.Config = .{};
    fake.reset(a, &.{.{ .stdout = "'a,b,0,'\n" }});
    try sessions.open(std.testing.io, a, entry, &client, &cfg);
    try std.testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try expectArgs(1, &.{ "switch-client", "-t", "a,b" });
}
