//! Bus addresses, such as "unix:path=/run/user/1000/bus" or
//! "unix:abstract=/tmp/dbus-x,guid=...".
//!
//! An address may list several alternatives separated by ';'. Only Unix sockets
//! (path= and abstract=) are supported; TCP and the other transports are not.
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const sys = @import("../sys.zig");

/// A Unix socket a bus can be reached at.
pub const Socket = struct {
    path: []u8,
    /// The path is a name in Linux's abstract socket namespace, not a file.
    abstract: bool,

    pub fn deinit(s: *Socket, a: Allocator) void {
        a.free(s.path);
        s.* = undefined;
    }
};

/// Connects to the first alternative in `address` that works and returns the socket's file
/// descriptor. If none works, returns the error from the last one tried.
pub fn connect(a: Allocator, address: []const u8) !i32 {
    var last_error: anyerror = error.AddressUnsupported;
    var alternatives = mem.splitScalar(u8, address, ';');
    while (alternatives.next()) |entry| {
        var socket = parse(a, entry) catch |err| {
            last_error = err;
            continue;
        };
        defer socket.deinit(a);
        return sys.connectUnix(socket.path, socket.abstract) catch |err| {
            last_error = err;
            continue;
        };
    }
    return last_error;
}

/// Parses one alternative, e.g. "unix:path=/run/user/1000/bus". The caller owns the result
/// (deinit it). error.AddressUnsupported for other transports or malformed values.
pub fn parse(a: Allocator, entry: []const u8) !Socket {
    const prefix = "unix:";
    if (!mem.startsWith(u8, entry, prefix)) return error.AddressUnsupported;
    var pairs = mem.splitScalar(u8, entry[prefix.len..], ',');
    while (pairs.next()) |pair| {
        const eq = mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const abstract = mem.eql(u8, key, "abstract");
        if (abstract or mem.eql(u8, key, "path")) {
            return .{ .path = try unescape(a, pair[eq + 1 ..]), .abstract = abstract };
        }
    }
    return error.AddressUnsupported;
}

/// Decodes %xx escapes, which addresses use for bytes that aren't allowed literally.
fn unescape(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const byte = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.AddressUnsupported;
            try out.append(a, byte);
            i += 2;
        } else {
            try out.append(a, s[i]);
        }
    }
    return out.toOwnedSlice(a);
}

const testing = std.testing;

test "path, abstract and escaped addresses parse" {
    const a = testing.allocator;
    var plain = try parse(a, "unix:path=/run/user/1000/bus");
    defer plain.deinit(a);
    try testing.expectEqualStrings("/run/user/1000/bus", plain.path);
    try testing.expect(!plain.abstract);

    var abstract = try parse(a, "unix:abstract=/tmp/dbus-UDCY,guid=20c8");
    defer abstract.deinit(a);
    try testing.expectEqualStrings("/tmp/dbus-UDCY", abstract.path);
    try testing.expect(abstract.abstract);

    var escaped = try parse(a, "unix:path=/run/user/1000/my%20bus");
    defer escaped.deinit(a);
    try testing.expectEqualStrings("/run/user/1000/my bus", escaped.path);
}

test "unsupported addresses are rejected" {
    try testing.expectError(error.AddressUnsupported, parse(testing.allocator, "tcp:host=localhost,port=1"));
    try testing.expectError(error.AddressUnsupported, parse(testing.allocator, "unix:tmpdir=/tmp"));
    try testing.expectError(error.AddressUnsupported, parse(testing.allocator, "unix:path=/x%zz"));
}
