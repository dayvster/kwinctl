//! A connection to KWin, the KDE Plasma 6 window manager, for listing and controlling windows.
//!
//! ```zig
//! var client = try Client.init(gpa, .{ .bus_address = bus, .runtime_dir = xdg_runtime_dir });
//! defer client.deinit();
//!
//! const list = try client.windows(gpa, .{});
//! defer list.deinit();
//! for (list.value) |w| {
//!     if (std.mem.eql(u8, w.app, "org.kde.konsole")) try client.focus(w.id);
//! }
//! ```
//!
//! ## How it works
//! On Wayland, KWin shows windows only to its own scripts. So every operation is a small
//! JavaScript program (see scripts.zig) that the client writes to a private file in
//! `runtime_dir`, has KWin load and run over D-Bus, and then unloads again. The script sends
//! its results back by calling this client's own D-Bus name. One operation takes a few
//! milliseconds.
//!
//! ## Errors
//! Besides allocation and bus failures, operations return:
//! - `error.KWinNotRunning` from `init`: no KWin on this bus (not a Plasma 6 session).
//! - `error.InvalidId`: an id that isn't a KWin window UUID.
//! - `error.WindowNotFound`: no window has that id (anymore).
//! - `error.ScriptFailed`: the script threw or reported an error, or KWin refused it.
//! - `error.Timeout`: KWin didn't answer within `Options.timeout_ms`.
//!
//! After any of these, `lastError()` has a message fit to show to a user.
//!
//! A client is not thread-safe; use one per thread.
const Client = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const dbus = @import("dbus.zig");
const sys = @import("sys.zig");
const scripts = @import("scripts.zig");
const types = @import("types.zig");
const window_id = @import("window_id.zig");
const Window = types.Window;
const Screen = types.Screen;
const Rect = types.Rect;

a: Allocator,
conn: dbus.Connection,
runtime_dir: []u8,
timeout_ms: u32,
/// How many scripts this client has run; part of each script's file and plugin name.
runs: u32 = 0,
last_error: std.ArrayList(u8) = .empty,

/// Settings for `init`.
pub const Options = struct {
    /// The session bus to find KWin on, normally the value of $DBUS_SESSION_BUS_ADDRESS,
    /// e.g. "unix:path=/run/user/1000/bus".
    bus_address: []const u8,
    /// A directory only this user can write to, for the script files KWin reads; normally
    /// $XDG_RUNTIME_DIR. Falls back to /tmp when null. Files are created with mode 0600 and
    /// deleted as soon as KWin has loaded them.
    runtime_dir: ?[]const u8 = null,
    /// The longest any single operation may take, in milliseconds, including waiting for
    /// KWin to run the script.
    timeout_ms: u32 = 5000,
};

/// Settings for `windows`.
pub const ListOptions = struct {
    /// Also list docks, panels, popups, notifications and other windows that aren't
    /// ordinary application windows.
    all: bool = false,
};

const bus_name_has_owner: dbus.Method = .{
    .destination = "org.freedesktop.DBus",
    .path = "/org/freedesktop/DBus",
    .interface = "org.freedesktop.DBus",
    .member = "NameHasOwner",
};

fn kwinScripting(member: []const u8) dbus.Method {
    return .{ .destination = "org.kde.KWin", .path = "/Scripting", .interface = "org.kde.kwin.Scripting", .member = member };
}

/// Connects to the session bus and makes sure KWin is on it.
///
/// Returns `error.KWinNotRunning` when no KWin is on that bus, e.g. under another desktop
/// or on Plasma 5, and the connection errors of `dbus.Connection.open` when the bus can't be
/// reached. Free the client with `deinit`.
pub fn init(a: Allocator, options: Options) !Client {
    var conn = try dbus.Connection.open(a, options.bus_address, options.timeout_ms);
    errdefer conn.close();
    try requireKWin(&conn, options.timeout_ms);
    return .{
        .a = a,
        .conn = conn,
        .runtime_dir = try a.dupe(u8, options.runtime_dir orelse "/tmp"),
        .timeout_ms = options.timeout_ms,
    };
}

/// Closes the bus connection and frees everything the client owns. Results returned
/// earlier (window lists and so on) stay valid; they are freed separately.
pub fn deinit(c: *Client) void {
    c.conn.close();
    c.a.free(c.runtime_dir);
    c.last_error.deinit(c.a);
    c.* = undefined;
}

