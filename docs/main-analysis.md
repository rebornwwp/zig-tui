# `main.zig` 代码解析

基于 Vaxis（Zig 终端 UI 库）的 TUI 时钟应用，在终端中央显示带渐变色彩的时间字符串。

## 完整代码

```zig
const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

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

    var color_idx: u8 = 0;

    // 主事件循环
    while (true) {
        const event = try loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'q' or (key.codepoint == 'c' and key.mods.ctrl)) {
                    break;
                }
                color_idx = switch (color_idx) {
                    255 => 0,
                    else => color_idx + 1,
                };
            },
            .winsize => |ws| {
                try vx.resize(alloc, tty.writer(), ws);
            },
            else => {},
        }

        // 获取当前时间并格式化
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
                    .fg = .{ .index = color_idx },
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
```

---

## 函数签名

```zig
pub fn main(init: std.process.Init) !void {
```

Zig 0.14+ 的新风格 main 签名。`std.process.Init` 是一个结构体，把传统分开传的资源（`std.io.getStdOut()`、`std.heap.page_allocator` 等）打包成一个参数。

- `!void` 表示可能返回错误，错误会被 Zig 运行时捕获并打印。

---

## 解构初始化参数

```zig
const io = init.io;
const alloc = init.gpa;
```

`init` 结构体包含：

| 字段 | 类型 | 用途 |
|------|------|------|
| `io` | IO 抽象 | 包含 stdin/stdout/stderr 的 reader/writer |
| `gpa` | 内存分配器 | 通用内存分配器（General Purpose Allocator） |

这种做法替代了手写 `var gpa = std.heap.GeneralPurposeAllocator(.{}){}` 的模板代码。Zig 0.14+ 让运行时帮我们初始化这些，main 只管用。

---

## TTY 初始化

```zig
var buffer: [1024]u8 = undefined;
var tty = try vaxis.Tty.init(io, &buffer);
defer tty.deinit();
```

- `buffer` 是 TTY 的内部读写缓冲，栈上分配 1KB。`undefined` 表示不初始化（`Tty.init` 会写入）。
- `vaxis.Tty.init` 将终端设为 raw mode：关闭行缓冲、禁用回显、禁用信号处理等。只有这样才能逐键读取。
- **`defer tty.deinit()`**：确保函数退出时恢复终端原始设置，即使因错误提前退出也会执行。这是 Zig 最重要的资源管理机制。

---

## Vaxis 初始化

```zig
var vx = try vaxis.init(io, alloc, init.environ_map, .{});
defer vx.deinit(alloc, tty.writer());
```

Vaxis 是 TUI 框架，管理窗口树、样式、事件分发。

参数说明：

| 参数 | 用途 |
|------|------|
| `io` | 输入输出 |
| `alloc` | 用于动态分配窗口树等数据 |
| `init.environ_map` | 环境变量（Vaxis 需要读 `TERM` 等确定终端能力） |
| `.{}` | 配置选项，这里使用默认值 |

`defer vx.deinit(...)` 需要两个参数：
- `alloc`：释放窗口树等动态分配的内存
- `tty.writer()`：发送终端重置序列（如显示光标）

---

## 事件循环

```zig
var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
try loop.start();
defer loop.stop();
```

- `vaxis.Loop(Event)` 是泛型事件循环，`Event` 是自定义的事件枚举（定义在文件末尾）。
- `.init(...)` 接收 IO、TTY 和 Vaxis 实例，内部会启动一个**独立线程**来监听 stdin 和终端信号。
- `try loop.start()` 启动监听线程。
- `defer loop.stop()` 退出时停止线程并等待 join。

---

## 进入备用屏幕

```zig
try vx.enterAltScreen(tty.writer());
try vx.queryTerminal(tty.writer(), .fromSeconds(1));
```

- **`enterAltScreen`**：终端切换到"备用缓冲区"——退出应用后终端内容原样恢复，不会留下 TUI 的残影。这是 TUI 程序的标配操作。
- **`queryTerminal`**：向终端发送查询序列（如支持多少色、是否支持 true color），等 1 秒超时。Vaxis 根据终端能力调整渲染策略。比如不支持 256 色的终端会降级到 16 色。

---

## 主事件循环

```zig
while (true) {
    const event = try loop.nextEvent();
    ...
}
```

### 事件处理

```zig
switch (event) {
    .key_press => |key| {
        if (key.codepoint == 'q' or (key.codepoint == 'c' and key.mods.ctrl)) {
            break;
        }
        color_idx = switch (color_idx) {
            255 => 0,
            else => color_idx + 1,
        };
    },
    .winsize => |ws| {
        try vx.resize(alloc, tty.writer(), ws);
    },
    else => {},
}
```

