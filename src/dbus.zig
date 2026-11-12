//! A small D-Bus client in pure Zig.
//!
//! It implements just enough of the protocol to call methods on the session bus and to
//! receive method calls back, which is how KWin scripts report results. Linux only: Unix
//! sockets, EXTERNAL authentication and the basic types (y b i u x t s o g).
const wire = @import("dbus/wire.zig");

pub const Connection = @import("dbus/Connection.zig");
pub const Method = Connection.Method;
pub const Message = wire.Message;
pub const Value = wire.Value;

test {
    _ = wire;
    _ = Connection;
    _ = @import("dbus/address.zig");
}
