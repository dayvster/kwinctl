//! The D-Bus wire format: turns messages into bytes and back.
//!
//! Only the basic types (y b i u x t s o g) are supported; containers such as arrays and
//! dictionaries are not, because nothing kwinctl exchanges with the bus or KWin uses them.
//! Outgoing messages are always little-endian; incoming ones may be either byte order.
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// What a message is for.
pub const MessageType = enum(u8) {
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
    _,
};

/// Bits of a message's flags byte.
pub const Flags = struct {
    /// The sender of a method call will not wait for, or read, a reply.
    pub const no_reply_expected: u8 = 0x1;
};

/// Header field codes from the specification.
const Field = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    _,
};

const little_endian_marker = 'l';
const big_endian_marker = 'B';
const protocol_version = 1;

/// Every message starts with 16 fixed bytes: byte order, type, flags, version, body length,
/// serial, and the byte length of the header field array that follows.
const fixed_header_len = 16;
const body_length_offset = 4;
const serial_offset = 8;
const fields_length_offset = 12;

/// Header fields and the body each start on an 8-byte boundary.
const struct_alignment = 8;

/// Larger messages are rejected as corrupt (the specification's own limit).
const max_message_len = 128 * 1024 * 1024;

/// A basic D-Bus value, as sent in a message body.
pub const Value = union(enum) {
    byte: u8,
    boolean: bool,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    string: []const u8,
    object_path: []const u8,
    signature: []const u8,

    /// Which of the types above a value has.
    pub const Kind = std.meta.Tag(Value);

    /// The character that stands for this value's type in a signature, e.g. 's' for a string.
    pub fn typeCode(v: Value) u8 {
        return codeOf(std.meta.activeTag(v));
    }

    /// The signature character for `kind`.
    pub fn codeOf(kind: Kind) u8 {
        return switch (kind) {
            .byte => 'y',
            .boolean => 'b',
            .int32 => 'i',
            .uint32 => 'u',
            .int64 => 'x',
            .uint64 => 't',
            .string => 's',
            .object_path => 'o',
            .signature => 'g',
        };
    }
};

/// Header fields of an outgoing message. Fields left null are not sent.
pub const Header = struct {
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    /// For replies: the serial of the call being answered.
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
};

// ---------- encoding ----------

/// Appends values following D-Bus alignment rules. Alignment is measured from the start of
/// `buf`, so a buffer must begin on an 8-byte boundary of the final message, which holds for
/// the header and for the body.
const Encoder = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,

    fn deinit(e: *Encoder) void {
        e.buf.deinit(e.a);
    }

    /// Appends zero bytes until the length is a multiple of `alignment`.
    fn pad(e: *Encoder, alignment: usize) !void {
        const len = mem.alignForward(usize, e.buf.items.len, alignment);
        try e.buf.appendNTimes(e.a, 0, len - e.buf.items.len);
    }

    fn byte(e: *Encoder, v: u8) !void {
        try e.buf.append(e.a, v);
    }

    /// Integers are aligned to their own size.
    fn int(e: *Encoder, comptime T: type, v: T) !void {
        try e.pad(@sizeOf(T));
        var bytes: [@sizeOf(T)]u8 = undefined;
        mem.writeInt(T, &bytes, v, .little);
        try e.buf.appendSlice(e.a, &bytes);
    }

    /// Strings and object paths: u32 length, the bytes, a terminating nul.
    fn string(e: *Encoder, s: []const u8) !void {
        try e.int(u32, @intCast(s.len));
        try e.buf.appendSlice(e.a, s);
        try e.byte(0);
    }

    /// Signatures: u8 length, the bytes, a terminating nul.
    fn signature(e: *Encoder, s: []const u8) !void {
        try e.byte(@intCast(s.len));
        try e.buf.appendSlice(e.a, s);
        try e.byte(0);
    }

    fn value(e: *Encoder, v: Value) !void {
        switch (v) {
            .byte => |x| try e.byte(x),
            .boolean => |x| try e.int(u32, @intFromBool(x)),
            .int32 => |x| try e.int(i32, x),
            .uint32 => |x| try e.int(u32, x),
            .int64 => |x| try e.int(i64, x),
            .uint64 => |x| try e.int(u64, x),
            .string, .object_path => |x| try e.string(x),
            .signature => |x| try e.signature(x),
        }
    }

    /// A header field: a (code, variant) struct, where the variant carries its own signature.
    fn field(e: *Encoder, code: Field, v: Value) !void {
        try e.pad(struct_alignment);
        try e.byte(@backingInt(code));
        try e.signature(&.{v.typeCode()});
        try e.value(v);
    }
};

