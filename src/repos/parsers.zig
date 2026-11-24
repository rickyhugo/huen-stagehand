const std = @import("std");
const A = std.mem.Allocator;
const Worktree = @import("../repos.zig").Worktree;

/// Read the common local file, as `git config --file` does without includes.
/// Unusual syntax goes back to Git rather than guessing during discovery.
pub fn configBare(bytes: []const u8) error{UnsupportedGitConfig}!?bool {
    var result: ?bool = null;
    var core = false;
    var section_seen = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        var quoted = false;
        var end = raw.len;
        var position: usize = 0;
        while (position < raw.len) : (position += 1) {
            switch (raw[position]) {
                0 => return error.UnsupportedGitConfig,
                '\\' => {
                    position += 1;
                    if (position == raw.len or std.mem.indexOfScalar(u8, "\\\"ntb", raw[position]) == null)
                        return error.UnsupportedGitConfig;
                },
                '"' => quoted = !quoted,
                '#', ';' => if (!quoted) {
                    end = position;
                    break;
                },
                else => {},
            }
        }
        if (quoted) return error.UnsupportedGitConfig;
        const text = std.mem.trim(u8, raw[0..end], " \t\r");
        if (text.len == 0) continue;
        if (text[0] == '[') {
            if (text[text.len - 1] != ']') return error.UnsupportedGitConfig;
            const section = std.mem.trim(u8, text[1 .. text.len - 1], " \t");
            const split = std.mem.indexOfAny(u8, section, " \t") orelse section.len;
            if (split == 0) return error.UnsupportedGitConfig;
            for (section[0..split]) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return error.UnsupportedGitConfig;
            }
            const subsection = std.mem.trim(u8, section[split..], " \t");
            if (subsection.len > 0 and (subsection.len < 2 or subsection[0] != '"' or subsection[subsection.len - 1] != '"' or
                std.mem.indexOfScalar(u8, subsection[1 .. subsection.len - 1], '"') != null))
                return error.UnsupportedGitConfig;
            core = std.ascii.eqlIgnoreCase(section, "core");
            section_seen = true;
            continue;
        }
        if (!section_seen) return error.UnsupportedGitConfig;
        const equal = std.mem.indexOfScalar(u8, text, '=');
        const key = std.mem.trim(u8, text[0 .. equal orelse text.len], " \t");
        if (key.len == 0 or !std.ascii.isAlphabetic(key[0])) return error.UnsupportedGitConfig;
        for (key) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-') return error.UnsupportedGitConfig;
        }
        if (!core or !std.ascii.eqlIgnoreCase(key, "bare")) continue;
        const i = equal orelse {
            result = true;
            continue;
        };
        var value = std.mem.trim(u8, text[i + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "false") or
            std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "off"))
        {
            result = false;
        } else if (std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "on")) {
            result = true;
        } else {
            const digits = if (value[0] == '+' or value[0] == '-') value[1..] else value;
            if (digits.len > 1 and digits[0] == '0') return error.UnsupportedGitConfig;
            for (digits) |c| {
                if (!std.ascii.isDigit(c)) return error.UnsupportedGitConfig;
            }
            result = (std.fmt.parseInt(i32, value, 10) catch return error.UnsupportedGitConfig) != 0;
        }
    }
    return result;
}

test "bare config handles Git booleans comments duplicate keys and unrelated quoted commands" {
    try std.testing.expectEqual(@as(?bool, false), try configBare(
        "[core]\r\nbare = true\r\n[Core]\r\nBaRe = \"OFF\" # last value wins\r\n" ++
            "[hook \"pre-commit\"]\ncommand = \"echo \\\"#not a comment\\\"; printf '\\\\n'\"\n",
    ));
    for ([_][]const u8{ "true", "YES", "\"on\"", "1", "-2" }) |value| {
        var buffer: [128]u8 = undefined;
        try std.testing.expectEqual(@as(?bool, true), try configBare(try std.fmt.bufPrint(&buffer, "[core]\nbare = {s}\n", .{value})));
    }
    for ([_][]const u8{ "false", "No", "\"off\"", "0", "", "\"\"" }) |value| {
        var buffer: [128]u8 = undefined;
        try std.testing.expectEqual(@as(?bool, false), try configBare(try std.fmt.bufPrint(&buffer, "[core]\nbare = {s}\n", .{value})));
    }
    try std.testing.expectEqual(@as(?bool, true), try configBare("[core]\nbare ; implicit true\n"));
    try std.testing.expectEqual(@as(?bool, null), try configBare("[core \"other\"]\nbare=true\n[core.other]\nbare=true\n"));
    try std.testing.expectEqual(@as(?bool, false), try configBare("[core]\nbare=false\n[include]\npath=other-config\n"));
}

