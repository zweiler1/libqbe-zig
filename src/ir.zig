//! This file is a rewrite of:
//!   - https://codeberg.org/ciathefed/qbe-zig/src/branch/main/src/root.zig and
//!   - https://codeberg.org/ciathefed/qbe-zig/src/branch/main/src/tests.zig
//! and updated to work with Zig 0.16.0
//!
//! This file has mostly been kept unchanged except for these parts:
//! - The allocator system was rewritten in a few places because of the new ArrayList implementation of Zig 0.16
//! - The `Float` tagged union was added to abstract QBEs floating point values
//!
//! For licensing information, look at the LICENSE-qbe-zig file

const std = @import("std");

pub const Argument = struct {
    ty: Type,
    val: Value,
};

/// QBE comparison operations used in conditional instructions.
pub const Cmp = enum {
    /// Returns 1 if first value is less than second, respecting signedness
    slt,
    /// Returns 1 if first value is less than or equal to second, respecting signedness
    sle,
    /// Returns 1 if first value is greater than second, respecting signedness
    sgt,
    /// Returns 1 if first value is greater than or equal to second, respecting signedness
    sge,
    /// Returns 1 if values are equal
    eq,
    /// Returns 1 if values are not equal
    ne,
    /// Returns 1 if both operands are not NaN (ordered comparison)
    o,
    /// Returns 1 if at least one operand is NaN (unordered comparison)
    uo,
    /// Returns 1 if first value is less than second, unsigned comparison
    ult,
    /// Returns 1 if first value is less than or equal to second, unsigned comparison
    ule,
    /// Returns 1 if first value is greater than second, unsigned comparison
    ugt,
    /// Returns 1 if first value is greater than or equal to second, unsigned comparison
    uge,

    pub fn toString(self: Cmp) []const u8 {
        return switch (self) {
            .slt => "slt",
            .sle => "sle",
            .sgt => "sgt",
            .sge => "sge",
            .eq => "eq",
            .ne => "ne",
            .o => "o",
            .uo => "uo",
            .ult => "ult",
            .ule => "ule",
            .ugt => "ugt",
            .uge => "uge",
        };
    }
};

