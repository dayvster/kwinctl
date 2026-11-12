const std = @import("std");
const kwinctl = @import("kwinctl");
const mem = std.mem;
const Allocator = mem.Allocator;
const Writer = std.Io.Writer;

const usage =
    \\kwinctl: list and control KDE Plasma 6 windows
    \\
    \\usage: kwinctl [--json] [--timeout MS] COMMAND [ARGS]
    \\
    \\  list [--all]            windows: id, app, title (--all adds panels, docks, popups)
    \\  active                  the focused window
    \\  screens                 outputs with their full and usable areas
    \\  focus ID                focus a window (un-minimizes, switches desktop)
    \\  close ID                ask a window to close
    \\  minimize ID             minimize ("unminimize ID" restores)
    \\  fullscreen ID on|off    enter or leave fullscreen
    \\  move ID X Y W H         move and resize a window's frame
    \\  script FILE|-           run your own KWin script (use output_result(value) to print)
    \\
    \\IDs are KWin window UUIDs, with or without braces (see `kwinctl list`).
    \\--json prints JSON instead of tab-separated text.
    \\
;

const max_script_bytes = 1024 * 1024;

/// Everything a command needs.
const Context = struct {
    a: Allocator,
    io: std.Io,
    client: *kwinctl.Client,
    out: *Writer,
    json: bool,
};

const Command = struct {
    name: []const u8,
    /// Number of arguments after the command name.
    min_args: usize,
    max_args: usize,
    run: *const fn (ctx: Context, args: []const []const u8) anyerror!void,
};

const commands = [_]Command{
    .{ .name = "list", .min_args = 0, .max_args = 1, .run = list },
    .{ .name = "active", .min_args = 0, .max_args = 0, .run = active },
    .{ .name = "screens", .min_args = 0, .max_args = 0, .run = screens },
    .{ .name = "focus", .min_args = 1, .max_args = 1, .run = focus },
    .{ .name = "close", .min_args = 1, .max_args = 1, .run = close },
    .{ .name = "minimize", .min_args = 1, .max_args = 1, .run = minimize },
    .{ .name = "unminimize", .min_args = 1, .max_args = 1, .run = unminimize },
    .{ .name = "fullscreen", .min_args = 2, .max_args = 2, .run = fullscreen },
    .{ .name = "move", .min_args = 5, .max_args = 5, .run = move },
    .{ .name = "script", .min_args = 1, .max_args = 1, .run = script },
};

/// Exit codes.
const exit_ok = 0;
const exit_failed = 1;
const exit_usage = 2;

pub fn main(init: std.process.Init) !u8 {
    var out_buf: [16 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    defer out.interface.flush() catch {};
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    defer err.interface.flush() catch {};

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    return run(init.gpa, init.io, init.environ_map, argv[1..], &out.interface, &err.interface);
}

fn run(a: Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8, out: *Writer, err: *Writer) !u8 {
    var parsed = parseArgs(a, argv) catch |e| return fail(err, "{s}", .{switch (e) {
        error.BadTimeout => "--timeout needs a number of milliseconds",
        else => @errorName(e),
    }});
    defer parsed.deinit(a);
    if (parsed.help) {
        try out.writeAll(usage);
        return exit_ok;
    }
    const command = findCommand(parsed.words.items) orelse {
        try err.writeAll(usage);
        return exit_usage;
    };

    var client = connect(a, env, parsed.timeout_ms) catch |e| return fail(err, "{s}", .{connectError(e)});
    defer client.deinit();

    const ctx: Context = .{ .a = a, .io = io, .client = &client, .out = out, .json = parsed.json };
    command.run(ctx, parsed.words.items[1..]) catch |e| switch (e) {
        error.Usage => {
            try err.writeAll(usage);
            return exit_usage;
        },
        else => return fail(err, "{s}", .{commandError(e, &client)}),
    };
    return exit_ok;
}

// ---------- arguments ----------

const Args = struct {
    json: bool = false,
    help: bool = false,
    timeout_ms: u32 = 5000,
    /// The command and its arguments.
    words: std.ArrayList([]const u8) = .empty,

    fn deinit(args: *Args, a: Allocator) void {
        args.words.deinit(a);
    }
};

/// Global options may appear anywhere; everything else is the command and its arguments.
fn parseArgs(a: Allocator, argv: []const []const u8) !Args {
    var args: Args = .{};
    errdefer args.deinit(a);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (mem.eql(u8, arg, "--json")) {
            args.json = true;
        } else if (mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i == argv.len) return error.BadTimeout;
            args.timeout_ms = std.fmt.parseInt(u32, argv[i], 10) catch return error.BadTimeout;
        } else if (isHelp(arg)) {
            args.help = true;
        } else {
            try args.words.append(a, arg);
        }
    }
    return args;
}