test "bare config delegates complex values and malformed syntax to Git" {
    for ([_][]const u8{
        "[core]\nbare=tr\\\nue\n",
        "[core]\nbare=t\"ru\"e\n",
        "[core]\nbare=1k\n",
        "[core]\nbare=1_0\n",
        "[core]\nbare=08\n",
        "[core]\nbare=unknown\n",
        "[core]\nbare=true\n[hook \"test\"]\ncommand=\"unclosed\n",
        "[core]\nbare=true\n[hook \"test\"]\ncommand=bad\\escape\n",
        "bare=true\n",
        "[core\nbare=true\n",
        "[core]\nbare=true\ninvalid key=value\n",
        "[core]\nbare=true\x00\n",
    }) |text| {
        try std.testing.expectError(error.UnsupportedGitConfig, configBare(text));
    }
}

pub fn gitdir(a: A, base: []const u8, bytes: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, bytes, "gitdir: ")) return error.InvalidGitdir;
    const path = std.mem.trimEnd(u8, bytes["gitdir: ".len..], std.ascii.whitespace[0..]);
    if (path.len == 0) return error.InvalidGitdir;
    return std.fs.path.resolve(a, &.{ base, path });
}

pub fn worktreePath(a: A, pointer: []const u8, bytes: []const u8) ![]const u8 {
    const path = std.mem.trimEnd(u8, bytes, std.ascii.whitespace[0..]);
    if (path.len == 0) return error.InvalidGitdir;
    const absolute = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(pointer).?, path });
    return if (std.mem.eql(u8, std.fs.path.basename(absolute), ".git")) std.fs.path.dirname(absolute).? else absolute;
}

pub const Module = struct { name: []const u8, path: []const u8 };

pub fn submoduleEntries(a: A, bytes: []const u8) ![]const Module {
    var modules: std.ArrayList(Module) = .empty;
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const newline = std.mem.indexOfScalar(u8, record, '\n') orelse return error.InvalidSubmodules;
        const key = record[0..newline];
        if (key.len < "submodule..path".len or
            !std.mem.startsWith(u8, key, "submodule.") or !std.mem.endsWith(u8, key, ".path"))
            return error.InvalidSubmodules;
        const module: Module = .{
            .name = key["submodule.".len .. key.len - ".path".len],
            .path = record[newline + 1 ..],
        };
        var duplicate = false;
        for (modules.items) |*existing| {
            if (std.mem.eql(u8, existing.name, module.name)) {
                existing.path = module.path;
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try modules.append(a, module);
    }
    var count: usize = 0;
    valid: for (modules.items) |module| {
        if (module.name.len == 0 or module.path.len == 0 or std.fs.path.isAbsolute(module.path)) continue;
        var names = std.mem.tokenizeAny(u8, module.name, "/\\");
        while (names.next()) |component| {
            if (std.mem.eql(u8, component, "..")) continue :valid;
        }
        var paths = std.mem.tokenizeScalar(u8, module.path, '/');
        var depth: usize = 0;
        while (paths.next()) |component| {
            if (std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) {
                if (depth == 0) continue :valid;
                depth -= 1;
            } else {
                depth += 1;
            }
        }
        modules.items[count] = module;
        count += 1;
    }
    modules.shrinkRetainingCapacity(count);
    return modules.toOwnedSlice(a);
}

pub fn workspaceStore(a: A, bytes: []const u8) ![]const Worktree {
    var result: std.ArrayList(Worktree) = .empty;
    var reader: Proto = .{ .bytes = bytes };
    while (try reader.next()) |field| {
        if (field.number != 1) continue;
        const record = field.bytes orelse return error.InvalidWorkspaceStore;
        var workspace: Proto = .{ .bytes = record };
        var name: []const u8 = "";
        var path: []const u8 = "";
        while (try workspace.next()) |value| switch (value.number) {
            1 => {
                name = value.bytes orelse return error.InvalidWorkspaceStore;
                if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidWorkspaceStore;
            },
            2 => path = value.bytes orelse return error.InvalidWorkspaceStore,
            else => {},
        };
        if (!std.unicode.utf8ValidateSlice(path)) continue;
        try result.append(a, .{ .name = name, .path = path, .prunable = false });
    }
    return result.toOwnedSlice(a);
}

pub fn checkoutName(bytes: []const u8) ![]const u8 {
    var reader: Proto = .{ .bytes = bytes };
    var name: []const u8 = "";
    while (try reader.next()) |field| {
        if (field.number == 3) {
            name = field.bytes orelse return error.InvalidWorkspaceStore;
            if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidWorkspaceStore;
        }
    }
    return if (name.len == 0) "default" else name;
}

const Proto = struct {
    bytes: []const u8,
    position: usize = 0,
    const Field = struct { number: u32, bytes: ?[]const u8 };

    fn varint(self: *Proto) !u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        for (0..10) |index| {
            if (self.position == self.bytes.len) return error.InvalidWorkspaceStore;
            const byte = self.bytes[self.position];
            self.position += 1;
            if (index == 9 and byte > 1) return error.InvalidWorkspaceStore;
            value |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) return value;
            if (index != 9) shift += 7;
        }
        return error.InvalidWorkspaceStore;
    }

    fn take(self: *Proto, length: u64) ![]const u8 {
        if (length > self.bytes.len - self.position) return error.InvalidWorkspaceStore;
        const end = self.position + @as(usize, @intCast(length));
        defer self.position = end;
        return self.bytes[self.position..end];
    }

    fn next(self: *Proto) !?Field {
        if (self.position == self.bytes.len) return null;
        const tag = try self.varint();
        const number = tag >> 3;
        if (number == 0 or number > 0x1fffffff) return error.InvalidWorkspaceStore;
        var field: Field = .{ .number = @intCast(number), .bytes = null };
        switch (tag & 7) {
            0 => _ = try self.varint(),
            1 => _ = try self.take(8),
            2 => field.bytes = try self.take(try self.varint()),
            5 => _ = try self.take(4),
            else => return error.InvalidWorkspaceStore,
        }
        return field;
    }
};