/// QBE instructions representing operations in the intermediate language
pub const Instr = union(enum) {
    /// Adds values of two temporaries together
    add: BinaryOp,
    /// Subtracts the second value from the first one
    sub: BinaryOp,
    /// Multiplies values of two temporaries
    mul: BinaryOp,
    /// Divides the first value by the second one
    div: BinaryOp,
    /// Returns a remainder from division
    rem: BinaryOp,
    /// Performs a comparion between values
    cmp: Compare,
    /// Performs a bitwise AND on values
    @"and": BinaryOp,
    /// Performs a bitwise OR on values
    @"or": BinaryOp,
    /// Copies either a temporary or a literal value
    copy: Value,
    /// Return from a function, optionally with a value
    ret: ?Value,
    /// Jumps to first label if a value is nonzero or to the second one otherwise
    jnz: JumpNotZero,
    /// Unconditionally jumps to a label
    jmp: []const u8,
    /// Calls a function
    call: Call,
    /// Allocates a 4-byte aligned area on the stack
    alloc4: u32,
    /// Allocates a 8-byte aligned area on the stack
    alloc8: u64,
    /// Allocates a 16-byte aligned area on the stack
    alloc16: u128,
    /// Stores a value into memory pointed to by destination.
    store: Store,
    /// Loads a value from memory pointed to by source
    load: Load,
    /// Copy `n` bytes from the source address to the destination address
    blit: Blit,

    /// Debug file
    dbg_file: []const u8,
    /// Debug line
    dbg_loc: DbgLoc,

    /// Performs unsigned division of the first value by the second one
    udiv: BinaryOp,
    /// Returns the remainder from unsigned division
    urem: BinaryOp,

    /// Shift arithmetic right (preserves sign)
    sar: BinaryOp,
    /// Shift logical right (fills with zeros)
    shr: BinaryOp,
    /// Shift left (fills with zeros)
    shl: BinaryOp,

    /// Cast between integer and floating point of the same width
    cast: Value,

    /// Sign-extends a word to a long
    extsw: Value,
    /// Zero-extends a word to a long
    extuw: Value,
    /// Sign-extends a halfword to a word or long
    extsh: Value,
    /// Zero-extends a halfword to a word or long
    extuh: Value,
    /// Sign-extends a byte to a word or long
    extsb: Value,
    /// Zero-extends a byte to a word or long
    extub: Value,
    /// Extends a single-precision float to double-precision
    exts: Value,
    /// Truncates a double-precision float to single-precision
    truncd: Value,

    /// Converts a single-precision float to a signed integer
    stosi: Value,
    /// Converts a single-precision float to an unsigned integer
    stoui: Value,
    /// Converts a double-precision float to a signed integer
    dtosi: Value,
    /// Converts a double-precision float to an unsigned integer
    dtoui: Value,
    /// Converts a signed word to a float
    swtof: Value,
    /// Converts an unsigned word to a float
    uwtof: Value,
    /// Converts a signed long to a float
    sltof: Value,
    /// Converts an unsigned long to a float
    ultof: Value,

    /// Initializes a variable argument list
    vastart: Value,
    /// Fetches the next argument from a variable argument list
    vaarg: Vaarg,

    /// Selects value based on the control flow path into a block.
    phi: Phi,

    /// Terminates the program with an error
    hlt,

    pub const BinaryOp = struct { lhs: Value, rhs: Value };
    pub const Compare = struct { ty: Type, cmp: Cmp, lhs: Value, rhs: Value };
    pub const JumpNotZero = struct { cond: Value, non_zero: []const u8, zero: []const u8 };
    pub const Call = struct { name: []const u8, args: []const Argument, variadic_i: ?u64 };
    pub const Store = struct { ty: Type, dest: Value, src: Value };
    pub const Load = struct { ty: Type, src: Value };
    pub const Blit = struct { src: Value, dest: Value, n: u64 };
    pub const DbgLoc = struct { line: u64, column: ?u64 };
    pub const Vaarg = struct { ty: Type, val: Value };
    pub const Phi = struct { label1: []const u8, val1: Value, label2: []const u8, val2: Value };

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .add => |i| try writer.print("add {f}, {f}", .{ i.lhs, i.rhs }),
            .sub => |i| try writer.print("sub {f}, {f}", .{ i.lhs, i.rhs }),
            .mul => |i| try writer.print("mul {f}, {f}", .{ i.lhs, i.rhs }),
            .div => |i| try writer.print("div {f}, {f}", .{ i.lhs, i.rhs }),
            .rem => |i| try writer.print("rem {f}, {f}", .{ i.lhs, i.rhs }),
            .cmp => |i| {
                if (i.ty == .aggregate) {
                    @panic("Cannot compare aggregate types");
                }
                try writer.print("c{s}{f} {f}, {f}", .{ i.cmp.toString(), i.ty, i.lhs, i.rhs });
            },
            .@"and" => |i| try writer.print("and {f}, {f}", .{ i.lhs, i.rhs }),
            .@"or" => |i| try writer.print("or {f}, {f}", .{ i.lhs, i.rhs }),
            .copy => |i| try writer.print("copy {f}", .{i}),
            .ret => |i| {
                if (i) |val| {
                    try writer.print("ret {f}", .{val});
                } else {
                    try writer.writeAll("ret");
                }
            },
            .dbg_file => |i| try writer.print("dbgfile \"{s}\"", .{i}),
            .dbg_loc => |i| {
                if (i.column) |col| {
                    try writer.print("dbgloc {d}, {d}", .{ i.line, col });
                } else {
                    try writer.print("dbgloc {d}", .{i.line});
                }
            },
            .jnz => |i| try writer.print("jnz {f}, @{s}, @{s}", .{ i.cond, i.non_zero, i.zero }),
            .jmp => |i| try writer.print("jmp @{s}", .{i}),
            .call => |i| {
                try writer.print("call ${s}(", .{i.name});
                for (i.args, 0..) |arg, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    if (i.variadic_i) |vi| {
                        if (idx == vi) {
                            try writer.writeAll("..., ");
                        }
                    }
                    try writer.print("{f} {f}", .{ arg.ty, arg.val });
                }
                try writer.writeAll(")");
            },
            .alloc4 => |i| try writer.print("alloc4 {d}", .{i}),
            .alloc8 => |i| try writer.print("alloc8 {d}", .{i}),
            .alloc16 => |i| try writer.print("alloc16 {d}", .{i}),
            .store => |i| {
                if (i.ty == .aggregate) {
                    @panic("Store to an aggregate type not implemented");
                }
                try writer.print("store{f} {f}, {f}", .{ i.ty, i.src, i.dest });
            },
            .load => |i| {
                if (i.ty == .aggregate) {
                    @panic("Load aggregate type not implemented");
                }
                try writer.print("load{f} {f}", .{ i.ty, i.src });
            },
            .blit => |i| try writer.print("blit {f}, {f}, {d}", .{ i.src, i.dest, i.n }),
            .udiv => |i| try writer.print("udiv {f}, {f}", .{ i.lhs, i.rhs }),
            .urem => |i| try writer.print("urem {f}, {f}", .{ i.lhs, i.rhs }),
            .sar => |i| try writer.print("sar {f}, {f}", .{ i.lhs, i.rhs }),
            .shr => |i| try writer.print("shr {f}, {f}", .{ i.lhs, i.rhs }),
            .shl => |i| try writer.print("shl {f}, {f}", .{ i.lhs, i.rhs }),
            .cast => |i| try writer.print("cast {f}", .{i}),
            .extsw => |i| try writer.print("extsw {f}", .{i}),
            .extuw => |i| try writer.print("extuw {f}", .{i}),
            .extsh => |i| try writer.print("extsh {f}", .{i}),
            .extuh => |i| try writer.print("extuh {f}", .{i}),
            .extsb => |i| try writer.print("extsb {f}", .{i}),
            .extub => |i| try writer.print("extub {f}", .{i}),
            .exts => |i| try writer.print("exts {f}", .{i}),
            .truncd => |i| try writer.print("truncd {f}", .{i}),
            .stosi => |i| try writer.print("stosi {f}", .{i}),
            .stoui => |i| try writer.print("stoui {f}", .{i}),
            .dtosi => |i| try writer.print("dtosi {f}", .{i}),
            .dtoui => |i| try writer.print("dtoui {f}", .{i}),
            .swtof => |i| try writer.print("swtof {f}", .{i}),
            .uwtof => |i| try writer.print("uwtof {f}", .{i}),
            .sltof => |i| try writer.print("sltof {f}", .{i}),
            .ultof => |i| try writer.print("ultof {f}", .{i}),
            .vastart => |i| try writer.print("vastart {f}", .{i}),
            .vaarg => |i| try writer.print("vaarg{f} {f}", .{ i.ty, i.val }),
            .phi => |i| try writer.print("phi @{s} {f}, @{s} {f}", .{ i.label1, i.val1, i.label2, i.val2 }),
            .hlt => try writer.writeAll("hlt"),
        }
    }
};