fn isHelp(arg: []const u8) bool {
    return mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "help");
}

/// The command for `words`, if the name exists and the argument count fits.
fn findCommand(words: []const []const u8) ?Command {
    if (words.len == 0) return null;
    const arg_count = words.len - 1;
    for (commands) |command| {
        if (!mem.eql(u8, command.name, words[0])) continue;
        if (arg_count < command.min_args or arg_count > command.max_args) return null;
        return command;
    }
    return null;
}

fn connect(a: Allocator, env: *const std.process.Environ.Map, timeout_ms: u32) !kwinctl.Client {
    const bus = env.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoSessionBus;
    return kwinctl.Client.init(a, .{
        .bus_address = bus,
        .runtime_dir = env.get("XDG_RUNTIME_DIR"),
        .timeout_ms = timeout_ms,
    });
}

// ---------- commands ----------

fn list(ctx: Context, args: []const []const u8) !void {
    const all = args.len == 1;
    if (all and !mem.eql(u8, args[0], "--all")) return error.Usage;
    const windows = try ctx.client.windows(ctx.a, .{ .all = all });
    defer windows.deinit();
    if (ctx.json) return printJson(ctx.out, windows.value);
    for (windows.value) |w| try printWindow(ctx.out, w);
}

fn active(ctx: Context, _: []const []const u8) !void {
    const window = try ctx.client.activeWindow(ctx.a) orelse return;
    defer window.deinit();
    if (ctx.json) return printJson(ctx.out, window.value);
    try printWindow(ctx.out, window.value);
}

fn screens(ctx: Context, _: []const []const u8) !void {
    const outputs = try ctx.client.screens(ctx.a);
    defer outputs.deinit();
    if (ctx.json) return printJson(ctx.out, outputs.value);
    for (outputs.value) |s| try printScreen(ctx.out, s);
}

fn focus(ctx: Context, args: []const []const u8) !void {
    try ctx.client.focus(args[0]);
}

fn close(ctx: Context, args: []const []const u8) !void {
    try ctx.client.close(args[0]);
}

fn minimize(ctx: Context, args: []const []const u8) !void {
    try ctx.client.setMinimized(args[0], true);
}

fn unminimize(ctx: Context, args: []const []const u8) !void {
    try ctx.client.setMinimized(args[0], false);
}

fn fullscreen(ctx: Context, args: []const []const u8) !void {
    try ctx.client.setFullscreen(args[0], try parseOnOff(args[1]));
}

fn move(ctx: Context, args: []const []const u8) !void {
    try ctx.client.setGeometry(args[0], try parseRect(args[1..5]));
}

fn script(ctx: Context, args: []const []const u8) !void {
    const source = try readFileOrStdin(ctx.a, ctx.io, args[0]);
    defer ctx.a.free(source);
    const results = try ctx.client.runScript(ctx.a, source);
    defer kwinctl.Client.freeResults(ctx.a, results);
    for (results) |r| try ctx.out.print("{s}\n", .{r});
}

fn parseOnOff(word: []const u8) !bool {
    if (mem.eql(u8, word, "on")) return true;
    if (mem.eql(u8, word, "off")) return false;
    return error.Usage;
}

