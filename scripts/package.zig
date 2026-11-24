//! Build and inspect release archives, and install source notices.
//! Run from the repository root through mise:
//!
//!   zig run scripts/package.zig -- build --target TRIPLE [--output DIR] [--smoke]
//!   zig run scripts/package.zig -- verify ARCHIVE --target TRIPLE [--smoke]
//!   zig run scripts/package.zig -- notices --dest DIR

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const zig_version = "0.17.1";

/// Required distribution notices, including names that prefix discovery misses.
/// Keep the independent policy list in the tests below in sync.
const required_source_notices = [_][]const u8{
    "LICENSE",
    "src/cli/registration/LICENSE",
    "src/config/UNICODE-LICENSE",
    "src/picker/LICENSE-unicode-width",
    "src/repos/template/LICENSE",
    "vendor/licenses/matcher/NOTICE.md",
    "vendor/licenses/matcher/Unicode-3.0.txt",
    "vendor/licenses/matcher/nucleo-MPL-2.0.txt",
    "vendor/licenses/matcher/unicode-Apache-2.0.txt",
    "vendor/licenses/matcher/unicode-COPYRIGHT.txt",
    "vendor/licenses/matcher/unicode-MIT.txt",
    "vendor/tomlc17/LICENSE",
};

/// Archive path, then the path relative to the Zig installation directory.
const compiler_notices = [_][2][]const u8{
    .{ "notices/zig/LICENSE", "LICENSE" },
    .{ "notices/musl/COPYRIGHT", "lib/libc/musl/COPYRIGHT" },
    .{ "notices/glibc/LICENSES", "lib/libc/glibc/LICENSES" },
};

const notice_prefixes = [_][]const u8{ "LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "THIRD_PARTY" };

pub const Target = struct {
    triple: []const u8,
    zig: []const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
};

pub const targets = [_]Target{
    .{ .triple = "aarch64-apple-darwin", .zig = "aarch64-macos", .os = .macos, .arch = .aarch64 },
    .{ .triple = "x86_64-apple-darwin", .zig = "x86_64-macos", .os = .macos, .arch = .x86_64 },
    .{ .triple = "x86_64-unknown-linux-gnu", .zig = "x86_64-linux-gnu.2.28", .os = .linux, .arch = .x86_64 },
    .{ .triple = "x86_64-unknown-linux-musl", .zig = "x86_64-linux-musl", .os = .linux, .arch = .x86_64 },
};

/// Paths are relative to the current directory unless absolute.
pub const Paths = struct {
    /// Repository root.
    root: []const u8,
    /// Zig installation directory: the one containing `LICENSE` and `lib/`.
    zig_dir: []const u8,
};

pub const Notice = struct {
    /// Path inside the archive or license directory, with `/` separators.
    name: []const u8,
    /// Source file path.
    source: []const u8,
};

/// The offending path or detail for the last returned error.
pub var detail: []const u8 = "";

fn fail(comptime err: anyerror, text: []const u8) anyerror {
    detail = text;
    return err;
}

pub fn findTarget(triple: []const u8) ?Target {
    for (targets) |target| {
        if (std.mem.eql(u8, target.triple, triple)) return target;
    }
    return null;
}

fn isNoticeName(basename: []const u8) bool {
    for (notice_prefixes) |prefix| {
        if (basename.len >= prefix.len and std.ascii.eqlIgnoreCase(basename[0..prefix.len], prefix)) return true;
    }
    return false;
}

fn lessThan(_: void, a: Notice, b: Notice) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Every source and compiler notice to distribute, sorted by name.
pub fn notices(a: Allocator, io: Io, paths: Paths) ![]Notice {
    var found: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    const cwd = Io.Dir.cwd();

    for (required_source_notices) |name| {
        const source = try std.fs.path.join(a, &.{ paths.root, name });
        const stat = cwd.statFile(io, source, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return fail(error.RequiredNoticeMissing, source),
            else => return err,
        };
        if (stat.kind == .sym_link) return fail(error.NoticeIsSymlink, source);
        if (stat.kind != .file) return fail(error.RequiredNoticeMissing, source);
        try found.put(a, name, source);
    }

    // Include additional conventionally named notices without weakening the
    // required list when a source notice is removed or renamed.
    {
        var dir = try cwd.openDir(io, paths.root, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!isNoticeName(entry.name)) continue;
            try addDiscovered(a, &found, paths.root, entry.name, entry.kind);
        }
    }
    for ([_][]const u8{ "vendor", "src" }) |base| {
        var dir = try cwd.openDir(io, try std.fs.path.join(a, &.{ paths.root, base }), .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            const name = try std.fs.path.join(a, &.{ base, entry.path });
            if (!std.mem.startsWith(u8, name, "vendor/licenses/") and !isNoticeName(entry.basename)) continue;
            try addDiscovered(a, &found, paths.root, name, entry.kind);
        }
    }

    for (compiler_notices) |pair| {
        try found.put(a, pair[0], try std.fs.path.join(a, &.{ paths.zig_dir, pair[1] }));
    }

    const result = try a.alloc(Notice, found.count());
    for (found.keys(), found.values(), result) |name, source, *notice| notice.* = .{ .name = name, .source = source };
    std.mem.sort(Notice, result, {}, lessThan);
    return result;
}

