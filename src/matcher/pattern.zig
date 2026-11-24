// Translated from nucleo-matcher 0.3.1. SPDX-License-Identifier: MPL-2.0
// See vendor/licenses/matcher/ for upstream licenses and provenance.

const std = @import("std");
const unicode = @import("unicode.zig");

pub const Kind = enum { fuzzy, substring, prefix, postfix, exact };
pub const Atom = struct {
    needle: unicode.Text,
    kind: Kind,
    negative: bool,
    ignore_case: bool,
    normalize: bool,
};

pub fn parse(arena: *std.heap.ArenaAllocator, query: []const u8) ![]const Atom {
    const allocator = arena.allocator();
    var atoms: std.ArrayList(Atom) = .empty;
    var start: usize = 0;
    var escaped = false;
    for (0..query.len + 1) |end| {
        if (end < query.len and (query[end] != ' ' or escaped)) {
            escaped = query[end] == '\\';
            continue;
        }
        var bytes = query[start..end];
        start = end + 1;
        const negative = std.mem.startsWith(u8, bytes, "!");
        if (negative or std.mem.startsWith(u8, bytes, "\\!")) bytes = bytes[1..];
        var kind: Kind = .fuzzy;
        if (std.mem.startsWith(u8, bytes, "^")) kind = .prefix;
        if (std.mem.startsWith(u8, bytes, "'")) kind = .substring;
        if (kind != .fuzzy or std.mem.startsWith(u8, bytes, "\\^") or std.mem.startsWith(u8, bytes, "\\'"))
            bytes = bytes[1..];
        const append_dollar = std.mem.endsWith(u8, bytes, "\\$");
        if (append_dollar) {
            bytes = bytes[0 .. bytes.len - 2];
        } else if (std.mem.endsWith(u8, bytes, "$")) {
            kind = if (kind == .fuzzy) .postfix else .exact;
            bytes = bytes[0 .. bytes.len - 1];
        }
        if (negative and kind == .fuzzy) kind = .substring;

        var decoded: std.ArrayList(u21) = .empty;
        const text = try unicode.decode(allocator, bytes, &decoded);
        var needle: std.ArrayList(u21) = .empty;
        var ignore_case = true;
        var normalize = true;
        var backslash = false;
        for (text.chars, 0..) |cp, i| {
            if (text.ascii and cp == '\\' and i + 1 < text.chars.len and text.chars[i + 1] == ' ') continue;
            // The upstream Unicode escape loop retains a backslash before non-space.
            if (!text.ascii and backslash and cp != ' ') try needle.append(allocator, '\\');
            backslash = cp == '\\';
            ignore_case = ignore_case and unicode.lower(cp) == cp;
            normalize = normalize and unicode.normalize(cp) == cp;
            try needle.append(allocator, cp);
        }
        if (append_dollar) try needle.append(allocator, '$');
        if (needle.items.len == 0) continue;
        try atoms.append(allocator, .{
            .needle = .{ .chars = needle.items, .ascii = text.ascii },
            .kind = kind,
            .negative = negative,
            .ignore_case = ignore_case,
            .normalize = normalize,
        });
    }
    return atoms.items;
}