**事件获取**：`loop.nextEvent()` 阻塞等待事件（来自后台监听线程的内部 channel）。这是一个异步边界——主线程和监听线程通过 channel 通信，是 CSP 并发模型的经典用法。

**键事件** `.key_press`：
- 按 `q` 或 `Ctrl+C`：`break` 跳出 `while(true)`，触发所有 `defer` 做清理，然后退出。
- 其他任意键：`color_idx` 递增（0→255→0 循环）。每次按键颜色切换一个色板索引，产生颜色在时间字符串上整体流动的视觉效果。

**窗口大小事件** `.winsize`：
- 终端窗口大小变化时，通知 Vaxis 重新计算窗口树尺寸。`vx.resize` 会更新所有子窗口的宽高。

**其他事件**：`else => {}` 忽略鼠标、粘贴等事件。

---

## 手动计算日期时间

```zig
const clock = std.Io.Clock.real;
const instant = std.Io.Clock.now(clock, io);
const total_seconds: i64 = @intCast(@divTrunc(instant.nanoseconds, std.time.ns_per_s));
```

这里没有用 libc 的 `localtime`/`gmtime`，而是从 Unix 纪元秒数**纯数学推算**年-月-日-时-分-秒。

### 为什么这样做？

1. **不依赖 libc**：Zig 可以独立于 C 运行时工作。
2. **确定性和可移植性**：不涉及时区数据库、locale 等平台差异。
3. **教学价值**：展示了 Zig 中对闰年、月份天数的手工处理。

### 年份推算

```zig
const epoch_days: i64 = @divTrunc(total_seconds, 86400);
var y: i64 = 1970;
var d_rem = epoch_days;

while (true) {
    const diy: i64 = if ((@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0) 366 else 365;
    if (d_rem < diy) break;
    d_rem -= diy;
    y += 1;
}
```

- `86400` = 一天秒数。
- 从 1970 年开始，每年减去对应的天数（365 或 366），直到剩余天数不够一整年。
- 闰年规则：`(y % 4 == 0 && y % 100 != 0) || y % 400 == 0`，这是格里高利历的精确定义。

### 月份推算

```zig
const mdays = [_]u8{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
var m: u8 = 1;
var dr = @as(u16, @intCast(d_rem));
while (m <= 12 and dr >= mdays[m - 1]) {
    dr -= mdays[m - 1];
    m += 1;
}
const d: u8 = @intCast(dr + 1);
```

- 编译时根据是否闰年选择 2 月的天数：`if (is_leap) 29 else 28`。
- 逐月减去天数，剩余的就是当月日期（+1 是因为日期从 1 开始）。

### 时间推算

```zig
const sec_today = @mod(total_seconds, 86400);
const h: u8 = @intCast(@divTrunc(sec_today, 3600));
const mi: u8 = @intCast(@mod(@divTrunc(sec_today, 60), 60));
const s: u8 = @intCast(@mod(sec_today, 60));
```

- `sec_today`：当天 0 点以来的秒数。
- 小时 = `sec_today / 3600`
- 分钟 = `(sec_today / 60) % 60`
- 秒 = `sec_today % 60`

---

## 格式化字符串

```zig
const time_str = try std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}: {d:0>2}:{d:0>2}:{d:0>2}", .{
    @as(u16, @intCast(y)), m, d, h, mi, s,
});
defer alloc.free(time_str);
```

- `allocPrint` 在堆上分配格式化后的字符串，结果如 `2026-05-15: 14:30:25`。
- 格式说明符：
  - `{d:0>4}`：十进制整数，右对齐，宽度 4，零填充。年份 `2026` 始终 4 位。
  - `{d:0>2}`：同逻辑，宽度 2，零填充。月和日始终 2 位（`05` 而非 `5`）。
- `defer alloc.free(time_str)` 确保释放堆内存。**分配与释放配对写在一起**，是 Zig 避免内存泄漏的核心模式。

---

## 窗口和居中渲染

```zig
const win = vx.window();
win.clear();

const msg_len: i16 = @intCast(time_str.len);
const win_width: i16 = @intCast(win.width);
const win_height: i16 = @intCast(win.height);
const x_off: i16 = @divTrunc(win_width, 2) - @divTrunc(msg_len, 2);
const y_off: u16 = @intCast(@divTrunc(win_height, 2));

const child = win.child(.{ .x_off = x_off, .y_off = y_off });
```