fn addDiscovered(
    a: Allocator,
    found: *std.StringArrayHashMapUnmanaged([]const u8),
    root: []const u8,
    name: []const u8,
    kind: Io.File.Kind,
) !void {
    const source = try std.fs.path.join(a, &.{ root, name });
    switch (kind) {
        .file => try found.put(a, try a.dupe(u8, name), source),
        .sym_link => return fail(error.NoticeIsSymlink, source),
        else => {},
    }
}

/// Copy every notice below `dest` with mode 0644.
pub fn installNotices(a: Allocator, io: Io, paths: Paths, dest: []const u8) !void {
    const cwd = Io.Dir.cwd();
    for (try notices(a, io, paths)) |notice| {
        const output = try std.fs.path.join(a, &.{ dest, notice.name });
        try cwd.copyFile(notice.source, cwd, output, io, .{
            .make_path = true,
            .permissions = .fromMode(0o644),
        });
    }
}

pub fn archiveName(target: Target) []const u8 {
    inline for (targets) |known| {
        if (std.mem.eql(u8, known.triple, target.triple)) return "stagehand-" ++ known.triple;
    }
    unreachable;
}

pub fn requireNative(target: Target) !void {
    if (builtin.os.tag != target.os or builtin.cpu.arch != target.arch) {
        return fail(error.ForeignSmoke, target.triple);
    }
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Write `<output>/<archive>.tar.gz` and its `.sha256` from a built executable.
/// Returns the archive path.
pub fn writeArchive(a: Allocator, io: Io, paths: Paths, target: Target, binary: []const u8, output: []const u8) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const name = archiveName(target);
    const files = try notices(a, io, paths);

    var compressed: Io.Writer.Allocating = try .initCapacity(a, 1 << 16);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = try std.compress.flate.Compress.init(&compressed.writer, &window, .gzip, .default);
    var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };

    // Members are sorted by name; `stagehand` sorts among the notices.
    var entries: std.ArrayList(Notice) = .empty;
    try entries.append(a, .{ .name = "stagehand", .source = binary });
    try entries.appendSlice(a, files);
    std.mem.sort(Notice, entries.items, {}, lessThan);
    for (entries.items) |entry| {
        const data = try cwd.readFileAlloc(io, entry.source, a, .unlimited);
        const mode: u32 = if (std.mem.eql(u8, entry.name, "stagehand")) 0o755 else 0o644;
        try tar.writeFileBytes(try std.fmt.allocPrint(a, "{s}/{s}", .{ name, entry.name }), data, .{ .mode = mode, .mtime = 0 });
    }
    try tar.finishPedantically();
    try gzip.finish();

    try cwd.createDirPath(io, output);
    const archive = try std.fmt.allocPrint(a, "{s}/{s}.tar.gz", .{ output, name });
    const bytes = compressed.written();
    try cwd.writeFile(io, .{ .sub_path = archive, .data = bytes });
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}.sha256", .{archive}),
        .data = try std.fmt.allocPrint(a, "{s}  {s}.tar.gz\n", .{ &sha256Hex(bytes), name }),
    });
    return archive;
}

const Member = struct {
    name: []const u8,
    kind: std.tar.FileKind,
    mode: u32,
    data: []const u8,
};

