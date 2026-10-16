//! Small demonstration of the handle based `Builder`.
//!
//! The program constructs a recursive Fibonacci function (plus a `main` that
//! calls it) entirely in memory, writes the generated QBE IL to `output.ssa`
//! and lowers it to amd64 assembly in `output.s` through the embedded backend.
//!
//! It exercises parameters, integer literals, signed comparison, conditional
//! branches, recursive calls, arithmetic and returns.

const std = @import("std");
const lib = @import("lib");

const Builder = lib.Builder;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var builder = Builder.init(gpa);
    defer builder.deinit();

    // export function w $fib(w %n) {
    const fib = try builder.createFunction(.public(), "fib", &.{
        .{ .ty = .word, .name = "n" },
    }, .word);

    const start = try builder.createBlock(fib, "start");
    const base = try builder.createBlock(fib, "base");
    const recurse = try builder.createBlock(fib, "recurse");

    const n = try builder.getParam(fib, 0);

    // @start
    //     %t0 =w csltw %n, 2
    //     jnz %t0, @base, @recurse
    try builder.setInsertPoint(start);
    const is_base = try builder.compare(.slt, n, try builder.intConst(.word, 2));
    try builder.jnz(is_base, base, recurse);

    // @base
    //     ret %n
    try builder.setInsertPoint(base);
    try builder.ret(n);

    // @recurse
    //     %t1 =w sub %n, 1
    //     %t2 =w call $fib(w %t1)
    //     %t3 =w sub %n, 2
    //     %t4 =w call $fib(w %t3)
    //     %t5 =w add %t2, %t4
    //     ret %t5
    try builder.setInsertPoint(recurse);
    const n_minus_1 = try builder.sub(n, try builder.intConst(.word, 1));
    const a = (try builder.call("fib", .word, &.{
        .{ .ty = .word, .val = n_minus_1 },
    }, null)).?;
    const n_minus_2 = try builder.sub(n, try builder.intConst(.word, 2));
    const b = (try builder.call("fib", .word, &.{
        .{ .ty = .word, .val = n_minus_2 },
    }, null)).?;
    try builder.ret(try builder.add(a, b));

    // export function w $main() {
    // @entry
    //     %t0 =w call $fib(w 10)
    //     ret %t0
    // }
    const main_fn = try builder.createFunction(.public(), "main", &.{}, .word);
    _ = try builder.createBlock(main_fn, "entry");
    const ten = try builder.intConst(.word, 10);
    const result = (try builder.call("fib", .word, &.{
        .{ .ty = .word, .val = ten },
    }, null)).?;
    try builder.ret(result);

    // Dump the IL so the result can be inspected, then lower it.
    const text = try builder.toText(gpa);
    defer gpa.free(text);
    std.debug.print("--- generated QBE IL ---\n{s}", .{text});

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "output.ssa",
        .data = text,
    });

    const asm_text = try builder.compile(gpa, .amd64_sysv);
    defer gpa.free(asm_text);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "output.s",
        .data = asm_text,
    });

    std.debug.print("wrote output.ssa and output.s\n", .{});
}
