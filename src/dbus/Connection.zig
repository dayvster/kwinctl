//! A connection to a D-Bus message bus.
//!
//! Besides calling methods, it can receive method calls addressed to its own unique bus
//! name, which is how KWin scripts send their results back. Calls that arrive while a reply
//! is being awaited are queued and handed out later by `waitCall`.
const Connection = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const sys = @import("../sys.zig");
const Deadline = sys.Deadline;
const address = @import("address.zig");
const wire = @import("wire.zig");
const Message = wire.Message;
const Value = wire.Value;

a: Allocator,
fd: i32,
/// Our name on the bus, e.g. ":1.42". Method calls sent to this name arrive here.
unique_name: []u8 = &.{},
serial: u32 = 0,
/// Bytes read from the socket that don't form a complete message yet.
inbox: std.ArrayList(u8) = .empty,
/// Calls to us that arrived while we were waiting for a reply.
pending_calls: std.ArrayList(Message) = .empty,
/// The last error reply, as "org.freedesktop.DBus.Error.X: text".
last_error: std.ArrayList(u8) = .empty,

/// The target of a method call.
pub const Method = struct {
    /// The bus name of the service, e.g. "org.kde.KWin".
    destination: []const u8,
    /// The object, e.g. "/Scripting".
    path: []const u8,
    interface: []const u8,
    /// The method name.
    member: []const u8,
};

const bus_hello: Method = .{
    .destination = "org.freedesktop.DBus",
    .path = "/org/freedesktop/DBus",
    .interface = "org.freedesktop.DBus",
    .member = "Hello",
};

/// Connects to the bus at `bus_address` (as in $DBUS_SESSION_BUS_ADDRESS), authenticates
/// and registers, which assigns `unique_name`. Close with `close`.
pub fn open(a: Allocator, bus_address: []const u8, timeout_ms: u32) !Connection {
    var c: Connection = .{ .a = a, .fd = try address.connect(a, bus_address) };
    errdefer c.close();
    try c.authenticate(Deadline.in(timeout_ms));
    c.unique_name = try c.hello(timeout_ms);
    return c;
}

/// Closes the socket and frees everything, including queued calls.
pub fn close(c: *Connection) void {
    sys.close(c.fd);
    for (c.pending_calls.items) |*m| m.deinit(c.a);
    c.pending_calls.deinit(c.a);
    c.inbox.deinit(c.a);
    c.last_error.deinit(c.a);
    c.a.free(c.unique_name);
    c.* = undefined;
}

/// Calls a method and waits for the reply, which the caller must deinit. An error reply
/// returns error.CallFailed and leaves its text in `last_error`.
pub fn call(c: *Connection, method: Method, args: []const Value, timeout_ms: u32) !Message {
    const serial = try c.send(.method_call, 0, .{
        .destination = method.destination,
        .path = method.path,
        .interface = method.interface,
        .member = method.member,
    }, args);
    return c.awaitReply(serial, Deadline.in(timeout_ms));
}

/// Like `call`, for methods whose reply carries nothing of interest.
pub fn callVoid(c: *Connection, method: Method, args: []const Value, timeout_ms: u32) !void {
    var reply = try c.call(method, args, timeout_ms);
    reply.deinit(c.a);
}

/// Returns the next method call addressed to us (queued ones first); the caller must
/// deinit it. Signals and unrelated replies are dropped. error.Timeout after `deadline`.
pub fn waitCall(c: *Connection, deadline: Deadline) !Message {
    if (c.pending_calls.items.len > 0) return c.pending_calls.orderedRemove(0);
    while (true) {
        var m = try c.receive(deadline);
        if (m.typ == .method_call) return m;
        m.deinit(c.a);
    }
}

/// Answers a call to us with an empty reply, unless the caller asked for none.
pub fn replyEmpty(c: *Connection, to: *const Message) !void {
    if (!to.expectsReply()) return;
    _ = try c.send(.method_return, wire.Flags.no_reply_expected, .{
        .reply_serial = to.serial,
        .destination = if (to.sender.len > 0) to.sender else null,
    }, &.{});
}

// ---------- handshake ----------

/// SASL EXTERNAL authentication: the bus identifies us by the uid on the socket, so we
/// only have to state it.
fn authenticate(c: *Connection, deadline: Deadline) !void {
    var buf: [64]u8 = undefined;
    try sys.writeAll(c.fd, authCommand(&buf, sys.uid()));
    if (!try c.readAuthOk(deadline)) return error.AuthFailed;
    try sys.writeAll(c.fd, "BEGIN\r\n");
}