test "git metadata pointers and administrative paths retain spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/repo/.bare", try gitdir(a, "/repo", "gitdir: .bare\n"));
    try std.testing.expectEqualStrings("/space dir/meta", try gitdir(a, "/repo", "gitdir: /space dir/meta\r\n"));
    try std.testing.expectEqualStrings("/repo/topic", try worktreePath(a, "/repo/worktrees/id/gitdir", "../../topic/.git\n"));
    try std.testing.expectEqualStrings("/repo/worktrees/id/ leading", try worktreePath(a, "/repo/worktrees/id/gitdir", " leading/.git \t\n"));
    try std.testing.expectError(error.InvalidGitdir, gitdir(a, "/repo", "gitdir:\n"));
    try std.testing.expectError(error.InvalidGitdir, worktreePath(a, "/repo/gitdir", "\n"));
}

test "submodule config is nul delimited and names come from paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = try submoduleEntries(arena.allocator(), "submodule.custom-name.path\nvendor/child\x00submodule.other.path\nline\nbreak\x00");
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("custom-name", paths[0].name);
    try std.testing.expectEqualStrings("vendor/child", paths[0].path);
    try std.testing.expectEqualStrings("line\nbreak", paths[1].path);
    try std.testing.expectError(error.InvalidSubmodules, submoduleEntries(arena.allocator(), "submodule.path\nbad\x00"));
}

test "submodule config keeps the last path and rejects invalid names and escaped roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try submoduleEntries(arena.allocator(), "submodule.same.path\nold\x00" ++
        "submodule.invalid/../name.path\nsafe\x00" ++
        "submodule.absolute.path\n/elsewhere\x00" ++
        "submodule.outside.path\n../elsewhere\x00" ++
        "submodule.same.path\nnested/../final\x00");
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("nested/../final", entries[0].path);
}

test "workspace protobuf retains current and stale records and skips unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const records = try workspaceStore(arena.allocator(), "\x0a\x0d\x0a\x07default\x12\x02/a\x0a\x0b\x0a\x05stale\x12\x02/b\x18\x01");
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("default", records[0].name);
    try std.testing.expectEqualStrings("/b", records[1].path);
    try std.testing.expect(!records[1].prunable);
}

test "workspace protobuf rejects truncation overflow and invalid UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "\x0a\x02\x0a", "\x00", "\x80", "\x0a\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02", "\x08\x01" }) |invalid| {
        try std.testing.expectError(error.InvalidWorkspaceStore, workspaceStore(arena.allocator(), invalid));
    }
    try std.testing.expectEqual(@as(usize, 0), (try workspaceStore(arena.allocator(), "\x0a\x03\x12\x01\xff")).len);
    try std.testing.expectError(error.InvalidWorkspaceStore, workspaceStore(arena.allocator(), "\x0a\x03\x0a\x01\xff"));
}

