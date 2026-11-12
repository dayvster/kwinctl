//! Window ids. KWin identifies windows by UUID, e.g. "{04add7fb-72b8-4e58-8ac1-5e22730b907b}".
//!
//! Ids end up inside JavaScript source, so they are always validated here first.
const std = @import("std");

/// Room for a normalized id, braces included.
pub const Buffer = [38]u8;

/// Accepts an id with or without braces, in any case, and returns it as "{lowercase-uuid}".
/// Anything that isn't a UUID is rejected, which is what makes ids safe to put into scripts.
pub fn normalize(id: []const u8, out: *Buffer) ?[]const u8 {
    const uuid = stripBraces(id);
    if (uuid.len != 36) return null;
    for (uuid, out[1..37], 0..) |ch, *dst, i| {
        if (isDashPosition(i)) {
            if (ch != '-') return null;
        } else if (!std.ascii.isHex(ch)) {
            return null;
        }
        dst.* = std.ascii.toLower(ch);
    }
    out[0] = '{';
    out[37] = '}';
    return out;
}

/// "{x}" -> "x"; anything else unchanged.
fn stripBraces(id: []const u8) []const u8 {
    if (id.len >= 2 and id[0] == '{' and id[id.len - 1] == '}') return id[1 .. id.len - 1];
    return id;
}

/// Where the dashes go in an 8-4-4-4-12 UUID.
fn isDashPosition(i: usize) bool {
    return i == 8 or i == 13 or i == 18 or i == 23;
}

test "ids are normalized and everything else is rejected" {
    var buf: Buffer = undefined;
    const expected = "{04add7fb-72b8-4e58-8ac1-5e22730b907b}";
    try std.testing.expectEqualStrings(expected, normalize("{04ADD7FB-72b8-4e58-8ac1-5e22730b907b}", &buf).?);
    try std.testing.expectEqualStrings(expected, normalize("04add7fb-72b8-4e58-8ac1-5e22730b907b", &buf).?);
    try std.testing.expect(normalize("0x123", &buf) == null);
    try std.testing.expect(normalize("{}", &buf) == null);
    try std.testing.expect(normalize("{04add7fb-72b8-4e58-8ac1-5e22730b907z}", &buf) == null);
    try std.testing.expect(normalize("04add7fb+72b8-4e58-8ac1-5e22730b907b", &buf) == null);
    try std.testing.expect(normalize("04add7fb-72b8-4e58-8ac1-5e22730b907b\"); evil(\"", &buf) == null);
}