/// Builds a complete message: fixed header, header fields, then `body` with a matching
/// signature field. The caller owns the returned bytes.
pub fn encode(a: Allocator, typ: MessageType, flags: u8, serial: u32, header: Header, body: []const Value) ![]u8 {
    var body_enc: Encoder = .{ .a = a };
    defer body_enc.deinit();
    var sig: std.ArrayList(u8) = .empty;
    defer sig.deinit(a);
    for (body) |v| {
        try body_enc.value(v);
        try sig.append(a, v.typeCode());
    }

    var msg: Encoder = .{ .a = a };
    errdefer msg.deinit();
    try writeFixedHeader(&msg, typ, flags, serial, body_enc.buf.items.len);
    try writeHeaderFields(&msg, header, sig.items);
    try msg.pad(struct_alignment);
    try msg.buf.appendSlice(a, body_enc.buf.items);
    return msg.buf.toOwnedSlice(a);
}

/// Writes the 16 fixed bytes. The field array length is a placeholder until
/// writeHeaderFields knows it.
fn writeFixedHeader(msg: *Encoder, typ: MessageType, flags: u8, serial: u32, body_len: usize) !void {
    try msg.byte(little_endian_marker);
    try msg.byte(@backingInt(typ));
    try msg.byte(flags);
    try msg.byte(protocol_version);
    try msg.int(u32, @intCast(body_len));
    try msg.int(u32, serial);
    try msg.int(u32, 0);
}

fn writeHeaderFields(msg: *Encoder, h: Header, body_signature: []const u8) !void {
    const start = msg.buf.items.len;
    if (h.path) |v| try msg.field(.path, .{ .object_path = v });
    if (h.interface) |v| try msg.field(.interface, .{ .string = v });
    if (h.member) |v| try msg.field(.member, .{ .string = v });
    if (h.error_name) |v| try msg.field(.error_name, .{ .string = v });
    if (h.reply_serial) |v| try msg.field(.reply_serial, .{ .uint32 = v });
    if (h.destination) |v| try msg.field(.destination, .{ .string = v });
    if (body_signature.len > 0) try msg.field(.signature, .{ .signature = body_signature });
    const fields_len: u32 = @intCast(msg.buf.items.len - start);
    mem.writeInt(u32, msg.buf.items[fields_length_offset..][0..4], fields_len, .little);
}

// ---------- decoding ----------

/// A received message. Every string field points into `raw`, which the message owns, so
/// they stay valid until `deinit`.
pub const Message = struct {
    raw: []u8,
    typ: MessageType,
    flags: u8,
    serial: u32,
    big_endian: bool,
    /// For replies: the serial of the call this answers.
    reply_serial: ?u32 = null,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    /// For error replies, e.g. "org.freedesktop.DBus.Error.UnknownMethod".
    error_name: []const u8 = "",
    destination: []const u8 = "",
    /// The unique bus name of whoever sent the message, e.g. ":1.42".
    sender: []const u8 = "",
    /// The body's type signature, e.g. "si" for a string and an int32.
    signature: []const u8 = "",
    body_offset: usize = 0,

    pub fn deinit(m: *Message, a: Allocator) void {
        a.free(m.raw);
        m.* = undefined;
    }

    /// Whether the sender of a method call waits for a reply.
    pub fn expectsReply(m: *const Message) bool {
        return m.flags & Flags.no_reply_expected == 0;
    }

    /// Decodes the whole body. Free the returned slice; its strings point into the message.
    /// Bodies with container types return error.UnsupportedType.
    pub fn args(m: *const Message, a: Allocator) ![]Value {
        var out: std.ArrayList(Value) = .empty;
        errdefer out.deinit(a);
        var d = m.bodyDecoder();
        for (m.signature) |code| try out.append(a, try d.value(code));
        return out.toOwnedSlice(a);
    }

    /// The body's value if the body is exactly one value of type `kind`; null otherwise.
    /// Typical for method replies, e.g. `reply.single(.int32)`.
    pub fn single(m: *const Message, comptime kind: Value.Kind) ?@FieldType(Value, @tagName(kind)) {
        const expected = Value.codeOf(kind);
        if (m.signature.len != 1 or m.signature[0] != expected) return null;
        var d = m.bodyDecoder();
        const v = d.value(expected) catch return null;
        return @field(v, @tagName(kind));
    }

    /// The body's first value if it is a string, otherwise "". Error replies carry their
    /// human-readable text this way.
    pub fn firstString(m: *const Message) []const u8 {
        if (m.signature.len == 0 or m.signature[0] != 's') return "";
        var d = m.bodyDecoder();
        return d.string() catch "";
    }

    fn bodyDecoder(m: *const Message) Decoder {
        return .{ .buf = m.raw, .pos = m.body_offset, .base = m.body_offset, .big_endian = m.big_endian };
    }
};

