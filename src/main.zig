const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

const MAX_EVENTS = 8;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    // 初始化 TTY
    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();

    // 初始化 Vaxis
    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    // 创建事件循环
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    // 进入备用屏幕模式
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    // 打开事件日志文件
    var log_buf: [0]u8 = undefined;
    var log_file = try std.Io.Dir.createFileAbsolute(io, "/tmp/vaxis_events.log", .{ .read = true, .truncate = true });
    defer log_file.close(io);
    var log_writer = log_file.writerStreaming(io, &log_buf);

    // 事件环形缓冲区（用于屏幕实时显示）
    var events: [MAX_EVENTS][128]u8 = undefined;
    var event_count: usize = 0;

    var clock_color_idx: u8 = 0;

    // 主事件循环
    while (true) {
        // 非阻塞取事件，没事件时跳过
        if (try loop.tryEvent()) |ev| {
            var quit = false;

            var msg_buf: [128]u8 = undefined;
            const msg: []const u8 = switch (ev) {
                .key_press => |key| blk: {
                    if (key.codepoint == 'q' or (key.codepoint == 'c' and key.mods.ctrl)) {
                        quit = true;
                        break :blk "KEY  q/Ctrl+C -> quit";
                    }
                    clock_color_idx = switch (clock_color_idx) {
                        255 => 0,
                        else => clock_color_idx + 1,
                    };
                    break :blk try std.fmt.bufPrint(&msg_buf, "KEY  U+{X:0>4} shift={} alt={} ctrl={} super={}", .{
                        key.codepoint,
                        key.mods.shift,
                        key.mods.alt,
                        key.mods.ctrl,
                        key.mods.super,
                    });
                },
                .winsize => |ws| blk: {
                    try vx.resize(alloc, tty.writer(), ws);
                    break :blk try std.fmt.bufPrint(&msg_buf, "WIN  {d}x{d} (px:{d}x{d})", .{
                        ws.rows, ws.cols, ws.x_pixel, ws.y_pixel,
                    });
                },
                .mouse_event => |mouse| try std.fmt.bufPrint(&msg_buf, "MS   {s} ({d},{d}) btn={s} shift={} alt={} ctrl={}", .{
                    @tagName(mouse.type),
                    mouse.col,
                    mouse.row,
                    @tagName(mouse.button),
                    mouse.mods.shift,
                    mouse.mods.alt,
                    mouse.mods.ctrl,
                }),
                .paste_begin => "PASTE begin",
                .paste_end => "PASTE end",
                .paste_data => |data| try std.fmt.bufPrint(&msg_buf, "PASTE {d} bytes", .{data.len}),
                .focus_in => "FOCUS gained",
                .focus_out => "FOCUS lost",
                .quit => blk: {
                    quit = true;
                    break :blk "QUIT";
                },
            };

            log_writer.interface.writeAll(msg) catch {};
            log_writer.interface.writeAll("\n") catch {};
            appendEvent(&events, &event_count, msg);

            if (quit) break;
        }

        // 获取当前时间并格式化 (yyyy-MM-DD: H:MM:SS)
        const clock = std.Io.Clock.real;
        const instant = std.Io.Clock.now(clock, io);
        const total_seconds: i64 = @intCast(@divTrunc(instant.nanoseconds, std.time.ns_per_s));

        // 计算日期
        const epoch_days: i64 = @divTrunc(total_seconds, 86400);
        var y: i64 = 1970;
        var d_rem = epoch_days;

        while (true) {
            const diy: i64 = if ((@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0) 366 else 365;
            if (d_rem < diy) break;
            d_rem -= diy;
            y += 1;
        }

        const is_leap = (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
        const mdays = [_]u8{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var m: u8 = 1;
        var dr = @as(u16, @intCast(d_rem));
        while (m <= 12 and dr >= mdays[m - 1]) {
            dr -= mdays[m - 1];
            m += 1;
        }
        const d: u8 = @intCast(dr + 1);

        // 计算时间
        const sec_today = @mod(total_seconds, 86400);
        const h: u8 = @intCast(@divTrunc(sec_today, 3600));
        const mi: u8 = @intCast(@mod(@divTrunc(sec_today, 60), 60));
        const s: u8 = @intCast(@mod(sec_today, 60));

        const time_str = try std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}: {d:0>2}:{d:0>2}:{d:0>2}", .{
            @as(u16, @intCast(y)), m, d, h, mi, s,
        });
        defer alloc.free(time_str);

        // 获取根窗口并清空
        const win = vx.window();
        win.clear();

        // 绘制事件日志（底部区域）
        drawEventLog(&win, &events, event_count, clock_color_idx);

        // 计算居中位置
        const msg_len: i16 = @intCast(time_str.len);
        const win_width: i16 = @intCast(win.width);
        const win_height: i16 = @intCast(win.height);
        const x_off: i16 = @divTrunc(win_width, 2) - @divTrunc(msg_len, 2);
        const y_off: u16 = @intCast(@divTrunc(win_height, 2));

        // 创建子窗口并绘制时间
        const child = win.child(.{ .x_off = x_off, .y_off = y_off });

        for (time_str, 0..) |_, i| {
            const cell: Cell = .{
                .char = .{ .grapheme = time_str[i .. i + 1] },
                .style = .{
                    .fg = .{ .index = clock_color_idx },
                },
            };
            child.writeCell(@intCast(i), 0, cell);
        }

        // 渲染屏幕
        try vx.render(tty.writer());

        // 短暂休眠避免 CPU 占用过高 (~60fps)
        try std.Io.sleep(io, .{ .nanoseconds = 16 * std.time.ns_per_ms }, .real);
    }
}