/// X Y W H, with a positive size.
fn parseRect(words: []const []const u8) !kwinctl.Rect {
    var numbers: [4]i32 = undefined;
    for (words, &numbers) |word, *n| n.* = std.fmt.parseInt(i32, word, 10) catch return error.Usage;
    const r: kwinctl.Rect = .{ .x = numbers[0], .y = numbers[1], .width = numbers[2], .height = numbers[3] };
    if (r.width <= 0 or r.height <= 0) return error.Usage;
    return r;
}

/// The script's source from a file, or from standard input for "-".
fn readFileOrStdin(a: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const limit: std.Io.Limit = .limited(max_script_bytes);
    const source = if (mem.eql(u8, path, "-")) blk: {
        var buf: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(io, &buf);
        break :blk stdin.interface.allocRemaining(a, limit);
    } else std.Io.Dir.cwd().readFileAlloc(io, path, a, limit);
    return source catch |e| switch (e) {
        error.StreamTooLong => error.ScriptTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.CannotReadScript,
    };
}

// ---------- output ----------

fn printWindow(out: *Writer, w: kwinctl.Window) !void {
    try out.print("{s}\t{s}\t{s}\n", .{ w.id, w.app, w.title });
}

fn printScreen(out: *Writer, s: kwinctl.Screen) !void {
    const g = s.geometry;
    const wa = s.work_area;
    try out.print("{s}\t{d},{d} {d}x{d}\twork area {d},{d} {d}x{d}\n", .{ s.name, g.x, g.y, g.width, g.height, wa.x, wa.y, wa.width, wa.height });
}

fn printJson(out: *Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, out);
    try out.writeByte('\n');
}

// ---------- errors ----------

fn fail(err: *Writer, comptime fmt: []const u8, args: anytype) u8 {
    err.print("kwinctl: " ++ fmt ++ "\n", args) catch {};
    return exit_failed;
}

fn connectError(e: anyerror) []const u8 {
    return switch (e) {
        error.NoSessionBus => "no session bus (DBUS_SESSION_BUS_ADDRESS is not set)",
        error.KWinNotRunning => "KWin is not running on this session bus (kwinctl needs KDE Plasma 6)",
        else => "cannot reach the session bus",
    };
}

fn commandError(e: anyerror, client: *const kwinctl.Client) []const u8 {
    return switch (e) {
        error.InvalidId => "not a window id (expected a UUID like {04add7fb-72b8-4e58-8ac1-5e22730b907b})",
        error.WindowNotFound => "no window with that id",
        error.ScriptTooLarge => "script is larger than 1 MiB",
        error.CannotReadScript => "cannot read the script file",
        else => if (client.lastError().len > 0) client.lastError() else @errorName(e),
    };
}

test "commands are found by name and argument count" {
    try std.testing.expectEqualStrings("move", findCommand(&.{ "move", "ID", "1", "2", "3", "4" }).?.name);
    try std.testing.expect(findCommand(&.{ "move", "ID" }) == null);
    try std.testing.expect(findCommand(&.{"bogus"}) == null);
    try std.testing.expect(findCommand(&.{}) == null);
}

test "options are parsed anywhere on the command line" {
    const a = std.testing.allocator;
    var args = try parseArgs(a, &.{ "list", "--json", "--timeout", "250", "--all" });
    defer args.deinit(a);
    try std.testing.expect(args.json);
    try std.testing.expectEqual(@as(u32, 250), args.timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), args.words.items.len);
    try std.testing.expectError(error.BadTimeout, parseArgs(a, &.{ "list", "--timeout", "soon" }));
}

test "rects need four numbers and a positive size" {
    try std.testing.expectEqual(kwinctl.Rect{ .x = -5, .y = 0, .width = 800, .height = 600 }, try parseRect(&.{ "-5", "0", "800", "600" }));
    try std.testing.expectError(error.Usage, parseRect(&.{ "0", "0", "0", "600" }));
    try std.testing.expectError(error.Usage, parseRect(&.{ "0", "0", "wide", "600" }));
}