fn readMembers(a: Allocator, archive: []const u8) ![]Member {
    var input: Io.Reader = .fixed(archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gunzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    var file_name: [std.fs.max_path_bytes]u8 = undefined;
    var link_name: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gunzip.reader, .{ .file_name_buffer = &file_name, .link_name_buffer = &link_name });
    var members: std.ArrayList(Member) = .empty;
    while (try it.next()) |file| {
        var data: Io.Writer.Allocating = .init(a);
        if (file.kind == .file) try it.streamRemaining(file, &data.writer);
        try members.append(a, .{ .name = try a.dupe(u8, file.name), .kind = file.kind, .mode = file.mode, .data = data.written() });
    }
    return members.items;
}

fn isExecutableFor(target: Target, executable: []const u8) bool {
    switch (target.os) {
        .linux => return executable.len >= 20 and
            std.mem.eql(u8, executable[0..6], "\x7fELF\x02\x01") and
            std.mem.readInt(u16, executable[16..18], .little) <= 3 and
            std.mem.readInt(u16, executable[16..18], .little) >= 2 and
            std.mem.readInt(u16, executable[18..20], .little) == 62,
        else => {
            const cpu: u32 = if (target.arch == .aarch64) 0x100000C else 0x1000007;
            return executable.len >= 16 and
                std.mem.eql(u8, executable[0..4], "\xcf\xfa\xed\xfe") and
                std.mem.readInt(u32, executable[4..8], .little) == cpu and
                std.mem.readInt(u32, executable[12..16], .little) == 2;
        },
    }
}

/// Check the checksum, exact member set, modes, notice bytes, and executable format.
/// With `smoke`, also run `--help` on a matching native host.
pub fn verify(a: Allocator, io: Io, paths: Paths, archive: []const u8, target: Target, smoke: bool) !void {
    const cwd = Io.Dir.cwd();
    const name = archiveName(target);
    const expected_basename = try std.fmt.allocPrint(a, "{s}.tar.gz", .{name});
    if (!std.mem.eql(u8, std.fs.path.basename(archive), expected_basename)) {
        return fail(error.WrongArchiveName, expected_basename);
    }
    const bytes = try cwd.readFileAlloc(io, archive, a, .unlimited);
    const checksum = try cwd.readFileAlloc(io, try std.fmt.allocPrint(a, "{s}.sha256", .{archive}), a, .limited(4096));
    const expected_checksum = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ &sha256Hex(bytes), expected_basename });
    if (!std.mem.eql(u8, checksum, expected_checksum)) return fail(error.ChecksumMismatch, archive);

    const executable_name = try std.fmt.allocPrint(a, "{s}/stagehand", .{name});
    var expected: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty;
    try expected.put(a, executable_name, null);
    for (try notices(a, io, paths)) |notice| {
        try expected.put(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ name, notice.name }), notice.source);
    }

    const members = try readMembers(a, bytes);
    if (members.len != expected.count()) return fail(error.UnexpectedMembers, "archive must contain only stagehand and the current licenses and notices");
    var executable: []const u8 = "";
    for (members) |member| {
        const source = expected.get(member.name) orelse
            return fail(error.UnexpectedMembers, "archive must contain only stagehand and the current licenses and notices");
        const mode: u32 = if (source == null) 0o755 else 0o644;
        if (member.kind != .file or member.mode != mode or member.data.len == 0) {
            return fail(error.InvalidMember, member.name);
        }
        if (source) |path| {
            const original = try cwd.readFileAlloc(io, path, a, .unlimited);
            if (!std.mem.eql(u8, original, member.data)) return fail(error.NoticeDiffers, member.name);
        } else {
            executable = member.data;
        }
    }
    // Duplicates keep the count but leave a name out.
    for (expected.keys()) |key| {
        for (members) |member| {
            if (std.mem.eql(u8, member.name, key)) break;
        } else return fail(error.UnexpectedMembers, "archive must contain only stagehand and the current licenses and notices");
    }
    if (!isExecutableFor(target, executable)) return fail(error.WrongExecutable, target.triple);

    if (smoke) try smokeTest(a, io, target, executable, std.fs.path.dirname(archive) orelse ".");
}