/// Fails with error.KWinNotRunning unless something owns the bus name org.kde.KWin.
fn requireKWin(conn: *dbus.Connection, timeout_ms: u32) !void {
    var reply = conn.call(bus_name_has_owner, &.{.{ .string = "org.kde.KWin" }}, timeout_ms) catch return error.KWinNotRunning;
    defer reply.deinit(conn.a);
    if (reply.single(.boolean) != true) return error.KWinNotRunning;
}

/// A human-readable description of the most recent error: the script's exception text, KWin's
/// or the bus's error message, or kwinctl's own explanation. Empty before any error. Valid
/// until the next call on the client.
pub fn lastError(c: *const Client) []const u8 {
    return c.last_error.items;
}

// ---------- windows ----------

/// All application windows (or, with `.all`, every window), in stacking order from bottom
/// to top, so the last one is in front.
///
/// The result and all strings in it are allocated with `a`; free them with `.deinit()`.
pub fn windows(c: *Client, a: Allocator, options: ListOptions) !std.json.Parsed([]Window) {
    return c.query([]Window, a, scripts.listWindows(options.all));
}

/// The window that has keyboard focus, or null when none has (e.g. on an empty desktop).
///
/// Allocated with `a`; free with `.deinit()`.
pub fn activeWindow(c: *Client, a: Allocator) !?std.json.Parsed(Window) {
    const json = try c.runForOneResult(scripts.active_window);
    defer c.a.free(json);
    if (mem.eql(u8, json, "null")) return null;
    return try types.parse(Window, a, json);
}

/// Every output (monitor), each with its full geometry and its work area: the part not
/// covered by panels, which is where maximized windows go.
///
/// Allocated with `a`; free with `.deinit()`.
pub fn screens(c: *Client, a: Allocator) !std.json.Parsed([]Screen) {
    return c.query([]Screen, a, scripts.list_screens);
}

/// Gives a window keyboard focus and raises it. A minimized window is restored first, and if
/// the window is on another virtual desktop, KWin switches to that desktop.
///
/// `id` is the window's `Window.id`; braces and letter case don't matter.
/// Errors: `error.InvalidId`, `error.WindowNotFound`.
pub fn focus(c: *Client, id: []const u8) !void {
    try c.onWindow(id, scripts.Action.focus);
}

/// Asks a window to close, the same as clicking its close button. Returns once KWin has sent
/// the request: the application may still show a dialog (e.g. "save changes?") or refuse.
///
/// Errors: `error.InvalidId`, `error.WindowNotFound`.
pub fn close(c: *Client, id: []const u8) !void {
    try c.onWindow(id, scripts.Action.close);
}

/// Minimizes a window (`minimized = true`) or restores it (`false`). Restoring doesn't focus
/// the window; use `focus` for that.
///
/// Errors: `error.InvalidId`, `error.WindowNotFound`.
pub fn setMinimized(c: *Client, id: []const u8, minimized: bool) !void {
    try c.onWindow(id, if (minimized) scripts.Action.minimize else scripts.Action.unminimize);
}

/// Puts a window into fullscreen on its current output (`true`) or takes it out (`false`).
///
/// Errors: `error.InvalidId`, `error.WindowNotFound`.
pub fn setFullscreen(c: *Client, id: []const u8, fullscreen: bool) !void {
    try c.onWindow(id, if (fullscreen) scripts.Action.enter_fullscreen else scripts.Action.leave_fullscreen);
}

/// Moves and resizes a window's frame (title bar and borders included) to `r`, in global
/// coordinates as `screens` reports them. The window leaves maximized and fullscreen first.
///
/// On Wayland the application resizes itself in response, so `windows` may report the old
/// geometry for a moment afterwards. Applications can also enforce a minimum size.
///
/// Errors: `error.InvalidId`, `error.WindowNotFound`.
pub fn setGeometry(c: *Client, id: []const u8, r: Rect) !void {
    var buf: [scripts.Action.geometry_buffer_len]u8 = undefined;
    try c.onWindow(id, scripts.Action.setGeometry(&buf, r));
}