/// The opening line: a nul byte, then "AUTH EXTERNAL" with the uid's decimal digits
/// hex-encoded, e.g. uid 1000 becomes "31303030".
fn authCommand(buf: *[64]u8, uid: u32) []const u8 {
    var digits: [10]u8 = undefined;
    const uid_text = std.fmt.bufPrint(&digits, "{d}", .{uid}) catch unreachable;
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("\x00AUTH EXTERNAL ") catch unreachable;
    for (uid_text) |ch| w.print("{x:0>2}", .{ch}) catch unreachable;
    w.writeAll("\r\n") catch unreachable;
    return w.buffered();
}

/// Reads the server's one-line answer: "OK <guid>" on success.
fn readAuthOk(c: *Connection, deadline: Deadline) !bool {
    while (mem.indexOf(u8, c.inbox.items, "\r\n") == null) try c.fill(deadline);
    const line_end = mem.indexOf(u8, c.inbox.items, "\r\n").? + 2;
    const ok = mem.startsWith(u8, c.inbox.items, "OK ");
    c.inbox.replaceRangeAssumeCapacity(0, line_end, &.{});
    return ok;
}

/// Registers with the bus, which must be the first call; returns our unique name.
fn hello(c: *Connection, timeout_ms: u32) ![]u8 {
    var reply = try c.call(bus_hello, &.{}, timeout_ms);
    defer reply.deinit(c.a);
    const name = reply.single(.string) orelse return error.ProtocolError;
    return c.a.dupe(u8, name);
}

// ---------- sending and receiving ----------

/// Encodes and writes one message; returns its serial.
fn send(c: *Connection, typ: wire.MessageType, flags: u8, header: wire.Header, args: []const Value) !u32 {
    const serial = c.nextSerial();
    const bytes = try wire.encode(c.a, typ, flags, serial, header, args);
    defer c.a.free(bytes);
    try sys.writeAll(c.fd, bytes);
    return serial;
}

/// Serials are never 0.
fn nextSerial(c: *Connection) u32 {
    c.serial +%= 1;
    if (c.serial == 0) c.serial = 1;
    return c.serial;
}

/// Waits for the reply to `serial`. Method calls to us that arrive meanwhile are queued
/// for waitCall; anything else is dropped.
fn awaitReply(c: *Connection, serial: u32, deadline: Deadline) !Message {
    while (true) {
        var m = try c.receive(deadline);
        const is_reply = m.reply_serial == serial and (m.typ == .method_return or m.typ == .error_reply);
        if (is_reply and m.typ == .method_return) return m;
        if (is_reply) {
            defer m.deinit(c.a);
            c.rememberError(&m);
            return error.CallFailed;
        }
        if (m.typ == .method_call) {
            c.pending_calls.append(c.a, m) catch |err| {
                m.deinit(c.a);
                return err;
            };
        } else {
            m.deinit(c.a);
        }
    }
}

fn rememberError(c: *Connection, m: *const Message) void {
    c.last_error.clearRetainingCapacity();
    const text = m.firstString();
    if (text.len > 0) {
        c.last_error.print(c.a, "{s}: {s}", .{ m.error_name, text }) catch {};
    } else {
        c.last_error.appendSlice(c.a, m.error_name) catch {};
    }
}

/// Returns the next complete message, reading from the socket as needed.
fn receive(c: *Connection, deadline: Deadline) !Message {
    while (true) {
        if (try c.takeMessage()) |m| return m;
        try c.fill(deadline);
    }
}

/// Cuts one complete message off the front of the inbox, if there is one.
fn takeMessage(c: *Connection) !?Message {
    const len = try wire.messageLength(c.inbox.items) orelse return null;
    const raw = try c.a.dupe(u8, c.inbox.items[0..len]);
    c.inbox.replaceRangeAssumeCapacity(0, len, &.{});
    return wire.decode(raw) catch |err| {
        c.a.free(raw);
        return err;
    };
}

/// Appends whatever the socket has to the inbox, waiting for data until `deadline`.
fn fill(c: *Connection, deadline: Deadline) !void {
    if (!try sys.waitReadable(c.fd, deadline)) return error.Timeout;
    var buf: [16 * 1024]u8 = undefined;
    const n = try sys.read(c.fd, &buf);
    if (n == 0) return error.ConnectionClosed;
    try c.inbox.appendSlice(c.a, buf[0..n]);
}

test "the auth command hex-encodes the uid's decimal digits" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x00AUTH EXTERNAL 31303030\r\n", authCommand(&buf, 1000));
    try std.testing.expectEqualStrings("\x00AUTH EXTERNAL 30\r\n", authCommand(&buf, 0));
}