/// QBE types used to specify the size and representation of values.
pub const Type = union(enum) {
    word,
    long,
    single,
    double,

    zero,

    byte,
    signed_byte,
    unsigned_byte,
    halfword,
    signed_halfword,
    unsigned_halfword,

    /// Aggregate type with a specified name
    aggregate: *const TypeDef,

    /// Returns a C ABI type. Extended types are converted to closest base
    /// types
    pub fn intoAbi(self: Type) Type {
        return switch (self) {
            .byte, .signed_byte, .unsigned_byte, .halfword, .signed_halfword, .unsigned_halfword => .word,
            else => self,
        };
    }

    /// Returns the closest base type
    pub fn intoBase(self: Type) Type {
        return switch (self) {
            .byte, .signed_byte, .unsigned_byte, .halfword, .signed_halfword, .unsigned_halfword => .word,
            .aggregate => .long,
            else => self,
        };
    }

    /// Returns byte size for values of the type
    pub fn size(self: Type) u64 {
        return switch (self) {
            .byte, .signed_byte, .unsigned_byte, .zero => 1,
            .halfword, .signed_halfword, .unsigned_halfword => 2,
            .word, .single => 4,
            .long, .double => 8,
            .aggregate => |td| blk: {
                var offset: u64 = 0;

                for (td.items) |item| {
                    const item_type = item.ty;
                    const repeat = item.repeat;
                    const alignment = item_type.@"align"();
                    const item_size = repeat * item_type.size();
                    const padding = (alignment - (offset % alignment)) % alignment;
                    offset += padding + item_size;
                }

                const alignment = self.@"align"();
                const padding = (alignment - (offset % alignment)) % alignment;

                break :blk offset + padding;
            },
        };
    }

    /// Returns byte alignment for values of the type
    pub fn @"align"(self: Type) u64 {
        return switch (self) {
            .aggregate => |td| blk: {
                if (td.@"align") |a| {
                    break :blk a;
                }

                var max_align: u64 = 1;
                for (td.items) |item| {
                    const item_align = item.ty.@"align"();
                    if (item_align > max_align) {
                        max_align = item_align;
                    }
                }
                break :blk max_align;
            },
            else => self.size(),
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .byte => try writer.writeAll("b"),
            .signed_byte => try writer.writeAll("sb"),
            .unsigned_byte => try writer.writeAll("ub"),
            .halfword => try writer.writeAll("h"),
            .signed_halfword => try writer.writeAll("sh"),
            .unsigned_halfword => try writer.writeAll("uh"),
            .word => try writer.writeAll("w"),
            .long => try writer.writeAll("l"),
            .single => try writer.writeAll("s"),
            .double => try writer.writeAll("d"),
            .zero => try writer.writeAll("z"),
            .aggregate => |td| try writer.print(":{s}", .{td.name}),
        }
    }
};

/// QBE floating point literal.
///
/// Floating point constants are self-typed in the QBE grammar: a single
/// precision literal is written `s_1.5` and a double precision one `d_2.25`.
pub const Float = union(enum) {
    single: f32,
    double: f64,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .single => |val| try writer.print("s_{e}", .{val}),
            .double => |val| try writer.print("d_{e}", .{val}),
        }
    }
};

/// QBE value that is accepted by instructions
pub const Value = union(enum) {
    /// `%`-temporary
    temporary: []const u8,
    /// `$`-global
    global: []const u8,
    /// Integer constant
    @"const": u64,
    /// Floating point constant
    float: Float,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .temporary => |name| try writer.print("%{s}", .{name}),
            .global => |name| try writer.print("${s}", .{name}),
            .@"const" => |val| try writer.print("{d}", .{val}),
            .float => |val| try writer.print("{f}", .{val}),
        }
    }
};

/// QBE data definition
pub const DataDef = struct {
    linkage: Linkage,
    name: []const u8,
    @"align": ?u64,
    items: []const Item,

    pub const Item = struct {
        ty: Type,
        item: DataItem,
    };

    pub fn init(
        linkage: Linkage,
        name: []const u8,
        @"align": ?u64,
        items: []const Item,
    ) DataDef {
        return DataDef{
            .linkage = linkage,
            .name = name,
            .@"align" = @"align",
            .items = items,
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}data ${s} = ", .{ self.linkage, self.name });

        if (self.@"align") |@"align"| {
            try writer.print("align {d} ", .{@"align"});
        }

        try writer.writeAll("{ ");
        for (self.items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{f} {f}", .{ item.ty, item.item });
        }
        try writer.writeAll(" }");
    }
};

/// Data definition item
pub const DataItem = union(enum) {
    /// Symbol and offset
    symbol: Symbol,
    /// String
    str: []const u8,
    /// Constant
    @"const": u64,
    /// Zero-initialized data of specified size
    zero: u64,

    pub const Symbol = struct {
        name: []const u8,
        offset: ?u64,
    };

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .symbol => |s| {
                if (s.offset) |off| {
                    try writer.print("${s} +{d}", .{ s.name, off });
                } else {
                    try writer.print("${s}", .{s.name});
                }
            },
            .str => |s| try writer.print("\"{s}\"", .{s}),
            .@"const" => |val| try writer.print("{d}", .{val}),
            .zero => |size| try writer.print("z {d}", .{size}),
        }
    }
};