fn smokeTest(a: Allocator, io: Io, target: Target, executable: []const u8, scratch: []const u8) !void {
    try requireNative(target);
    const cwd = Io.Dir.cwd();
    const dir = try std.fmt.allocPrint(a, "{s}/.smoke-{s}", .{ scratch, target.triple });
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};
    const binary = try std.fmt.allocPrint(a, "{s}/stagehand", .{dir});
    try cwd.writeFile(io, .{ .sub_path = binary, .data = executable, .flags = .{ .permissions = .fromMode(0o755) } });
    const result = try std.process.run(a, io, .{ .argv = &.{ binary, "--help" } });
    if (!result.term.success() or result.stderr.len != 0 or
        std.mem.indexOf(u8, result.stdout, "Usage: stagehand [COMMAND]") == null)
    {
        return fail(error.SmokeFailed, try std.fmt.allocPrint(a, "unexpected --help output:\n{s}{s}", .{ result.stdout, result.stderr }));
    }
}

fn runChecked(a: Allocator, io: Io, cwd: []const u8, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(a, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    if (!result.term.success()) {
        return fail(error.CommandFailed, try std.fmt.allocPrint(a, "{s} failed:\n{s}", .{ argv[0], result.stderr }));
    }
    return result.stdout;
}

/// The Zig installation directory, taken from `zig env`.
fn zigDir(a: Allocator, io: Io) ![]const u8 {
    const env = try runChecked(a, io, ".", &.{ "zig", "env" });
    const key = ".zig_exe = \"";
    const start = (std.mem.indexOf(u8, env, key) orelse return fail(error.ZigEnv, env)) + key.len;
    const end = std.mem.indexOfScalarPos(u8, env, start, '"') orelse return fail(error.ZigEnv, env);
    return std.fs.path.dirname(env[start..end]) orelse return fail(error.ZigEnv, env);
}

fn build(a: Allocator, io: Io, paths: Paths, target: Target, output: []const u8, smoke: bool) !void {
    if (smoke) try requireNative(target);
    const version = std.mem.trim(u8, try runChecked(a, io, paths.root, &.{ "zig", "version" }), " \n");
    if (!std.mem.eql(u8, version, zig_version)) return fail(error.WrongZig, version);

    const cwd = Io.Dir.cwd();
    const prefix = try std.fmt.allocPrint(a, "{s}/.install-{s}", .{ output, target.triple });
    const absolute_prefix = try std.fs.path.resolve(a, &.{ try std.process.currentPathAlloc(io, a), prefix });
    defer cwd.deleteTree(io, prefix) catch {};
    _ = try runChecked(a, io, paths.root, &.{
        "zig",                                                    "build",    "--system",      "--release=fast", "-Dcpu=baseline",
        try std.fmt.allocPrint(a, "-Dtarget={s}", .{target.zig}), "--prefix", absolute_prefix,
    });
    const archive = try writeArchive(a, io, paths, target, try std.fs.path.join(a, &.{ prefix, "bin/stagehand" }), output);
    try verify(a, io, paths, archive, target, smoke);
    printOut(io, "Verified archive contents and checksum: {s}\n", .{archive});
    if (smoke) printOut(io, "Native --help passed. This is not behavioral compatibility verification.\n", .{});
}

fn printOut(io: Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    writer.interface.print(format, args) catch {};
    writer.interface.flush() catch {};
}

const usage =
    \\Usage:
    \\  package build --target TRIPLE [--output DIR] [--smoke]
    \\  package verify ARCHIVE --target TRIPLE [--smoke]
    \\  package notices --dest DIR
    \\Run from the repository root.
    \\
;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(a);

    var command: ?[]const u8 = null;
    var archive: ?[]const u8 = null;
    var target: ?Target = null;
    var output: []const u8 = "target/distrib";
    var dest: ?[]const u8 = null;
    var smoke = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "--dest")) {
            i += 1;
            if (i == argv.len) usageError(io, "missing value");
            const value = argv[i];
            if (std.mem.eql(u8, arg, "--target")) {
                target = findTarget(value) orelse usageError(io, "unknown target");
            } else if (std.mem.eql(u8, arg, "--output")) {
                output = value;
            } else {
                dest = value;
            }
        } else if (command == null) {
            command = arg;
        } else if (archive == null and command != null and std.mem.eql(u8, command.?, "verify")) {
            archive = arg;
        } else usageError(io, "unexpected argument");
    }

    Io.Dir.cwd().access(io, "build.zig.zon", .{}) catch usageError(io, "build.zig.zon not found");
    const paths: Paths = .{ .root = ".", .zig_dir = try zigDir(a, io) };
    const name = command orelse usageError(io, "missing command");
    const result = if (std.mem.eql(u8, name, "build"))
        build(a, io, paths, target orelse usageError(io, "--target is required"), output, smoke)
    else if (std.mem.eql(u8, name, "verify")) blk: {
        const path = archive orelse usageError(io, "missing archive");
        verify(a, io, paths, path, target orelse usageError(io, "--target is required"), smoke) catch |err| break :blk err;
        printOut(io, "Verified archive contents and checksum: {s}\n", .{path});
        if (smoke) printOut(io, "Native --help passed. This is not behavioral compatibility verification.\n", .{});
    } else if (std.mem.eql(u8, name, "notices"))
        installNotices(a, io, paths, dest orelse usageError(io, "--dest is required"))
    else
        usageError(io, "unknown command");
    result catch |err| {
        std.debug.print("error: {s}: {s}\n", .{ @errorName(err), detail });
        std.process.exit(1);
    };
}