/// Runs `action` (one of scripts.Action) with the JavaScript variable `w` set to the window
/// with this id. The id is validated before it goes into the script.
fn onWindow(c: *Client, id: []const u8, action: []const u8) !void {
    var id_buf: window_id.Buffer = undefined;
    const normalized = window_id.normalize(id, &id_buf) orelse return error.InvalidId;
    const source = try scripts.onWindow(c.a, normalized, action);
    defer c.a.free(source);
    const results = c.runScript(c.a, source) catch |err| {
        if (err == error.ScriptFailed and mem.eql(u8, c.lastError(), scripts.window_not_found)) {
            c.setError("no window with that id", .{});
            return error.WindowNotFound;
        }
        return err;
    };
    freeResults(c.a, results);
}

/// Runs a script that reports one JSON value and parses it as `T` with `a`.
fn query(c: *Client, comptime T: type, a: Allocator, source: []const u8) !std.json.Parsed(T) {
    const json = try c.runForOneResult(source);
    defer c.a.free(json);
    return types.parse(T, a, json);
}

/// Runs a script that must report exactly one value and returns it, allocated with the
/// client's allocator.
fn runForOneResult(c: *Client, source: []const u8) ![]u8 {
    const results = try c.runScript(c.a, source);
    defer c.a.free(results);
    if (results.len == 1) return results[0];
    for (results) |r| c.a.free(r);
    c.setError("expected one result from KWin, got {d}", .{results.len});
    return error.ScriptFailed;
}

// ---------- running scripts ----------

/// Runs your own KWin script and returns the values it reported, in order.
///
/// The script has the full KWin scripting API (`workspace`, `KWin`, ...) plus two functions:
/// - `output_result(value)` reports a value, converted with String(). Call it any number of
///   times; each call becomes one element of the result.
/// - `output_error(text)` fails the run with `error.ScriptFailed` and `text` in `lastError`.
///   An uncaught exception does the same with the exception's message.
///
/// The run ends when the script's top-level code returns, so values reported later (e.g. from
/// timers or signal handlers) are lost. `error.Timeout` if KWin doesn't answer in time.
///
/// ```zig
/// const values = try client.runScript(gpa, "output_result(workspace.currentDesktop.name);");
/// defer Client.freeResults(gpa, values);
/// ```
///
/// Allocated with `a`; free with `freeResults`.
pub fn runScript(c: *Client, a: Allocator, source: []const u8) ![][]u8 {
    var run = try ScriptRun.start(c, source);
    defer run.finish(c);
    return c.collectResults(a, run.token(), sys.Deadline.in(c.timeout_ms));
}

/// Frees the values returned by `runScript`, which must have been allocated with `a`.
pub fn freeResults(a: Allocator, results: [][]u8) void {
    for (results) |r| a.free(r);
    a.free(results);
}

/// One script's trip through KWin. `start` writes it to a file, loads it and starts it;
/// `finish` unloads it and deletes the file, even after an error.
const ScriptRun = struct {
    plugin_name: []u8,
    path: [:0]u8,
    token_buf: [24]u8,
    token_len: usize,
    loaded: bool = false,

    fn start(c: *Client, source: []const u8) !ScriptRun {
        c.runs += 1;
        var run = try ScriptRun.init(c);
        errdefer run.finish(c);

        const wrapped = try scripts.wrap(c.a, c.conn.unique_name, run.token(), source);
        defer c.a.free(wrapped);
        try sys.createPrivateFile(run.path, wrapped);

        const script_id = try run.load(c);
        run.loaded = true;
        try runLoadedScript(c, script_id);
        return run;
    }

    /// Builds the file name, the KWin plugin name and the reply token from the process id and
    /// the run count, so runs from several kwinctl processes never collide.
    fn init(c: *Client) !ScriptRun {
        const pid = sys.pid();
        var run: ScriptRun = .{ .plugin_name = undefined, .path = undefined, .token_buf = undefined, .token_len = 0 };
        run.token_len = (std.fmt.bufPrint(&run.token_buf, "{x}-{x}", .{ pid, c.runs }) catch unreachable).len;
        run.plugin_name = try std.fmt.allocPrint(c.a, "kwinctl_{d}_{d}", .{ pid, c.runs });
        errdefer c.a.free(run.plugin_name);
        run.path = try std.fmt.allocPrintSentinel(c.a, "{s}/kwinctl-{d}-{d}.js", .{ c.runtime_dir, pid, c.runs }, 0);
        return run;
    }

    /// Tags every reply from this run, so replies from earlier runs are ignored.
    fn token(run: *const ScriptRun) []const u8 {
        return run.token_buf[0..run.token_len];
    }

    /// Asks KWin to load the script file. KWin answers with the script's number, or -1 when it
    /// can't load it.
    fn load(run: *const ScriptRun, c: *Client) !i32 {
        var reply = c.conn.call(kwinScripting("loadScript"), &.{ .{ .string = run.path }, .{ .string = run.plugin_name } }, c.timeout_ms) catch |err| return c.busError(err);
        defer reply.deinit(c.a);
        const script_id = reply.single(.int32) orelse -1;
        if (script_id < 0) {
            c.setError("KWin refused to load the script", .{});
            return error.ScriptFailed;
        }
        return script_id;
    }

    fn finish(run: *ScriptRun, c: *Client) void {
        if (run.loaded) {
            c.conn.callVoid(kwinScripting("unloadScript"), &.{.{ .string = run.plugin_name }}, c.timeout_ms) catch {};
        }
        sys.deleteFile(run.path);
        c.a.free(run.path);
        c.a.free(run.plugin_name);
        run.* = undefined;
    }
};

