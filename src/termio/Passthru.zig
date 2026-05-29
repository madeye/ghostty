//! Passthru implements a termio backend that owns no subprocess and no pty.
//!
//! Instead of reading/writing a local pty, the embedder provides the IO:
//!
//!   * Incoming data (what would normally be read from the pty) is injected by
//!     the embedder by calling `Termio.processOutput` (exposed via the C API
//!     `ghostty_surface_pty_data`). This is the exact same ingress the exec
//!     backend's read thread uses.
//!
//!   * Outgoing data (keyboard input, terminal query responses, etc.) flows
//!     through `Termio.queueWrite` -> `Backend.queueWrite` -> here, where we
//!     hand the bytes to an embedder-provided callback instead of writing them
//!     to a pty fd. `queueWrite` is the single chokepoint for all terminal ->
//!     pty writes, so this captures everything.
//!
//!   * Resizes are reported to the embedder via a callback so the remote end
//!     can be notified (e.g. an SSH window-change request).
//!
//! This is what allows libghostty to be driven by a network transport such as
//! an SSH connection (e.g. on iOS where fork/exec is unavailable).
const Passthru = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_passthru);

/// Callback invoked with bytes the terminal wants to send to the "pty"
/// (keyboard input, query responses, clipboard, etc.). The embedder forwards
/// these to its transport. Invoked on the termio (IO) thread; it MUST NOT
/// block (e.g. hop to your network event loop instead of doing sync IO).
pub const WriteFn = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;

/// Callback invoked when the terminal is resized so the embedder can notify
/// the remote (e.g. SSH window-change). Args: userdata, columns, rows,
/// width_px, height_px. May be invoked during surface init (before the
/// embedder's transport is ready), so the embedder should tolerate that.
pub const ResizeFn = *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void;

pub const Config = struct {
    /// Opaque userdata passed to the callbacks. Typically the surface
    /// userdata so the embedder can recover its own object.
    userdata: ?*anyopaque = null,

    /// Invoked with outgoing terminal bytes. If null, outgoing data is
    /// silently dropped.
    write_cb: ?WriteFn = null,

    /// Invoked on resize. If null, resizes are not reported.
    resize_cb: ?ResizeFn = null,
};

userdata: ?*anyopaque,
write_cb: ?WriteFn,
resize_cb: ?ResizeFn,

/// Last reported size, cached for completeness/debugging.
grid_size: renderer.GridSize = .{},
screen_size: renderer.ScreenSize = .{ .width = 0, .height = 0 },

pub fn init(alloc: Allocator, cfg: Config) !Passthru {
    _ = alloc;
    return .{
        .userdata = cfg.userdata,
        .write_cb = cfg.write_cb,
        .resize_cb = cfg.resize_cb,
    };
}

pub fn deinit(self: *Passthru) void {
    _ = self;
}

/// Set up the initial terminal state. Mirrors Exec: report the initial size.
pub fn initTerminal(self: *Passthru, term: *terminal.Terminal) void {
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Passthru,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;

    // No read thread, no pty, no process. We just need backend thread data.
    td.backend = .{ .passthru = .{} };
}

pub fn threadExit(self: *Passthru, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *Passthru,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Passthru,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;
    if (self.resize_cb) |cb| {
        cb(
            self.userdata,
            @intCast(grid_size.columns),
            @intCast(grid_size.rows),
            screen_size.width,
            screen_size.height,
        );
    }
}

pub fn queueWrite(
    self: *Passthru,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;

    const cb = self.write_cb orelse return;
    if (data.len == 0) return;

    // Fast path: no linefeed translation requested.
    if (!linefeed) {
        cb(self.userdata, data.ptr, data.len);
        return;
    }

    // Linefeed mode (terminal mode 20, LNM): translate each '\r' to "\r\n",
    // matching the exec backend's behavior so writes are identical regardless
    // of backend.
    var count: usize = 0;
    for (data) |ch| {
        if (ch == '\r') count += 1;
    }
    if (count == 0) {
        cb(self.userdata, data.ptr, data.len);
        return;
    }

    const buf = try alloc.alloc(u8, data.len + count);
    defer alloc.free(buf);
    var j: usize = 0;
    for (data) |ch| {
        buf[j] = ch;
        j += 1;
        if (ch == '\r') {
            buf[j] = '\n';
            j += 1;
        }
    }
    cb(self.userdata, buf.ptr, j);
}

pub fn childExitedAbnormally(
    self: *Passthru,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(
    self: *Passthru,
    comptime info: ProcessInfo,
) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

/// The thread local data for the passthru backend. There is no pty or
/// process, so this is empty.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

const TestCtx = struct {
    out: std.ArrayList(u8) = .{},
    cols: u16 = 0,
    rows: u16 = 0,
    width: u32 = 0,
    height: u32 = 0,

    fn onWrite(ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
        const self: *TestCtx = @ptrCast(@alignCast(ud.?));
        self.out.appendSlice(testing.allocator, ptr[0..len]) catch unreachable;
    }

    fn onResize(ud: ?*anyopaque, cols: u16, rows: u16, w: u32, h: u32) callconv(.c) void {
        const self: *TestCtx = @ptrCast(@alignCast(ud.?));
        self.cols = cols;
        self.rows = rows;
        self.width = w;
        self.height = h;
    }
};

test "queueWrite forwards bytes verbatim" {
    var ctx: TestCtx = .{};
    defer ctx.out.deinit(testing.allocator);

    var pt = try Passthru.init(testing.allocator, .{
        .userdata = &ctx,
        .write_cb = TestCtx.onWrite,
    });
    defer pt.deinit();

    try pt.queueWrite(testing.allocator, undefined, "hello world", false);
    try testing.expectEqualStrings("hello world", ctx.out.items);
}

test "queueWrite translates CR to CRLF in linefeed mode" {
    var ctx: TestCtx = .{};
    defer ctx.out.deinit(testing.allocator);

    var pt = try Passthru.init(testing.allocator, .{
        .userdata = &ctx,
        .write_cb = TestCtx.onWrite,
    });
    defer pt.deinit();

    try pt.queueWrite(testing.allocator, undefined, "a\rb\r", true);
    try testing.expectEqualStrings("a\r\nb\r\n", ctx.out.items);
}

test "queueWrite with no callback is a no-op" {
    var pt = try Passthru.init(testing.allocator, .{});
    defer pt.deinit();
    try pt.queueWrite(testing.allocator, undefined, "ignored", false);
}

test "resize reports size to callback" {
    var ctx: TestCtx = .{};
    defer ctx.out.deinit(testing.allocator);

    var pt = try Passthru.init(testing.allocator, .{
        .userdata = &ctx,
        .resize_cb = TestCtx.onResize,
    });
    defer pt.deinit();

    try pt.resize(
        .{ .columns = 120, .rows = 40 },
        .{ .width = 1200, .height = 800 },
    );
    try testing.expectEqual(@as(u16, 120), ctx.cols);
    try testing.expectEqual(@as(u16, 40), ctx.rows);
    try testing.expectEqual(@as(u32, 1200), ctx.width);
    try testing.expectEqual(@as(u32, 800), ctx.height);
}