fn usageError(io: Io, message: []const u8) noreturn {
    _ = io;
    std.debug.print("error: {s}\n{s}", .{ message, usage });
    std.process.exit(2);
}

// Policy tests. Compilation is not exercised; archive and notice paths are real.

const testing = std.testing;
const test_io = testing.io;

/// Independent policy oracle: never derive this list from `notices`.
const policy_source_notices = [_][]const u8{
    "LICENSE",
    "src/cli/registration/LICENSE",
    "src/config/UNICODE-LICENSE",
    "src/picker/LICENSE-unicode-width",
    "src/repos/template/LICENSE",
    "vendor/licenses/matcher/NOTICE.md",
    "vendor/licenses/matcher/Unicode-3.0.txt",
    "vendor/licenses/matcher/nucleo-MPL-2.0.txt",
    "vendor/licenses/matcher/unicode-Apache-2.0.txt",
    "vendor/licenses/matcher/unicode-COPYRIGHT.txt",
    "vendor/licenses/matcher/unicode-MIT.txt",
    "vendor/tomlc17/LICENSE",
};
const policy_compiler_notices = [_][2][]const u8{
    .{ "notices/zig/LICENSE", "LICENSE" },
    .{ "notices/musl/COPYRIGHT", "lib/libc/musl/COPYRIGHT" },
    .{ "notices/glibc/LICENSES", "lib/libc/glibc/LICENSES" },
};
const macho_arm64 = "\xcf\xfa\xed\xfe\x0c\x00\x00\x01\x00\x00\x00\x00\x02\x00\x00\x00";
const macho_x86_64 = "\xcf\xfa\xed\xfe\x07\x00\x00\x01\x00\x00\x00\x00\x02\x00\x00\x00";

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    paths: Paths,
    target: Target,
    output: []const u8,
    binary: []const u8,

    fn init() !Fixture {
        var self: Fixture = .{
            .tmp = testing.tmpDir(.{}),
            .arena = .init(testing.allocator),
            .paths = undefined,
            .target = findTarget("aarch64-apple-darwin").?,
            .output = undefined,
            .binary = undefined,
        };
        const a = self.arena.allocator();
        const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&self.tmp.sub_path});
        self.paths = .{ .root = try std.fmt.allocPrint(a, "{s}/source", .{base}), .zig_dir = try std.fmt.allocPrint(a, "{s}/zig", .{base}) };
        self.output = try std.fmt.allocPrint(a, "{s}/dist", .{self.paths.root});
        for (policy_source_notices) |name| try self.write(try std.fs.path.join(a, &.{ "source", name }), name);
        for (policy_compiler_notices) |pair| try self.write(try std.fs.path.join(a, &.{ "zig", pair[1] }), pair[0]);
        try self.write("source/build.zig.zon", ".{}\n");
        try self.write("source/zig-out/bin/stagehand", macho_arm64);
        self.binary = try std.fmt.allocPrint(a, "{s}/zig-out/bin/stagehand", .{self.paths.root});
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |dir| try self.tmp.dir.createDirPath(test_io, dir);
        try self.tmp.dir.writeFile(test_io, .{ .sub_path = sub_path, .data = data });
    }

    fn expected(self: *Fixture) !std.StringArrayHashMapUnmanaged([]const u8) {
        const a = self.arena.allocator();
        var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (policy_source_notices) |name| try map.put(a, name, name);
        for (policy_compiler_notices) |pair| try map.put(a, pair[0], pair[0]);
        return map;
    }

    fn archive(self: *Fixture) ![]const u8 {
        return writeArchive(self.arena.allocator(), test_io, self.paths, self.target, self.binary, self.output);
    }

    /// Rewrite the archive with `members` and a matching checksum.
    fn rewrite(self: *Fixture, path: []const u8, members: []const Member) !void {
        const a = self.arena.allocator();
        var compressed: Io.Writer.Allocating = try .initCapacity(a, 1 << 16);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var gzip = try std.compress.flate.Compress.init(&compressed.writer, &window, .gzip, .default);
        var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
        for (members) |member| switch (member.kind) {
            .file => try tar.writeFileBytes(member.name, member.data, .{ .mode = member.mode }),
            .sym_link => try tar.writeLink(member.name, "LICENSE", .{ .mode = member.mode }),
            .directory => try tar.writeDir(member.name, .{ .mode = member.mode }),
        };
        try gzip.finish();
        const bytes = compressed.written();
        try Io.Dir.cwd().writeFile(test_io, .{ .sub_path = path, .data = bytes });
        try Io.Dir.cwd().writeFile(test_io, .{
            .sub_path = try std.fmt.allocPrint(a, "{s}.sha256", .{path}),
            .data = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ &sha256Hex(bytes), std.fs.path.basename(path) }),
        });
    }
};

