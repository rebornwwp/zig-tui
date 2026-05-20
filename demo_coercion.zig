const std = @import("std");

// 这个函数只认识切片，不认识数组
fn process(data: []const u8) void {
    std.debug.print("Data: '{s}', Len: {d}\n", .{ data, data.len });
}

pub fn main() void {
    // ==========================================
    // 1. 测试数组 -> 切片
    // ==========================================
    const arr: [5]u8 = .{ 'H', 'e', 'l', 'l', 'o' };

    // 验证：数组长度是 comptime 已知的。
    // @compileLog("Arr len (comptime): ", arr.len); // 取消注释可在编译期查看日志（会阻断编译）
    comptime {
        // 证明 arr.len 是 comptime 的：
        const L = arr.len;
        switch (L) {
            1 => {},
            5 => {}, // 必须精确匹配编译期常量才能通过 switch
            else => unreachable,
        }
    }
    // 如果下面这行能编译，说明 arr.len 在编译期就被替换成了字面量 5
    // const arr_ptr: *const [5]u8 = &arr; 

    std.debug.print("\n--- 调用 1: 传入 &arr (数组) ---\n", .{});
    process(&arr); // 自动隐式转换 &arr -> []const u8

    // ==========================================
    // 2. 测试字符串字面量 -> 切片
    // ==========================================
    std.debug.print("\n--- 调用 2: 传入 \"Hello World\" (字面量) ---\n", .{});
    process("Hello World"); // 字面量 *const [12:0]u8 自动转切片

    // ==========================================
    // 3. 测试切片 -> 切片
    // ==========================================
    std.debug.print("\n--- 调用 3: 传入子切片 ---\n", .{});
    const sentence = "Hello Zig World";
    process(sentence[6..9]); // "Zig" (切片转切片，零拷贝)
}
