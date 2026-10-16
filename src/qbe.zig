const std = @import("std");

extern fn qbe_set_target(name: [*c]const u8) c_int;
extern fn qbe_compile(
    ssa_text: [*c]const u8,
    ssa_len: usize,
    out_asm: *[*c]u8,
    out_len: *usize,
) c_int;

pub const Target = enum {
    amd64_sysv,
    amd64_apple,
    amd64_win,
    arm64,
    arm64_apple,
    rv64,
};

pub fn compile(allocator: std.mem.Allocator, ssa_text: [:0]const u8, target: Target) ![]u8 {
    const target_name: [:0]const u8 = @tagName(target);
    if (qbe_set_target(target_name.ptr) != 0) {
        return error.UnknownTarget;
    }

    var out_ptr: [*c]u8 = null;
    var out_len: usize = 0;
    const rc = qbe_compile(ssa_text.ptr, ssa_text.len, &out_ptr, &out_len);
    if (rc != 0) {
        return error.CompileFailed;
    }

    const result = try allocator.dupe(u8, out_ptr[0..out_len]);
    std.c.free(out_ptr);
    return result;
}
