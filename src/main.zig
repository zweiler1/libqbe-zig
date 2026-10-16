const std = @import("std");
const qbe = @import("qbe");

pub fn main(init: std.process.Init) !void {
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, "input.ssa", init.gpa, .unlimited);
    defer init.gpa.free(input);

    const output = try qbe.compile(init.gpa, @ptrCast(input), .amd64_sysv);
    defer init.gpa.free(output);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "output.s",
        .data = output,
    });
}
