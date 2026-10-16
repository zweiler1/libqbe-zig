const std = @import("std");
const qbe = @import("qbe.zig");

pub const compile = qbe.compile;

pub const ir = @import("ir.zig");

test "hello world" {
    const output = try qbe.compile(std.testing.allocator,
        \\data $str = { b "hello world", b 0 }
        \\
        \\export function w $main() {
        \\@start
        \\        %r =w call $puts(l $str)
        \\        ret 0
        \\}
    , .amd64_sysv);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        ".data\n" ++
            ".balign 8\n" ++
            "str:\n" ++
            "\t.ascii \"hello world\"\n" ++
            "\t.byte 0\n" ++
            "/* end data */\n" ++
            "\n" ++
            ".text\n" ++
            ".balign 16\n" ++
            ".globl main\n" ++
            "main:\n" ++
            "\tendbr64\n" ++
            "\tpushq %rbp\n" ++
            "\tmovq %rsp, %rbp\n" ++
            "\tleaq str(%rip), %rdi\n" ++
            "\tcallq puts\n" ++
            "\tmovl $0, %eax\n" ++
            "\tleave\n" ++
            "\tret\n" ++
            ".type main, @function\n" ++
            ".size main, .-main\n" ++
            "/* end function main */\n" ++
            "\n" ++
            ".section .note.GNU-stack,\"\",@progbits\n",
        output,
    );
}