test "archive contains every required notice byte for byte" {
    var f: Fixture = try .init();
    defer f.deinit();
    const a = f.arena.allocator();
    const path = try f.archive();
    try verify(a, test_io, f.paths, path, f.target, false);
    const members = try readMembers(a, try Io.Dir.cwd().readFileAlloc(test_io, path, a, .unlimited));
    var expected = try f.expected();
    try testing.expectEqual(expected.count() + 1, members.len);
    for (members) |member| {
        const name = member.name["stagehand-aarch64-apple-darwin/".len..];
        if (std.mem.eql(u8, name, "stagehand")) {
            try testing.expectEqual(@as(u32, 0o755), member.mode);
            try testing.expectEqualStrings(macho_arm64, member.data);
        } else {
            try testing.expectEqual(@as(u32, 0o644), member.mode);
            try testing.expectEqualStrings(expected.get(name) orelse return error.UnexpectedMember, member.data);
        }
    }
}

test "source installation contains every required notice byte for byte" {
    var f: Fixture = try .init();
    defer f.deinit();
    const a = f.arena.allocator();
    const dest = try std.fmt.allocPrint(a, "{s}/prefix with spaces/share/licenses/stagehand", .{f.paths.root});
    try installNotices(a, test_io, f.paths, dest);
    var expected = try f.expected();
    for (expected.keys(), expected.values()) |name, data| {
        const path = try std.fs.path.join(a, &.{ dest, name });
        try testing.expectEqualStrings(data, try Io.Dir.cwd().readFileAlloc(test_io, path, a, .unlimited));
        const stat = try Io.Dir.cwd().statFile(test_io, path, .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o644), stat.permissions.toMode() & 0o777);
    }
    var count: usize = 0;
    var dir = try Io.Dir.cwd().openDir(test_io, dest, .{ .iterate = true });
    defer dir.close(test_io);
    var walker = try dir.walk(a);
    while (try walker.next(test_io)) |entry| count += @intFromBool(entry.kind == .file);
    try testing.expectEqual(expected.count(), count);
}

test "discovers additional conventionally named notices" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.write("source/vendor/other/COPYING", "copying");
    try f.write("source/src/picker/README.md", "not a notice");
    const found = try notices(f.arena.allocator(), test_io, f.paths);
    var names: std.ArrayList([]const u8) = .empty;
    for (found) |notice| try names.append(f.arena.allocator(), notice.name);
    try testing.expectEqual(policy_source_notices.len + policy_compiler_notices.len + 1, found.len);
    for (names.items) |name| try testing.expect(!std.mem.eql(u8, name, "src/picker/README.md"));
}

test "verifier rejects archive without config Unicode notice" {
    var f: Fixture = try .init();
    defer f.deinit();
    const a = f.arena.allocator();
    const path = try f.archive();
    var members: std.ArrayList(Member) = .empty;
    for (try readMembers(a, try Io.Dir.cwd().readFileAlloc(test_io, path, a, .unlimited))) |member| {
        if (!std.mem.endsWith(u8, member.name, "/src/config/UNICODE-LICENSE")) try members.append(a, member);
    }
    try f.rewrite(path, members.items);
    try testing.expectError(error.UnexpectedMembers, verify(a, test_io, f.paths, path, f.target, false));
}