/// Reads values following D-Bus alignment rules, measured from `base`. Every read checks
/// bounds, so malformed input gives error.ProtocolError instead of reading past the end.
const Decoder = struct {
    buf: []const u8,
    pos: usize,
    base: usize,
    big_endian: bool,

    fn alignTo(d: *Decoder, alignment: usize) !void {
        d.pos = d.base + mem.alignForward(usize, d.pos - d.base, alignment);
        if (d.pos > d.buf.len) return error.ProtocolError;
    }

    fn take(d: *Decoder, n: usize) ![]const u8 {
        if (d.pos + n > d.buf.len) return error.ProtocolError;
        defer d.pos += n;
        return d.buf[d.pos..][0..n];
    }

    fn int(d: *Decoder, comptime T: type) !T {
        try d.alignTo(@sizeOf(T));
        const bytes = try d.take(@sizeOf(T));
        return mem.readInt(T, bytes[0..@sizeOf(T)], if (d.big_endian) .big else .little);
    }

    fn string(d: *Decoder) ![]const u8 {
        const len = try d.int(u32);
        const s = try d.take(len);
        _ = try d.take(1);
        return s;
    }

    fn signature(d: *Decoder) ![]const u8 {
        const len = (try d.take(1))[0];
        const s = try d.take(len);
        _ = try d.take(1);
        return s;
    }

    /// Reads one value of the type with signature character `code`.
    fn value(d: *Decoder, code: u8) !Value {
        return switch (code) {
            'y' => .{ .byte = (try d.take(1))[0] },
            'b' => .{ .boolean = try d.int(u32) != 0 },
            'i' => .{ .int32 = try d.int(i32) },
            'u' => .{ .uint32 = try d.int(u32) },
            'x' => .{ .int64 = try d.int(i64) },
            't' => .{ .uint64 = try d.int(u64) },
            's' => .{ .string = try d.string() },
            'o' => .{ .object_path = try d.string() },
            'g' => .{ .signature = try d.signature() },
            else => error.UnsupportedType,
        };
    }
};

fn endianOf(marker: u8) !std.builtin.Endian {
    return switch (marker) {
        little_endian_marker => .little,
        big_endian_marker => .big,
        else => error.ProtocolError,
    };
}

/// The total length of the message at the start of `buf`, or null while it hasn't fully
/// arrived. Used to cut complete messages out of a stream of socket reads.
pub fn messageLength(buf: []const u8) !?usize {
    if (buf.len < fixed_header_len) return null;
    const endian = try endianOf(buf[0]);
    const body_len = mem.readInt(u32, buf[body_length_offset..][0..4], endian);
    const fields_len = mem.readInt(u32, buf[fields_length_offset..][0..4], endian);
    const total = mem.alignForward(usize, fixed_header_len + @as(usize, fields_len), struct_alignment) + body_len;
    if (total > max_message_len) return error.ProtocolError;
    return if (buf.len >= total) total else null;
}

/// Parses one complete message (see messageLength). On success the message owns `raw`;
/// on error the caller still does.
pub fn decode(raw: []u8) !Message {
    const endian = try endianOf(raw[0]);
    var m: Message = .{
        .raw = raw,
        .typ = @fromBackingInt(@intCast(raw[1])),
        .flags = raw[2],
        .serial = mem.readInt(u32, raw[serial_offset..][0..4], endian),
        .big_endian = endian == .big,
    };
    const fields_end = fixed_header_len + @as(usize, mem.readInt(u32, raw[fields_length_offset..][0..4], endian));
    if (fields_end > raw.len) return error.ProtocolError;
    try readHeaderFields(&m, raw[0..fields_end]);
    m.body_offset = mem.alignForward(usize, fields_end, struct_alignment);
    return m;
}

