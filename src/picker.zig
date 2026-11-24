const std = @import("std");
const config = @import("config");
const tmux = @import("tmux");
const matcher = @import("matcher");
const input = @import("picker/input.zig");
const terminal = @import("picker/terminal.zig");
const render = @import("picker/render.zig");
const preview = @import("picker/preview.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Item = struct {
    id: usize,
    label: []const u8,
    active: bool = false,
    preview: Preview = .none,
};
pub const Preview = union(enum) {
    none,
    pane: struct { client: *const tmux.Client, target: []const u8 },
    directory: []const u8,
};
pub const Size = struct { width: u16, height: u16 };
pub const State = struct {
    query: std.ArrayList(u8) = .empty,
    scalar_cursor: usize = 0,
    ranked: []const usize = &.{},
    selection: ?usize = null,
    scroll: usize = 0,
    size: Size,
};
pub const Event = union(enum) {
    key: config.Key,
    resize: Size,
    matches: []const usize,
};
pub const Transition = enum { unchanged, redraw, rematch, confirm, cancel };

pub fn reduce(a: A, state: *State, event: Event, options: config.PickerOptions) anyerror!Transition {
    switch (event) {
        .resize => |size| {
            state.size = size;
            keepVisible(state);
            return .redraw;
        },
        .matches => |ranked| {
            state.ranked = ranked;
            state.selection = if (ranked.len == 0) null else @min(state.selection orelse 0, ranked.len - 1);
            keepVisible(state);
            return .redraw;
        },
        .key => |key| {
            const action = boundAction(key, options);
            const count = std.unicode.utf8CountCodepoints(state.query.items) catch unreachable;
            const old_cursor = state.scalar_cursor;
            var start = bytePosition(state.query.items, old_cursor);
            var end = start;
            if (action) |mapped| switch (mapped) {
                .noop => return .unchanged,
                .cancel => return .cancel,
                .confirm => return if (state.selection != null) .confirm else .unchanged,
                .move_up, .move_down => {
                    if (state.ranked.len == 0) return .unchanged;
                    const increment = (mapped == .move_up) == (options.input_position == .bottom);
                    const len = state.ranked.len;
                    state.selection = if (state.selection) |selected| (selected + if (increment) 1 else len - 1) % len else 0;
                    keepVisible(state);
                    return .redraw;
                },
                .cursor_left => state.scalar_cursor -|= 1,
                .cursor_right => state.scalar_cursor = @min(count, old_cursor + 1),
                .move_to_line_start => state.scalar_cursor = 0,
                .move_to_line_end => state.scalar_cursor = count,
                .backspace => {
                    state.scalar_cursor -|= 1;
                    start = bytePosition(state.query.items, state.scalar_cursor);
                },
                .delete => end = bytePosition(state.query.items, @min(count, old_cursor + 1)),
                .delete_to_line_start => {
                    start = 0;
                    state.scalar_cursor = 0;
                },
                .delete_to_line_end => end = state.query.items.len,
                .delete_word => {
                    var cursor = old_cursor;
                    var byte = start;
                    while (byte > 0 and asciiWhitespace(state.query.items[byte - 1])) {
                        byte -= 1;
                        cursor -= 1;
                    }
                    while (byte > 0 and !asciiWhitespace(state.query.items[byte - 1])) {
                        byte -= 1;
                        while (byte > 0 and state.query.items[byte] & 0xc0 == 0x80) byte -= 1;
                        cursor -= 1;
                    }
                    state.scalar_cursor = cursor;
                    start = byte;
                },
            } else switch (key.code) {
                .char => |scalar| {
                    if (count >= std.math.maxInt(u16)) return .unchanged;
                    var bytes: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(scalar, &bytes) catch return .unchanged;
                    try state.query.insertSlice(a, start, bytes[0..n]);
                    state.scalar_cursor += 1;
                    return .rematch;
                },
                else => return .unchanged,
            }
            if (end > start) {
                std.mem.copyForwards(u8, state.query.items[start..], state.query.items[end..]);
                state.query.items.len -= end - start;
                return .rematch;
            }
            return if (old_cursor != state.scalar_cursor) .redraw else .unchanged;
        },
    }
}

pub fn choose(io: Io, result: A, scratch: A, items: []const Item, options: config.PickerOptions) anyerror!?usize {
    _ = result;
    var tty = try terminal.Terminal.init();
    defer tty.deinit();
    var state: State = .{ .size = tty.size() };
    defer state.query.deinit(scratch);
    const labels = try scratch.alloc([]const u8, items.len);
    defer scratch.free(labels);
    for (items, labels) |item, *label| label.* = item.label;
    var ranked = try matcher.rank(scratch, "", labels);
    defer scratch.free(ranked);
    _ = try reduce(scratch, &state, .{ .matches = ranked }, options);
    var previews: Previews = .{ .gpa = scratch };
    defer previews.deinit(io);
    var decoder: input.Decoder = .{};
    var frame = std.heap.ArenaAllocator.init(scratch);
    defer frame.deinit();
    var dirty = true;
    while (true) {
        if (try tty.checkSignals()) {
            _ = try reduce(scratch, &state, .{ .resize = tty.size() }, options);
            dirty = true;
        }
        if (try previews.collect(io)) dirty = true;
        if (dirty) {
            _ = frame.reset(.retain_capacity);
            const text = try previews.text(io, items, if (state.selection) |i| state.ranked[i] else null);
            const bytes = try render.draw(frame.allocator(), state, items, options, text);
            tty.write(bytes) catch |err| {
                _ = try tty.checkSignals();
                if (err == error.TerminalInterrupted) continue;
                return err;
            };
            dirty = false;
        }
        const ready = try tty.wait(if (decoder.pending()) 35 else if (previews.pending != null) 5 else 100);
        if (try tty.checkSignals()) {
            _ = try reduce(scratch, &state, .{ .resize = tty.size() }, options);
            dirty = true;
        }
        if (ready) {
            var bytes: [128]u8 = undefined;
            const n = tty.read(&bytes) catch |err| {
                _ = try tty.checkSignals();
                return err;
            };
            if (n == 0) return null;
            decoder.feed(bytes[0..n]);
        }
        var rematch = false;
        while (decoder.next(!ready)) |key| {
            // Selection keys must see matches for the query typed before them.
            if (rematch) if (boundAction(key, options)) |action| switch (action) {
                .confirm, .move_up, .move_down => {
                    rematch = false;
                    try rank(scratch, &state, labels, &ranked, options);
                    dirty = true;
                },
                else => {},
            };
            switch (try reduce(scratch, &state, .{ .key = key }, options)) {
                .cancel => return null,
                .confirm => return items[state.ranked[state.selection.?]].id,
                .redraw => dirty = true,
                .rematch => rematch = true,
                .unchanged => {},
            }
        }
        // A paste or key burst ranks once, not once per key.
        if (rematch) {
            try rank(scratch, &state, labels, &ranked, options);
            dirty = true;
        }
    }
}