/// QBE aggregate type definition
pub const TypeDef = struct {
    name: []const u8,
    @"align": ?u64,
    items: []const Item,

    pub const Item = struct {
        ty: Type,
        repeat: usize,
    };

    pub fn init(name: []const u8, @"align": ?u64, items: []const Item) TypeDef {
        return TypeDef{
            .name = name,
            .@"align" = @"align",
            .items = items,
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("type :{s} = ", .{self.name});
        if (self.@"align") |@"align"| {
            try writer.print("align {d} ", .{@"align"});
        }

        try writer.writeAll("{ ");
        for (self.items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(", ");
            if (item.repeat > 1) {
                try writer.print("{f} {d}", .{ item.ty, item.repeat });
            } else {
                try writer.print("{f}", .{item.ty});
            }
        }
        try writer.writeAll(" }");
    }
};

/// An IR statement
pub const Statement = union(enum) {
    assign: Assign,
    @"volatile": Instr,

    pub const Assign = struct {
        temp: Value,
        ty: Type,
        instr: Instr,
    };

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .assign => |s| {
                if (s.temp != .temporary) {
                    @panic("Assignment target must be a temporary");
                }
                try writer.print("{f} ={f} {f}", .{ s.temp, s.ty, s.instr });
            },
            .@"volatile" => |s| try writer.print("{f}", .{s}),
        }
    }
};

/// A block of QBE instructions with a label
pub const Block = struct {
    /// Label before the block
    label: []const u8,
    /// A list of statements in the block
    items: std.ArrayList(BlockItem),

    /// Initialize a new block with a label and allocator
    pub fn init(label: []const u8) Block {
        return .{
            .label = label,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    /// Adds a comment to the block
    pub fn addComment(self: *Block, allocator: std.mem.Allocator, contents: []const u8) !void {
        try self.items.append(allocator, .{ .comment = contents });
    }

    /// Adds a new instruction to the block
    pub fn addInstr(self: *Block, allocator: std.mem.Allocator, instr: Instr) !void {
        try self.items.append(allocator, .{ .statement = .{ .@"volatile" = instr } });
    }

    /// Adds a new instruction assigned to a temporary
    pub fn assignInstr(self: *Block, allocator: std.mem.Allocator, temp: Value, ty: Type, instr: Instr) !void {
        try self.items.append(allocator, .{ .statement = .{ .assign = .{
            .temp = temp,
            .ty = ty.intoBase(),
            .instr = instr,
        } } });
    }

    /// Returns true if the block's last instruction is a jump
    pub fn jumps(self: *const Block) bool {
        if (self.items.items.len == 0) return false;

        const last = self.items.items[self.items.items.len - 1];
        if (last == .statement and last.statement == .@"volatile") {
            const instr = last.statement.@"volatile".instr;
            return switch (instr) {
                .ret, .jmp, .jnz => true,
                else => false,
            };
        }
        return false;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("@{s}\n", .{self.label});
        for (self.items.items) |item| {
            try writer.print("\t{f}\n", .{item});
        }
    }
};

/// See `Block.items`
pub const BlockItem = union(enum) {
    statement: Statement,
    comment: []const u8,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .statement => |stmt| try writer.print("{f}", .{stmt}),
            .comment => |comment| try writer.print("# {s}", .{comment}),
        }
    }
};

/// A QBE function definition
pub const Function = struct {
    /// Function's linkage
    linkage: Linkage,
    /// Function name
    name: []const u8,
    /// Function arguments
    arguments: []const Argument,
    /// Return type
    return_ty: ?Type,
    /// labeled blocks
    blocks: std.ArrayList(Block),

    allocator: std.mem.Allocator,

    /// Initialize an empty function and returns it
    pub fn init(
        linkage: Linkage,
        name: []const u8,
        arguments: []const Argument,
        return_ty: ?Type,
        allocator: std.mem.Allocator,
    ) Function {
        return .{
            .linkage = linkage,
            .name = name,
            .arguments = arguments,
            .return_ty = return_ty,
            .blocks = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Function) void {
        for (self.blocks.items) |*block| {
            block.deinit(self.allocator);
        }
        self.blocks.deinit(self.allocator);
    }

    /// Adds a new empty block with a specified label and returns a reference to it
    pub fn addBlock(self: *Function, label: []const u8) !*Block {
        try self.blocks.append(self.allocator, Block.init(label));
        return &self.blocks.items[self.blocks.items.len - 1];
    }

    /// Returns a reference to the last block
    pub fn lastBlock(self: *Function) !*Block {
        if (self.blocks.items.len == 0) @panic("Function must have at least one block");
        return &self.blocks.items[self.blocks.items.len - 1];
    }

    /// Adds a new instruction to the last block
    pub fn addInstr(self: *Function, instr: Instr) !void {
        if (self.blocks.items.len == 0) {
            @panic("Last block must be present");
        }
        try self.blocks.items[self.blocks.items.len - 1].addInstr(self.allocator, instr);
    }

    /// Adds a new instruction assigned to a temporary
    pub fn assignInstr(self: *Function, temp: Value, ty: Type, instr: Instr) !void {
        if (self.blocks.items.len == 0) {
            @panic("Last block must be present");
        }
        try self.blocks.items[self.blocks.items.len - 1].assignInstr(self.allocator, temp, ty, instr);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}function", .{self.linkage});
        if (self.return_ty) |ty| {
            try writer.print(" {f}", .{ty});
        }

        var args: std.ArrayList([]const u8) = .empty;
        defer {
            for (args.items) |arg| {
                self.allocator.free(arg);
            }
            args.deinit(self.allocator);
        }

        for (self.arguments) |arg| {
            const arg_string = std.fmt.allocPrint(self.allocator, "{f} {f}", .{ arg.ty, arg.val }) catch {
                return std.Io.Writer.Error.WriteFailed;
            };
            args.append(self.allocator, arg_string) catch {
                return std.Io.Writer.Error.WriteFailed;
            };
        }

        const args_string = std.mem.join(self.allocator, ", ", args.items) catch {
            return std.Io.Writer.Error.WriteFailed;
        };
        defer self.allocator.free(args_string);

        try writer.print(" ${s}({s}) {{\n", .{ self.name, args_string });
        for (self.blocks.items) |blk| {
            try writer.print("{f}", .{blk});
        }
        try writer.print("}}", .{});
    }
};