// 向环形缓冲区追加一条事件消息
fn appendEvent(events: *[MAX_EVENTS][128]u8, count: *usize, msg: []const u8) void {
    const len = @min(msg.len, 127);
    if (count.* < MAX_EVENTS) {
        @memcpy(events[count.*][0..len], msg[0..len]);
        events[count.*][len] = 0;
        count.* += 1;
    } else {
        // 满了，整体左移一位
        for (0..MAX_EVENTS - 1) |i| {
            events[i] = events[i + 1];
        }
        @memcpy(events[MAX_EVENTS - 1][0..len], msg[0..len]);
        events[MAX_EVENTS - 1][len] = 0;
    }
}

// 在窗口底部绘制事件日志
fn drawEventLog(win: *const vaxis.Window, events: *const [MAX_EVENTS][128]u8, count: usize, clock_color_idx: u8) void {
    if (count == 0) return;

    const w = win.width;
    const h: u16 = win.height;
    const n: u16 = @intCast(count);
    const needed: u16 = n + 1;
    if (h < needed) return;

    const base_y: u16 = h - needed;

    // 分隔线
    const sep_child = win.child(.{ .y_off = base_y });
    const sep_cell: Cell = .{ .char = .{ .grapheme = "─" }, .style = .{ .fg = .{ .index = 8 } } };
    for (0..@as(usize, @intCast(w))) |x| {
        sep_child.writeCell(@intCast(x), 0, sep_cell);
    }

    // 逐行绘制事件（最旧在上，最新在下）
    for (0..count) |i| {
        const msg = std.mem.sliceTo(&events[i], 0);
        const y: u16 = base_y + 1 + @as(u16, @intCast(i));
        const child = win.child(.{ .y_off = y });
        const fg: u8 = if (i == count - 1) clock_color_idx else 8;
        const max_len = @min(msg.len, @as(usize, @intCast(w)));
        for (0..max_len) |x| {
            const cell: Cell = .{
                .char = .{ .grapheme = msg[x .. x + 1] },
                .style = .{ .fg = .{ .index = fg } },
            };
            child.writeCell(@intCast(x), 0, cell);
        }
    }
}

// 事件枚举，包含 vaxis 发送的事件类型
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    mouse_event: vaxis.Mouse,
    paste_begin: void,
    paste_end: void,
    paste_data: []const u8,
    focus_in: void,
    focus_out: void,
    quit: void,
};