/// Starts a loaded script. KWin 6 exposes each loaded script as the object
/// /Scripting/Script<number>, which has a run() method.
fn runLoadedScript(c: *Client, script_id: i32) !void {
    var path_buf: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/Scripting/Script{d}", .{script_id}) catch unreachable;
    const run_method: dbus.Method = .{ .destination = "org.kde.KWin", .path = path, .interface = "org.kde.kwin.Script", .member = "run" };
    c.conn.callVoid(run_method, &.{}, c.timeout_ms) catch |err| return c.busError(err);
}

/// What one call from a running script means. Strings point into the call message.
const ScriptReply = union(enum) {
    /// output_result(value)
    result: []const u8,
    /// output_error(text), or an uncaught exception
    failed: []const u8,
    /// The script's top-level code finished.
    done,
    /// From an earlier run or someone else entirely; ignored.
    unrelated,
};

/// Answers the calls a script makes back to us and gathers its results, until it reports
/// Done or an error, or the deadline passes.
fn collectResults(c: *Client, a: Allocator, run_token: []const u8, deadline: sys.Deadline) ![][]u8 {
    var results: std.ArrayList([]u8) = .empty;
    errdefer {
        for (results.items) |r| a.free(r);
        results.deinit(a);
    }
    while (true) {
        var call = c.conn.waitCall(deadline) catch |err| switch (err) {
            error.Timeout => {
                c.setError("KWin did not answer within {d} ms", .{c.timeout_ms});
                return error.Timeout;
            },
            else => return err,
        };
        defer call.deinit(c.a);
        c.conn.replyEmpty(&call) catch {};

        switch (try parseScriptReply(c.a, &call, run_token)) {
            .unrelated => {},
            .result => |value| {
                const owned = try a.dupe(u8, value);
                results.append(a, owned) catch |err| {
                    a.free(owned);
                    return err;
                };
            },
            .failed => |text| {
                c.setError("{s}", .{text});
                return error.ScriptFailed;
            },
            .done => return results.toOwnedSlice(a),
        }
    }
}

/// Reads a call from a script: the method (Result, Error or Done) on scripts.reply_interface,
/// with two string arguments, the run token and the value.
fn parseScriptReply(a: Allocator, call: *const dbus.Message, run_token: []const u8) !ScriptReply {
    if (!mem.eql(u8, call.interface, scripts.reply_interface)) return .unrelated;
    const args = call.args(a) catch return .unrelated;
    defer a.free(args);
    if (args.len != 2 or args[0] != .string or args[1] != .string) return .unrelated;
    if (!mem.eql(u8, args[0].string, run_token)) return .unrelated;
    const value = args[1].string;
    if (mem.eql(u8, call.member, "Result")) return .{ .result = value };
    if (mem.eql(u8, call.member, "Error")) return .{ .failed = value };
    if (mem.eql(u8, call.member, "Done")) return .done;
    return .unrelated;
}

// ---------- errors ----------

/// Replaces the text lastError returns.
fn setError(c: *Client, comptime fmt: []const u8, args: anytype) void {
    c.last_error.clearRetainingCapacity();
    c.last_error.print(c.a, fmt, args) catch {};
}

/// For a bus call that failed: an error reply from KWin becomes error.ScriptFailed with KWin's
/// message in lastError; other errors (timeouts, a closed connection) pass through unchanged.
fn busError(c: *Client, err: anyerror) anyerror {
    if (err != error.CallFailed) return err;
    c.setError("{s}", .{c.conn.last_error.items});
    return error.ScriptFailed;
}