/// Linkage of a function or data defintion (e.g. section and
/// private/public status)
pub const Linkage = struct {
    /// Specifies whether the target is going to be accessible publicly
    exported: bool = false,
    /// Specifies target's section
    section: ?[]const u8 = null,
    /// Specifies target's section flags
    secflags: ?[]const u8 = null,
    /// Specifies whether the target is stored in thread-local storage
    thread_local: bool = false,

    /// Returns the default configuration for private linkage
    pub fn private() Linkage {
        return .{};
    }

    /// Returns the configuration for private linkage with a provided section
    pub fn privateWithSection(section: []const u8) Linkage {
        return .{ .section = section };
    }

    /// Returns the default configuration for public linkage
    pub fn public() Linkage {
        return .{ .exported = true };
    }

    /// Returns the configuration for public linkage with a provided section
    pub fn publicWithSection(section: []const u8) Linkage {
        return .{ .exported = true, .section = section };
    }

    /// Returns the configuration for thread-local private linkage
    pub fn threadLocal() Linkage {
        return .{ .thread_local = true };
    }

    /// Returns the configuration for thread-local public linkage
    pub fn exportedThreadLocal() Linkage {
        return .{ .exported = true, .thread_local = true };
    }

    /// Returns the configuration for thread-local private linkage with a section
    pub fn threadLocalWithSection(section: []const u8) Linkage {
        return .{ .thread_local = true, .section = section };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.exported) {
            try writer.writeAll("export ");
        }
        if (self.thread_local) {
            try writer.writeAll("thread ");
        }
        if (self.section) |section| {
            try writer.print("section \"{s}\"", .{section});
            if (self.secflags) |secflags| {
                try writer.print(" \"{s}\"", .{secflags});
            }
            try writer.writeAll(" ");
        }
    }
};

/// A complete QBE IL module
pub const Module = struct {
    functions: std.ArrayList(Function),
    types: std.ArrayList(TypeDef),
    data: std.ArrayList(DataDef),

    /// Creates a new module
    pub const empty: Module = .{
        .functions = .empty,
        .types = .empty,
        .data = .empty,
    };

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        for (self.functions.items) |*func| {
            func.deinit();
        }
        self.functions.deinit(allocator);
        self.types.deinit(allocator);
        self.data.deinit(allocator);
    }

    /// Adds a function to the module, returning a reference to it for later
    /// modification
    pub fn addFunction(self: *Module, allocator: std.mem.Allocator, func: Function) !*Function {
        try self.functions.append(allocator, func);
        return &self.functions.items[self.functions.items.len - 1];
    }

    /// Adds a type definition to the module, returning a reference to it for
    /// later modification
    pub fn addType(self: *Module, allocator: std.mem.Allocator, def: TypeDef) !*TypeDef {
        try self.types.append(allocator, def);
        return &self.types.items[self.types.items.len - 1];
    }

    /// Adds a data definition to the module
    pub fn addData(self: *Module, allocator: std.mem.Allocator, data: DataDef) !*DataDef {
        try self.data.append(allocator, data);
        return &self.data.items[self.data.items.len - 1];
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        for (self.types.items) |ty| {
            try writer.print("{f}\n", .{ty});
        }

        for (self.functions.items) |func| {
            try writer.print("{f}\n", .{func});
        }

        for (self.data.items) |data| {
            try writer.print("{f}\n", .{data});
        }
    }
};

// --- TESTING FILES ---

fn testFmtEquals(T: type, value: T, expected: []const u8) !void {
    const string = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{value});
    defer std.testing.allocator.free(string);
    try std.testing.expectEqualSlices(u8, expected, string);
}

test "qbe value" {
    try testFmtEquals(Value, .{ .temporary = "temp42" }, "%temp42");
    try testFmtEquals(Value, .{ .global = "main" }, "$main");
    try testFmtEquals(Value, .{ .@"const" = 1337 }, "1337");
    try testFmtEquals(Value, .{ .float = .{ .single = 1.5 } }, "s_1.5e0");
    try testFmtEquals(Value, .{ .float = .{ .double = -2.25 } }, "d_-2.25e0");
}

test "block" {
    var blk1 = Block.init("start");
    defer blk1.deinit(std.testing.allocator);
    try blk1.addInstr(std.testing.allocator, .{ .ret = null });
    try testFmtEquals(Block, blk1, "@start\n\tret\n");

    var blk2 = Block.init("start");
    defer blk2.deinit(std.testing.allocator);
    try blk2.addComment(std.testing.allocator, "Comment");
    try blk2.assignInstr(std.testing.allocator, .{ .temporary = "foo" }, .word, .{ .add = .{ .lhs = .{ .@"const" = 2 }, .rhs = .{ .@"const" = 2 } } });
    try blk2.addInstr(std.testing.allocator, .{ .ret = .{ .temporary = "foo" } });
    try testFmtEquals(Block, blk2, "@start\n\t# Comment\n\t%foo =w add 2, 2\n\tret %foo\n");
}