- **`vx.window()`**：获取根窗口，其大小等于终端尺寸。
- **`win.clear()`**：清空所有单元格，清除上一帧的内容。这是帧渲染的必要步骤。
- **居中算法**：
  - X 偏移 = `(终端宽度 / 2) - (字符串长度 / 2)`
  - Y 偏移 = `终端高度 / 2`
- **`win.child(...)`**：创建子窗口。子窗口的坐标 (0,0) 是相对于偏移量的，方便绘制时使用局部坐标。
- Vaxis 的窗口是**树状结构**——根窗口可以不断切分出子窗口，子窗口还可以再切分。这里只用了一层。

---

## 逐字符绘制

```zig
for (time_str, 0..) |_, i| {
    const cell: Cell = .{
        .char = .{ .grapheme = time_str[i .. i + 1] },
        .style = .{
            .fg = .{ .index = color_idx },
        },
    };
    child.writeCell(@intCast(i), 0, cell);
}
```

- 每个字符单独创建一个 `Cell`（Vaxis 的单元格类型）。
- `Cell` 结构：
  - `char.grapheme`：要显示的字符（UTF-8 切片）。
  - `style.fg.index`：前景色索引，0-255 对应 256 色调色板。
- `writeCell(x, y, cell)`：将 cell 写入子窗口指定位置。
- 所有字符共用同一个 `color_idx`，整个时间字符串是同一个颜色，按键后整体切换。

> 注意：`time_str[i .. i + 1]` 是按字节切片。这里时间字符串是纯 ASCII，所以安全。如果处理多字节 UTF-8 字符（如中文），需要使用 `unicode.Utf8View` 迭代。

---

## 渲染与帧率控制

```zig
try vx.render(tty.writer());
try std.Io.sleep(io, .{ .nanoseconds = 16 * std.time.ns_per_ms }, .real);
```

- **`vx.render(tty.writer())`**：把窗口树中所有 cell 的状态序列化为 ANSI 转义序列写入 TTY。VGaxis 做了脏区域优化——只重绘变化的 cell。
- **`sleep(16ms)`** ≈ 60fps。没有这个 sleep 的话，`while(true)` 空转会**100% 占满一个 CPU 核心**。即使屏幕上没变化，每秒也是 60 次渲染循环。

---

## 事件枚举

```zig
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
```

这是 Zig 的 **tagged union**（带标签的联合体），等同于其他语言中的枚举 + 关联值。

- `vaxis.Loop(Event)` 使用这个枚举来反序列化来自监听线程的事件。
- 每个事件类型可以携带不同的载荷类型：
  - `.key_press` 携带 `vaxis.Key`
  - `.winsize` 携带 `vaxis.Winsize`
  - `.mouse_event` 携带 `vaxis.Mouse`
  - 其余事件无载荷（`void`）
- 当前 `main` 只处理了 `.key_press` 和 `.winsize`，其余被 `else => {}` 忽略。

---

## 架构总结

```
┌─────────────────────────────────────────────┐
│                  main()                      │
│  init → TTY → Vaxis → Loop → EventLoop      │
│          │       │        │                  │
│          │ raw   │ window │ background       │
│          │ mode  │ tree   │ thread           │
│          ▼       ▼        │                  │
│  ┌──────────┐ ┌──────┐   │                  │
│  │stdin/out │ │Cell[]│   │                  │
│  └──────────┘ └──────┘   │                  │
│                    ▲       ▼                  │
│              render()  events (channel)       │
│                    │       │                  │
│              tty.writer   loop.nextEvent()    │
└─────────────────────────────────────────────┘
```

| 组件 | 职责 |
|------|------|
| `Tty` | 管理终端 raw mode、读写缓冲 |
| `Vaxis` | 窗口树、样式、渲染引擎 |
| `Loop(Event)` | 后台线程监听 stdin + 事件分发 |
| `Cell` | 单元格：字符 + 样式 |
| `main` | 编排上述组件，实现业务逻辑 |

### 设计要点

1. **defer 链式清理**：每个资源初始化后紧跟 `defer`，保证即使 panic 也能恢复终端状态
2. **单线程事件 + 后台监听线程**：主线程处理渲染，监听线程处理输入，通过 channel 通信
3. **纯计算无 libc**：日期时间是纯 Zig 数学，不依赖系统调用
4. **Vaxis 窗口树**：居中、子窗口、逐 cell 绘制都是 Vaxis 的标准模式
5. **帧率控制**：16ms sleep 保证 60fps 且不空转 CPU