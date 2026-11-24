const std = @import("std");
const Io = std.Io;

// Filesystem and process calls mostly wait on the kernel, often behind an endpoint security agent,
// so more workers than cores still shorten discovery.
const max_workers = 16;

/// Sets `results[i]` to `function(args..., items[i])` for every item, spreading calls over worker threads.
pub fn map(io: Io, results: anytype, items: anytype, comptime function: anytype, args: anytype) Io.Cancelable!void {
    std.debug.assert(results.len == items.len);
    const Work = struct {
        next: std.atomic.Value(usize) = .init(0),
        results: @TypeOf(results),
        items: @TypeOf(items),
        args: @TypeOf(args),

        fn run(work: *@This()) void {
            while (true) {
                const i = work.next.fetchAdd(1, .monotonic);
                if (i >= work.items.len) return;
                work.results[i] = @call(.auto, function, work.args ++ .{work.items[i]});
            }
        }
    };
    var work: Work = .{ .results = results, .items = items, .args = args };
    var group: Io.Group = .init;
    for (1..@max(1, @min(items.len, max_workers))) |_| group.concurrent(io, Work.run, .{&work}) catch break;
    work.run();
    try group.await(io);
}

fn square(offset: usize, value: usize) usize {
    return value * value + offset;
}

test "map keeps each result at its item's index" {
    var items: [100]usize = undefined;
    for (&items, 0..) |*item, i| item.* = i;
    var results: [100]usize = undefined;
    try map(std.testing.io, &results, &items, square, .{@as(usize, 1)});
    for (results, 0..) |result, i| try std.testing.expectEqual(i * i + 1, result);
    try map(std.testing.io, results[0..0], items[0..0], square, .{@as(usize, 1)});
}