test "instr blit" {
    var blk = Block.init("start");
    defer blk.deinit(std.testing.allocator);
    try blk.addInstr(std.testing.allocator, .{ .blit = .{ .src = .{ .temporary = "src" }, .dest = .{ .temporary = "dest" }, .n = 4 } });
    try testFmtEquals(Block, blk, "@start\n\tblit %src, %dest, 4\n");
}

test "function" {
    var func = Function.init(Linkage.public(), "main", &.{}, null, std.testing.allocator);
    defer func.deinit();
    var block = try func.addBlock("start");
    try block.addInstr(std.testing.allocator, .{ .ret = null });
    try testFmtEquals(Function, func, "export function $main() {\n@start\n\tret\n}");
}

test "data def" {
    const data_def = DataDef.init(Linkage.public(), "hello", null, &.{
        .{ .ty = .byte, .item = .{ .str = "Hello, World!" } },
        .{ .ty = .byte, .item = .{ .@"const" = 0 } },
    });
    try testFmtEquals(DataDef, data_def, "export data $hello = { b \"Hello, World!\", b 0 }");
}

test "type def" {
    const type_def = TypeDef.init("person", null, &.{
        .{ .ty = .long, .repeat = 1 },
        .{ .ty = .word, .repeat = 2 },
        .{ .ty = .byte, .repeat = 1 },
    });
    try testFmtEquals(TypeDef, type_def, "type :person = { l, w 2, b }");
    try testFmtEquals(Type, .{ .aggregate = &type_def }, ":person");
}

test "type size" {
    try std.testing.expectEqual(Type.size(.byte), 1);
    try std.testing.expectEqual(Type.size(.signed_byte), 1);
    try std.testing.expectEqual(Type.size(.unsigned_byte), 1);
    try std.testing.expectEqual(Type.size(.halfword), 2);
    try std.testing.expectEqual(Type.size(.signed_halfword), 2);
    try std.testing.expectEqual(Type.size(.unsigned_halfword), 2);
    try std.testing.expectEqual(Type.size(.word), 4);
    try std.testing.expectEqual(Type.size(.single), 4);
    try std.testing.expectEqual(Type.size(.long), 8);
    try std.testing.expectEqual(Type.size(.double), 8);

    const type_def = TypeDef.init("person", null, &.{
        .{ .ty = .long, .repeat = 1 },
        .{ .ty = .word, .repeat = 2 },
        .{ .ty = .byte, .repeat = 1 },
    });
    const aggregate: Type = .{ .aggregate = &type_def };
    try std.testing.expectEqual(aggregate.size(), 24);
}

test "type size nested aggregate" {
    const inner = TypeDef.init("dog", null, &.{
        .{ .ty = .long, .repeat = 2 },
    });
    const inner_aggregate: Type = .{ .aggregate = &inner };
    try std.testing.expectEqual(inner_aggregate.size(), 16);

    const type_def = TypeDef.init("person", null, &.{
        .{ .ty = .long, .repeat = 1 },
        .{ .ty = .word, .repeat = 2 },
        .{ .ty = .byte, .repeat = 1 },
        .{ .ty = .{ .aggregate = &inner }, .repeat = 1 },
    });
    const aggregate: Type = .{ .aggregate = &type_def };
    try std.testing.expectEqual(aggregate.size(), 40);
}

test "type into abi" {
    const unchanged = struct {
        fn func(ty: Type) !void {
            try std.testing.expectEqual(ty.intoAbi(), ty);
        }
    }.func;

    try unchanged(.word);
    try unchanged(.long);
    try unchanged(.single);
    try unchanged(.double);
    const type_def = TypeDef.init("foo", null, &.{});
    try unchanged(.{ .aggregate = &type_def });

    try std.testing.expectEqual(Type.intoAbi(.byte), Type.word);
    try std.testing.expectEqual(Type.intoAbi(.unsigned_byte), Type.word);
    try std.testing.expectEqual(Type.intoAbi(.signed_byte), Type.word);
    try std.testing.expectEqual(Type.intoAbi(.halfword), Type.word);
    try std.testing.expectEqual(Type.intoAbi(.unsigned_halfword), Type.word);
    try std.testing.expectEqual(Type.intoAbi(.signed_halfword), Type.word);
}

test "type into base" {
    const unchanged = struct {
        fn func(ty: Type) !void {
            try std.testing.expectEqual(ty.intoBase(), ty);
        }
    }.func;

    try unchanged(.word);
    try unchanged(.long);
    try unchanged(.single);
    try unchanged(.double);

    try std.testing.expectEqual(Type.intoBase(.byte), Type.word);
    try std.testing.expectEqual(Type.intoBase(.unsigned_byte), Type.word);
    try std.testing.expectEqual(Type.intoBase(.signed_halfword), Type.word);
    try std.testing.expectEqual(Type.intoBase(.halfword), Type.word);
    try std.testing.expectEqual(Type.intoBase(.unsigned_halfword), Type.word);
    try std.testing.expectEqual(Type.intoBase(.signed_halfword), Type.word);
    const type_def = TypeDef.init("foo", null, &.{});
    try std.testing.expectEqual(Type.intoBase(.{ .aggregate = &type_def }), Type.long);
}

test "add function to module" {
    var module: Module = .empty;
    defer module.deinit(std.testing.allocator);

    const function = Function.init(Linkage.private(), "foo", &.{}, null, std.testing.allocator);

    _ = try module.addFunction(std.testing.allocator, function);

    try std.testing.expectEqual(module.functions.items[0], function);
}