test "checkout name preserves raw workspace names and old default fallback" {
    try std.testing.expectEqualStrings("with space", try checkoutName("\x12\x02op\x1a\x0awith space"));
    try std.testing.expectEqualStrings("default", try checkoutName(""));
    try std.testing.expectError(error.InvalidWorkspaceStore, checkoutName("\x1a\x01\xff"));
}

/// Where a remote lives: `host` is lowercase without user or port, `path` has no `.git` suffix,
/// and `url` is what `git clone` receives.
pub const Remote = struct { host: []const u8, path: []const u8, url: []const u8 };

/// Accepts scheme URLs, scp-like `user@host:path`, and bare `host/path`, which clones over HTTPS.
pub fn remote(a: A, text: []const u8) !Remote {
    var url = text;
    var authority: []const u8 = undefined;
    var path: []const u8 = undefined;
    if (std.mem.indexOf(u8, text, "://")) |separator| {
        const schemes = [_][]const u8{ "https", "http", "ssh", "git", "git+ssh", "ssh+git" };
        const scheme = text[0..separator];
        for (schemes) |known| {
            if (std.ascii.eqlIgnoreCase(scheme, known)) break;
        } else return error.UnsupportedRemote;
        const rest = text[separator + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.UnsupportedRemote;
        authority = rest[0..slash];
        path = rest[slash + 1 ..];
    } else if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, text[0..colon], '/') != null) return error.UnsupportedRemote;
        authority = text[0..colon];
        path = text[colon + 1 ..];
    } else {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return error.UnsupportedRemote;
        authority = text[0..slash];
        path = text[slash + 1 ..];
        if (std.mem.indexOfScalar(u8, authority, '.') == null) return error.UnsupportedRemote;
        url = try std.fmt.allocPrint(a, "https://{s}", .{text});
    }
    var host = authority[if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else 0..];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    if (host.len == 0 or host[0] == '[' or std.mem.eql(u8, host, ".") or std.mem.eql(u8, host, "..")) return error.UnsupportedRemote;
    path = std.mem.trim(u8, path, "/");
    while (std.mem.endsWith(u8, path, ".git")) path = std.mem.trimEnd(u8, path[0 .. path.len - 4], "/");
    if (path.len == 0) return error.UnsupportedRemote;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..") or segment[0] == '~')
            return error.UnsupportedRemote;
    }
    return .{ .host = try std.ascii.allocLowerString(a, host), .path = path, .url = url };
}

test "remotes map to host and path across URL forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { text: []const u8, host: []const u8, path: []const u8, url: []const u8 }{
        .{ .text = "https://github.com/rickyhugo/huen-wm", .host = "github.com", .path = "rickyhugo/huen-wm", .url = "https://github.com/rickyhugo/huen-wm" },
        .{ .text = "https://GitHub.com/rickyhugo/huen-wm.git/", .host = "github.com", .path = "rickyhugo/huen-wm", .url = "https://GitHub.com/rickyhugo/huen-wm.git/" },
        .{ .text = "git@github.com:rickyhugo/huen-wm.git", .host = "github.com", .path = "rickyhugo/huen-wm", .url = "git@github.com:rickyhugo/huen-wm.git" },
        .{ .text = "ssh://git@gitlab.example.com:2222/group/sub/repo.git", .host = "gitlab.example.com", .path = "group/sub/repo", .url = "ssh://git@gitlab.example.com:2222/group/sub/repo.git" },
        .{ .text = "https://user:token@codeberg.org/owner/repo", .host = "codeberg.org", .path = "owner/repo", .url = "https://user:token@codeberg.org/owner/repo" },
        .{ .text = "codeberg.org/owner/repo", .host = "codeberg.org", .path = "owner/repo", .url = "https://codeberg.org/owner/repo" },
    };
    for (cases) |case| {
        const parsed = try remote(a, case.text);
        try std.testing.expectEqualStrings(case.host, parsed.host);
        try std.testing.expectEqualStrings(case.path, parsed.path);
        try std.testing.expectEqualStrings(case.url, parsed.url);
    }
}

test "remotes without a host and path or with escaping segments are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "file:///tmp/repo",      "/tmp/repo",                    "../repo",                   "repo",
        "https://github.com/",   "https://github.com/a/../../x", "git@github.com:~/repo.git", "https://[::1]/a/b",
        "local/repo",            "https://github.com/a//b",      "https://github.com/.git",   "https://user@/owner/repo",
        "ftp://example.com/a/b",
    }) |text| {
        try std.testing.expectError(error.UnsupportedRemote, remote(arena.allocator(), text));
    }
}