fn boundAction(key: config.Key, options: config.PickerOptions) ?config.PickerAction {
    return for (options.bindings) |binding| {
        if (std.meta.eql(key, binding.key)) break binding.action;
    } else null;
}

fn rank(scratch: A, state: *State, labels: []const []const u8, ranked: *[]usize, options: config.PickerOptions) !void {
    const next = try matcher.rank(scratch, state.query.items, labels);
    scratch.free(ranked.*);
    ranked.* = next;
    _ = try reduce(scratch, state, .{ .matches = ranked.* }, options);
}

/// Fetches one preview at a time in the background so navigation never waits on tmux or the filesystem.
const Previews = struct {
    gpa: A,
    /// Each preview keeps its own arena so a refresh frees the text it replaces.
    cache: std.AutoHashMapUnmanaged(usize, struct { arena: std.heap.ArenaAllocator, text: []const u8 }) = .empty,
    /// Owned by the pending fetch until `store` moves it into the cache.
    job: std.heap.ArenaAllocator = undefined,
    pending: ?struct { item: usize, future: Io.Future([]const u8) } = null,
    done: std.atomic.Value(bool) = .init(false),
    /// The item fetched most recently; selecting any other item fetches again so revisits refresh.
    requested: ?usize = null,

    fn deinit(self: *Previews, io: Io) void {
        if (self.pending) |*pending| {
            _ = pending.future.cancel(io);
            self.job.deinit();
        }
        var entries = self.cache.valueIterator();
        while (entries.next()) |entry| entry.arena.deinit();
        self.cache.deinit(self.gpa);
    }

    /// Returns the last preview fetched for the selected item, or "" before its first fetch completes.
    fn text(self: *Previews, io: Io, items: []const Item, selected: ?usize) ![]const u8 {
        const item = selected orelse {
            self.requested = null;
            return "";
        };
        if (items[item].preview == .none) {
            self.requested = null;
            return "";
        }
        const cached = if (self.cache.get(item)) |entry| entry.text else "";
        if (self.pending != null or self.requested == item) return cached;
        self.requested = item;
        self.done.store(false, .monotonic);
        self.job = .init(self.gpa);
        const future = io.concurrent(fetch, .{ io, self.job.allocator(), items[item].preview, &self.done }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                const fetched = fetch(io, self.job.allocator(), items[item].preview, &self.done);
                try self.store(item, fetched);
                return fetched;
            },
        };
        self.pending = .{ .item = item, .future = future };
        return cached;
    }

    /// Stores a finished preview; true means the screen should redraw.
    fn collect(self: *Previews, io: Io) !bool {
        const pending = self.pending orelse return false;
        if (!self.done.load(.acquire)) return false;
        var future = pending.future;
        self.pending = null;
        try self.store(pending.item, future.await(io));
        return true;
    }

    fn store(self: *Previews, item: usize, fetched: []const u8) !void {
        errdefer self.job.deinit();
        const old = try self.cache.fetchPut(self.gpa, item, .{ .arena = self.job, .text = fetched });
        if (old) |entry| {
            var arena = entry.value.arena;
            arena.deinit();
        }
    }

    fn fetch(io: Io, a: A, source: Preview, done: *std.atomic.Value(bool)) []const u8 {
        defer done.store(true, .release);
        return switch (source) {
            .none => "",
            .pane => |pane| pane.client.capture(io, a, pane.target) catch "",
            .directory => |path| preview.directory(io, a, path) catch "",
        };
    }
};

pub fn bytePosition(text: []const u8, scalar: usize) usize {
    var pos: usize = 0;
    var remaining = scalar;
    while (pos < text.len and remaining > 0) : (remaining -= 1) {
        pos += std.unicode.utf8ByteSequenceLength(text[pos]) catch unreachable;
    }
    return pos;
}

fn asciiWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', 0x0c => true,
        else => false,
    };
}

fn keepVisible(state: *State) void {
    const selected = state.selection orelse {
        state.scroll = 0;
        return;
    };
    const rows = @max(1, @as(usize, state.size.height) -| 2);
    state.scroll = @min(state.scroll, selected);
    if (selected - state.scroll >= rows) state.scroll = selected - rows + 1;
}

test {
    _ = @import("picker/tests.zig");
    _ = input;
    _ = render;
    _ = preview;
}