test "variadic call" {
    const instr = Instr{ .call = .{
        .name = "printf",
        .args = &.{
            .{ .ty = .long, .val = .{ .global = "fmt" } },
            .{ .ty = .word, .val = .{ .@"const" = 0 } },
        },
        .variadic_i = 1,
    } };
    try testFmtEquals(Instr, instr, "call $printf(l $fmt, ..., w 0)");
}

test "module fmt order" {
    var module: Module = .empty;
    defer module.deinit(std.testing.allocator);

    const type_def = TypeDef.init("test_type", null, &.{});
    _ = try module.addType(std.testing.allocator, type_def);

    var func = Function.init(Linkage.public(), "test_func", &.{}, null, std.testing.allocator);

    var block = try func.addBlock("entry");
    try block.addInstr(std.testing.allocator, .{ .ret = null });

    _ = try module.addFunction(std.testing.allocator, func);

    const data = DataDef.init(Linkage.private(), "test_data", null, &.{
        .{ .ty = .word, .item = .{ .@"const" = 42 } },
    });
    _ = try module.addData(std.testing.allocator, data);

    const formatted = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{module});
    defer std.testing.allocator.free(formatted);

    const type_pos = std.mem.indexOf(u8, formatted, ":test_type") orelse {
        @panic("Type definition not found");
    };

    const func_pos = std.mem.indexOf(u8, formatted, "export function $test_func") orelse {
        @panic("Function not found");
    };

    const data_pos = std.mem.indexOf(u8, formatted, "data $test_data") orelse {
        @panic("Data definition not found");
    };

    try std.testing.expect(type_pos < func_pos);
    try std.testing.expect(func_pos < data_pos);
}

test "comparison types" {
    const ordered_cmp: Statement = .{ .@"volatile" = .{ .cmp = .{
        .ty = .double,
        .cmp = .o,
        .lhs = .{ .temporary = "a" },
        .rhs = .{ .temporary = "b" },
    } } };
    try testFmtEquals(Statement, ordered_cmp, "cod %a, %b");

    const unordered_cmp: Statement = .{ .@"volatile" = .{ .cmp = .{
        .ty = .single,
        .cmp = .uo,
        .lhs = .{ .temporary = "a" },
        .rhs = .{ .temporary = "b" },
    } } };
    try testFmtEquals(Statement, unordered_cmp, "cuos %a, %b");

    const unsigned_lt: Statement = .{ .@"volatile" = .{ .cmp = .{
        .ty = .word,
        .cmp = .ult,
        .lhs = .{ .temporary = "a" },
        .rhs = .{ .temporary = "b" },
    } } };
    try testFmtEquals(Statement, unsigned_lt, "cultw %a, %b");

    const unsigned_le: Statement = .{ .@"volatile" = .{ .cmp = .{
        .ty = .long,
        .cmp = .ule,
        .lhs = .{ .temporary = "a" },
        .rhs = .{ .temporary = "b" },
    } } };
    try testFmtEquals(Statement, unsigned_le, "culel %a, %b");

    const unsigned_gt: Statement = .{ .@"volatile" = .{ .cmp = .{
        .ty = .word,
        .cmp = .ugt,
        .lhs = .{ .temporary = "a" },
        .rhs = .{ .temporary = "b" },
    } } };
    try testFmtEquals(Statement, unsigned_gt, "cugtw %a, %b");

    const unsigned_ge: Statement = .{ .@"volatile" = .{ .cmp = .{
        .ty = .long,
        .cmp = .uge,
        .lhs = .{ .temporary = "a" },
        .rhs = .{ .temporary = "b" },
    } } };
    try testFmtEquals(Statement, unsigned_ge, "cugel %a, %b");
}

test "unsigned arithmetic instructions" {
    const udiv: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .udiv = .{ .lhs = .{ .temporary = "a" }, .rhs = .{ .temporary = "b" } } },
    } };
    try testFmtEquals(Statement, udiv, "%result =w udiv %a, %b");

    const urem: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .long,
        .instr = .{ .urem = .{ .lhs = .{ .temporary = "a" }, .rhs = .{ .temporary = "b" } } },
    } };
    try testFmtEquals(Statement, urem, "%result =l urem %a, %b");
}

test "shift instructions" {
    const sar: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .sar = .{ .lhs = .{ .temporary = "a" }, .rhs = .{ .temporary = "b" } } },
    } };
    try testFmtEquals(Statement, sar, "%result =w sar %a, %b");

    const shr: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .long,
        .instr = .{ .shr = .{ .lhs = .{ .temporary = "a" }, .rhs = .{ .temporary = "b" } } },
    } };
    try testFmtEquals(Statement, shr, "%result =l shr %a, %b");

    const shl: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .shl = .{ .lhs = .{ .temporary = "a" }, .rhs = .{ .temporary = "b" } } },
    } };
    try testFmtEquals(Statement, shl, "%result =w shl %a, %b");
}

test "cast instruction" {
    const cast_int_to_float: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .single,
        .instr = .{ .cast = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, cast_int_to_float, "%result =s cast %a");

    const cast_float_to_int: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .cast = .{ .temporary = "f" } },
    } };
    try testFmtEquals(Statement, cast_float_to_int, "%result =w cast %f");
}

test "extension operations" {
    const extsw: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .long,
        .instr = .{ .extsw = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, extsw, "%result =l extsw %a");

    const extuw: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .long,
        .instr = .{ .extuw = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, extuw, "%result =l extuw %a");

    const extsh: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .extsh = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, extsh, "%result =w extsh %a");

    const extuh: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .extuh = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, extuh, "%result =w extuh %a");

    const extsb: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .extsb = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, extsb, "%result =w extsb %a");

    const extub: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .extub = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, extub, "%result =w extub %a");
}

