const std = @import("std");
const A = std.mem.Allocator;

const Frame = struct {
    kind: enum { array, header },
    needs_comma: bool = false,
};

/// Returns null when tomlc17's `native` message should be reported unchanged.
pub fn format(a: A, text: []const u8, native: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, native, "(line ")) return null;
    const end = std.mem.indexOf(u8, native, ") ") orelse return null;
    const line = std.fmt.parseInt(usize, native[6..end], 10) catch return null;
    const reason = native[end + 2 ..];
    const eof_error = std.mem.eql(u8, reason, "missing value") or
        std.mem.eql(u8, reason, "syntax error while parsing array: missing comma") or
        std.mem.startsWith(u8, reason, "unterminated");
    if (!eof_error or line != std.mem.count(u8, text, "\n") + 1) return null;

    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(a);
    var expect_value = false;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (std.ascii.isWhitespace(ch)) {
            if (ch == '\n' and stack.items.len == 0) expect_value = false;
            i += 1;
            continue;
        }
        if (ch == '#') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            if (!value(&stack)) return null;
            const multiline = i + 2 < text.len and text[i + 1] == ch and text[i + 2] == ch;
            i += if (multiline) @as(usize, 3) else 1;
            while (i < text.len) {
                if (ch == '"' and text[i] == '\\') {
                    i = @min(i + 2, text.len);
                } else if (text[i] == ch and (!multiline or
                    (i + 2 < text.len and text[i + 1] == ch and text[i + 2] == ch)))
                {
                    i += if (multiline) @as(usize, 3) else 1;
                    // TOML permits one or two quote characters before a triple terminator.
                    if (multiline) {
                        var extra: usize = 0;
                        while (i < text.len and text[i] == ch and extra < 2) : (extra += 1) i += 1;
                    }
                    break;
                } else i += 1;
            }
            expect_value = false;
            continue;
        }
        switch (ch) {
            '=' => {
                if (stack.last()) |frame| if (frame.kind == .array) return null;
                expect_value = true;
            },
            '{', '}' => return null,
            '[' => {
                const array = expect_value or if (stack.last()) |frame| frame.kind == .array else false;
                if (!value(&stack)) return null;
                try stack.append(a, .{ .kind = if (array) .array else .header });
                expect_value = false;
            },
            ']' => {
                _ = stack.pop() orelse return null;
                expect_value = false;
            },
            ',' => {
                const frame = stack.lastPtr() orelse return null;
                if (frame.kind == .array) {
                    if (!frame.needs_comma) return null;
                    frame.needs_comma = false;
                }
                expect_value = false;
            },
            else => {
                if (!value(&stack)) return null;
                const start = i;
                while (i < text.len and std.mem.indexOfScalar(u8, " \t\r\n,[]{}=#\"'", text[i]) == null) : (i += 1) {}
                if (i == start) return null;
                // The sole whitespace inside an unquoted TOML value separates date and time.
                if (i - start == 10 and i < text.len and text[i] == ' ' and
                    i + 1 < text.len and std.ascii.isDigit(text[i + 1]) and
                    text[start + 4] == '-' and text[start + 7] == '-')
                {
                    i += 1;
                    while (i < text.len and std.mem.indexOfScalar(u8, " \t\r\n,[]{}=#\"'", text[i]) == null) : (i += 1) {}
                }
                expect_value = false;
                continue;
            },
        }
        i += 1;
    }
    const open = stack.last() orelse return null;
    if (open.kind != .array) return null;

    // toml 0.9 anchors EOF to the last byte, then adds one column, even after LF.
    const start = if (std.mem.lastIndexOfScalar(u8, text[0 .. text.len - 1], '\n')) |n| n + 1 else 0;
    const eof_line = std.mem.count(u8, text[0..start], "\n") + 1;
    const column = try std.unicode.utf8CountCodepoints(text[start..]);
    const digits = std.fmt.count("{d}", .{eof_line});
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("TOML parse error at line {d}, column {d}\n", .{ eof_line, column + 1 });
    try w.splatByteAll(' ', digits + 5);
    try w.print("|\n    {d} | {s}\n", .{ eof_line, std.mem.trimEnd(u8, text[start..], "\r\n") });
    try w.splatByteAll(' ', digits + 5);
    try w.writeByte('|');
    try w.splatByteAll(' ', column + 1);
    try w.writeAll("^\n    unclosed array, expected `]`\n    ");
    return try out.toOwnedSlice();
}

fn value(stack: *std.ArrayList(Frame)) bool {
    const frame = stack.lastPtr() orelse return true;
    if (frame.kind != .array) return true;
    if (frame.needs_comma) return false;
    frame.needs_comma = true;
    return true;
}