test "required notice must exist" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.tmp.dir.deleteFile(test_io, "source/src/config/UNICODE-LICENSE");
    try testing.expectError(error.RequiredNoticeMissing, notices(f.arena.allocator(), test_io, f.paths));
}

test "required notice must not be a symlink" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.tmp.dir.deleteFile(test_io, "source/src/config/UNICODE-LICENSE");
    try f.tmp.dir.symLink(test_io, "../../LICENSE", "source/src/config/UNICODE-LICENSE", .{});
    try testing.expectError(error.NoticeIsSymlink, notices(f.arena.allocator(), test_io, f.paths));
}

test "discovered notice must not be a symlink" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.tmp.dir.symLink(test_io, "../LICENSE", "source/vendor/NOTICE", .{});
    try testing.expectError(error.NoticeIsSymlink, notices(f.arena.allocator(), test_io, f.paths));
}

test "verifier rejects changed checksum" {
    var f: Fixture = try .init();
    defer f.deinit();
    const a = f.arena.allocator();
    const path = try f.archive();
    try Io.Dir.cwd().writeFile(test_io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.sha256", .{path}), .data = "invalid\n" });
    try testing.expectError(error.ChecksumMismatch, verify(a, test_io, f.paths, path, f.target, false));
}

test "verifier rejects invalid members after checksum is updated" {
    var f: Fixture = try .init();
    defer f.deinit();
    const a = f.arena.allocator();
    const path = try f.archive();
    const original = try readMembers(a, try Io.Dir.cwd().readFileAlloc(test_io, path, a, .unlimited));
    var notice_index: usize = undefined;
    var binary_index: usize = undefined;
    for (original, 0..) |member, index| {
        if (std.mem.endsWith(u8, member.name, "/src/config/UNICODE-LICENSE")) notice_index = index;
        if (std.mem.endsWith(u8, member.name, "-apple-darwin/stagehand")) binary_index = index;
    }
    // Control: an unchanged rewrite still verifies.
    try f.rewrite(path, original);
    try verify(a, test_io, f.paths, path, f.target, false);
    const Defect = enum { bytes, missing, duplicate, extra, mode, symlink, empty, cpu };
    for (std.enums.values(Defect)) |defect| {
        var members: std.ArrayList(Member) = .empty;
        try members.appendSlice(a, original);
        const notice = &members.items[notice_index];
        switch (defect) {
            .bytes => notice.data = "changed notice\n",
            .missing => _ = members.orderedRemove(notice_index),
            .duplicate => try members.append(a, notice.*),
            .extra => try members.append(a, .{ .name = "stagehand-aarch64-apple-darwin/unexpected", .kind = .file, .mode = 0o644, .data = "extra" }),
            .mode => notice.mode = 0o755,
            .symlink => notice.* = .{ .name = notice.name, .kind = .sym_link, .mode = 0o644, .data = "" },
            .empty => notice.data = "",
            .cpu => members.items[binary_index].data = macho_x86_64,
        }
        try f.rewrite(path, members.items);
        if (verify(a, test_io, f.paths, path, f.target, false)) |_| {
            std.debug.print("defect accepted: {s}\n", .{@tagName(defect)});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "verifier rejects a misnamed archive" {
    var f: Fixture = try .init();
    defer f.deinit();
    const path = try f.archive();
    try testing.expectError(error.WrongArchiveName, verify(f.arena.allocator(), test_io, f.paths, path, findTarget("x86_64-apple-darwin").?, false));
}

test "foreign smoke is rejected" {
    for (targets) |target| {
        const native = builtin.os.tag == target.os and builtin.cpu.arch == target.arch;
        if (native) continue;
        try testing.expectError(error.ForeignSmoke, requireNative(target));
    }
}

test "executable format matches target" {
    try testing.expect(isExecutableFor(findTarget("aarch64-apple-darwin").?, macho_arm64));
    try testing.expect(!isExecutableFor(findTarget("aarch64-apple-darwin").?, macho_x86_64));
    try testing.expect(isExecutableFor(findTarget("x86_64-apple-darwin").?, macho_x86_64));
    const elf = "\x7fELF\x02\x01" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x03\x00\x3e\x00";
    try testing.expect(isExecutableFor(findTarget("x86_64-unknown-linux-musl").?, elf));
    try testing.expect(!isExecutableFor(findTarget("x86_64-unknown-linux-musl").?, macho_arm64));
}