test "float precision conversion" {
    const exts: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .double,
        .instr = .{ .exts = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, exts, "%result =d exts %a");

    const truncd: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .single,
        .instr = .{ .truncd = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, truncd, "%result =s truncd %a");
}

test "float integer conversions" {
    const stosi: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .stosi = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, stosi, "%result =w stosi %a");

    const stoui: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .stoui = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, stoui, "%result =w stoui %a");

    const dtosi: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .long,
        .instr = .{ .dtosi = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, dtosi, "%result =l dtosi %a");

    const dtoui: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .long,
        .instr = .{ .dtoui = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, dtoui, "%result =l dtoui %a");

    const swtof: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .single,
        .instr = .{ .swtof = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, swtof, "%result =s swtof %a");

    const uwtof: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .single,
        .instr = .{ .uwtof = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, uwtof, "%result =s uwtof %a");

    const sltof: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .double,
        .instr = .{ .sltof = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, sltof, "%result =d sltof %a");

    const ultof: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .double,
        .instr = .{ .ultof = .{ .temporary = "a" } },
    } };
    try testFmtEquals(Statement, ultof, "%result =d ultof %a");
}

test "variadic instructions" {
    const vastart: Statement = .{ .@"volatile" = .{ .vastart = .{ .temporary = "ap" } } };
    try testFmtEquals(Statement, vastart, "vastart %ap");

    const vaarg: Statement = .{ .assign = .{
        .temp = .{ .temporary = "arg" },
        .ty = .word,
        .instr = .{ .vaarg = .{ .ty = .word, .val = .{ .temporary = "ap" } } },
    } };
    try testFmtEquals(Statement, vaarg, "%arg =w vaargw %ap");
}

test "phi instruction" {
    const phi1: Instr = .{ .phi = .{
        .label1 = "ift",
        .val1 = .{ .@"const" = 2 },
        .label2 = "iff",
        .val2 = .{ .temporary = "3" },
    } };
    try testFmtEquals(Instr, phi1, "phi @ift 2, @iff %3");

    const phi2: Statement = .{ .assign = .{
        .temp = .{ .temporary = "result" },
        .ty = .word,
        .instr = .{ .phi = .{
            .label1 = "start",
            .val1 = .{ .temporary = "1" },
            .label2 = "loop",
            .val2 = .{ .global = "tmp" },
        } },
    } };
    try testFmtEquals(Statement, phi2, "%result =w phi @start %1, @loop $tmp");
}

test "halt instruction" {
    const hlt: Statement = .{ .@"volatile" = .hlt };
    try testFmtEquals(Statement, hlt, "hlt");
}

test "thread local linkage" {
    const thread_local = Linkage.threadLocal();
    try testFmtEquals(Linkage, thread_local, "thread ");

    const exported_thread_local = Linkage.exportedThreadLocal();
    try testFmtEquals(Linkage, exported_thread_local, "export thread ");

    const thread_local_with_section = Linkage.threadLocalWithSection("data");
    try testFmtEquals(Linkage, thread_local_with_section, "thread section \"data\" ");

    const data_def = DataDef.init(Linkage.threadLocal(), "thread_var", null, &.{
        .{ .ty = .word, .item = .{ .@"const" = 42 } },
    });
    try testFmtEquals(DataDef, data_def, "thread data $thread_var = { w 42 }");
}

test "zero initialized data" {
    const zero_data: DataItem = .{ .zero = 1000 };
    try testFmtEquals(DataItem, zero_data, "z 1000");

    const data_def1 = DataDef.init(Linkage.private(), "zero_array", null, &.{
        .{ .ty = .byte, .item = .{ .zero = 1000 } },
    });
    try testFmtEquals(DataDef, data_def1, "data $zero_array = { b z 1000 }");

    const data_def2 = DataDef.init(Linkage.private(), "mixed_data", null, &.{
        .{ .ty = .word, .item = .{ .@"const" = 1 } },
        .{ .ty = .byte, .item = .{ .zero = 10 } },
        .{ .ty = .word, .item = .{ .@"const" = 2 } },
    });
    try testFmtEquals(DataDef, data_def2, "data $mixed_data = { w 1, b z 10, w 2 }");
}

test "complex block with multiple instructions" {
    const allocator = std.testing.allocator;
    var block = Block.init("test_block");
    defer block.deinit(allocator);

    try block.assignInstr(
        allocator,
        .{ .temporary = "udiv_result" },
        .word,
        .{ .udiv = .{ .lhs = .{ .temporary = "a" }, .rhs = .{ .temporary = "b" } } },
    );

    try block.assignInstr(
        allocator,
        .{ .temporary = "shift_result" },
        .word,
        .{ .shl = .{ .lhs = .{ .temporary = "a" }, .rhs = .{ .temporary = "b" } } },
    );

    try block.assignInstr(
        allocator,
        .{ .temporary = "cast_result" },
        .single,
        .{ .cast = .{ .temporary = "shift_result" } },
    );

    try block.assignInstr(
        allocator,
        .{ .temporary = "cmp_result" },
        .word,
        .{ .cmp = .{
            .ty = .single,
            .cmp = .uo,
            .lhs = .{ .temporary = "cast_result" },
            .rhs = .{ .temporary = "x" },
        } },
    );

    try block.addInstr(allocator, .hlt);

    try testFmtEquals(Block, block, "@test_block\n\t%udiv_result =w udiv %a, %b\n\t%shift_result =w shl %a, %b\n\t%cast_result =s cast %shift_result\n\t%cmp_result =w cuos %cast_result, %x\n\thlt\n");
}