/// Fills in the fields of `m` that the header carries. Unknown fields (such as unix fd
/// counts) are skipped.
fn readHeaderFields(m: *Message, header: []const u8) !void {
    var d: Decoder = .{ .buf = header, .pos = fixed_header_len, .base = 0, .big_endian = m.big_endian };
    while (d.pos < header.len) {
        try d.alignTo(struct_alignment);
        if (d.pos >= header.len) break;
        const code: Field = @fromBackingInt(@intCast((try d.take(1))[0]));
        const sig = try d.signature();
        if (sig.len != 1) return error.ProtocolError;
        const v = try d.value(sig[0]);
        switch (code) {
            .path => m.path = v.object_path,
            .interface => m.interface = v.string,
            .member => m.member = v.string,
            .error_name => m.error_name = v.string,
            .reply_serial => m.reply_serial = v.uint32,
            .destination => m.destination = v.string,
            .sender => m.sender = v.string,
            .signature => m.signature = v.signature,
            _ => {},
        }
    }
}

// ---------- tests ----------

const testing = std.testing;

fn roundTrip(bytes: []const u8) !Message {
    return decode(try testing.allocator.dupe(u8, bytes));
}

test "a method call survives encode and decode" {
    const a = testing.allocator;
    const bytes = try encode(a, .method_call, 0, 7, .{
        .destination = "org.kde.KWin",
        .path = "/Scripting",
        .interface = "org.kde.kwin.Scripting",
        .member = "loadScript",
    }, &.{ .{ .string = "/tmp/x.js" }, .{ .string = "kwinctl_1" }, .{ .int32 = -3 }, .{ .boolean = true } });
    defer a.free(bytes);
    try testing.expectEqual(@as(?usize, bytes.len), try messageLength(bytes));
    try testing.expectEqual(@as(?usize, null), try messageLength(bytes[0 .. bytes.len - 1]));

    var m = try roundTrip(bytes);
    defer m.deinit(a);
    try testing.expectEqual(MessageType.method_call, m.typ);
    try testing.expectEqual(@as(u32, 7), m.serial);
    try testing.expectEqualStrings("/Scripting", m.path);
    try testing.expectEqualStrings("loadScript", m.member);
    try testing.expectEqualStrings("org.kde.KWin", m.destination);
    try testing.expectEqualStrings("ssib", m.signature);
    const values = try m.args(a);
    defer a.free(values);
    try testing.expectEqualStrings("/tmp/x.js", values[0].string);
    try testing.expectEqualStrings("kwinctl_1", values[1].string);
    try testing.expectEqual(@as(i32, -3), values[2].int32);
    try testing.expect(values[3].boolean);
}

test "the body starts on an 8-byte boundary and single() reads a lone value" {
    const a = testing.allocator;
    const bytes = try encode(a, .method_return, 0, 1, .{ .reply_serial = 5 }, &.{.{ .uint64 = 42 }});
    defer a.free(bytes);
    var m = try roundTrip(bytes);
    defer m.deinit(a);
    try testing.expectEqual(@as(usize, 0), m.body_offset % 8);
    try testing.expectEqual(@as(?u32, 5), m.reply_serial);
    try testing.expectEqual(@as(?u64, 42), m.single(.uint64));
    try testing.expectEqual(@as(?i32, null), m.single(.int32));
}

test "big-endian messages decode" {
    const a = testing.allocator;
    // A method_return with reply serial 3 and one int32 body value, 7.
    const raw = [_]u8{
        'B', 2, 0,   1, 0, 0, 0, 4, 0, 0, 0,   9, 0, 0,   0, 0x0f,
        5,   1, 'u', 0, 0, 0, 0, 3, 8, 1, 'g', 0, 1, 'i', 0, 0,
        0,   0, 0,   7,
    };
    try testing.expectEqual(@as(?usize, 36), try messageLength(&raw));
    var m = try roundTrip(&raw);
    defer m.deinit(a);
    try testing.expectEqual(@as(?u32, 3), m.reply_serial);
    try testing.expectEqual(@as(?i32, 7), m.single(.int32));
}

test "garbage is rejected instead of read past the end" {
    var bad_marker: [16]u8 = @splat(0);
    bad_marker[0] = 'X';
    try testing.expectError(error.ProtocolError, messageLength(&bad_marker));

    const a = testing.allocator;
    const fields_too_long = [_]u8{ 'l', 2, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0xff, 0, 0, 0 };
    const raw = try a.dupe(u8, &fields_too_long);
    defer a.free(raw);
    try testing.expectError(error.ProtocolError, decode(raw));
}
