# Zig 数组与切片 (Array vs Slice) 学习指南

## 1. 核心区别

在 Zig 中：**数组是数据容器，切片是数据视图。**

| 维度 | 数组 `[N]T` | 切片 `[]T` |
|:---|:---|:---|
| **长度** | **Comptime 常量**：`N` 是类型的一部分 | **Runtime 值**：`len` 是结构体成员，运行期确定 |
| **底层结构** | 连续存放 `N` 个元素 | **胖指针**：`{ ptr: [*]T, len: usize }` (固定 16 字节) |
| **内存所有权** | 拥有并包含实际数据 | **不拥有数据**，只指向某块连续内存的一段 |
| **复制代价** | 拷贝整个数组 ($O(N)$) | 只拷 ptr + len ($O(1)$) |
| **类型等价性** | `[4]u8` 和 `[5]u8` 是**不同**类型 | `[]u8` 只有一种，长度不改变类型 |

---

## 2. Comptime 长度 vs Runtime 长度

### 数组长度 `.len`
它是编译期常量，**不占用任何运行期内存字节**。
```zig
var buf: [24]u8 = undefined;
const L = buf.len; // L 在编译期就是 24，相当于字面量

// 证明：只有 comptime 已知的值才能用于 switch case
comptime {
    switch (buf.len) {
        24 => {}, // 匹配成功
        else => unreachable,
    }
}
```

### 切片长度 `.len`
它是运行期值，存在切片的结构体内部。

```zig
// 切片底层结构 (简化)
pub const Slice = struct {
    ptr: [*]T, // 8 bytes
    len: usize // 8 bytes (Runtime)
};

// 如果尝试把切片长度用在 switch case：
const s = buf[0..5];
// switch (s.len) { ... } // ERROR: 非 compile-time 已知值
```

---

## 3. Implicit Coercion (隐式强制转换)

Zig API 通常只接受切片 (`[]T`)，但你经常可以传入数组 (`&arr`)。这是因为 Zig 的**安全自动转换规则**：

> 如果从类型 A 转到类型 B 绝对安全且不丢失关键信息，则自动转换。

### 典型场景
```zig
// API 声明为切片
fn process(data: []const u8) void { ... }

const arr: [10]u8 = .{0} ** 10;
process(&arr);            // ✅ 数组指针 -> 切片 (编译器自动将 10 填入 len)

process("Hello");         // ✅ 字符串字面量 (*const [5:0]u8) -> 切片

process(slice_arg);       // ✅ 切片 -> 切片 (零拷贝)
```

### 转换层级
`*[N]T` (指向定长数组) `->`  `[]T` (切片) `->`  `[*]T` (C指针)

*   **❌ 禁止**: C指针 (`[*]T`) 不能自动转切片，因为没有长度信息，必须显式 `ptr[0..len]`。

---

## 4. Demo 代码

以下代码演示了上述所有概念：

```zig
// source: demo_coercion.zig
const std = @import("std");

// 这个函数只认识切片，不认识数组
fn process(data: []const u8) void {
    std.debug.print("Data: '{s}', Len: {d}\n", .{ data, data.len });
}

pub fn main() void {
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
```