//! This file contains the IR Builder itself, an abstraction on top of the 'ir.zig' file.
//!
//! It aims at providing an LLVM-like interface and validation layer for QBE.
//!
//! The builder owns every piece of state needed to describe a QBE module: the
//! functions and their blocks, the temporary values inside those blocks, the
//! aggregate type definitions and the global data definitions. The user never
//! touches an `ir.Instr` or an `ir.Module` directly; instead they refer to
//! everything through opaque handles, and the builder is responsible for
//! interning strings, assigning temporary names and validating that the values
//! it is handed actually make sense together.
//!
//! Every validation failure is reported as a Zig error (see `Builder.Error`)
//! with an optional human readable message in `Builder.last_error`. This keeps
//! the builder usable from within a compiler that wants to keep running, which
//! is the whole point of embedding QBE as a library.

const std = @import("std");

const qbe = @import("qbe.zig");
const ir = @import("ir.zig");

pub const handle = struct {
    /// Handle referring to a function owned by the builder.
    pub const Function = enum(usize) { _ };

    /// Handle referring to a global (data) definition owned by the builder.
    pub const Global = enum(usize) { _ };

    /// Handle referring to a basic block owned by a function.
    ///
    /// The function is part of the handle so that a block can never be confused
    /// with a block of a different function, and so that the owning function can be
    /// recovered without a side table.
    pub const Block = struct {
        func: Function,
        index: usize,
    };

    /// Handle referring to a value that can be used as an operand.
    ///
    /// A value knows where it came from. Temporaries carry the block that defined
    /// them, parameters carry their function, globals carry their global handle and
    /// integer literals carry their own type. This lets the builder validate that
    /// an operand belongs to the function currently being emitted into, and that
    /// literal types line up with the instruction that consumes them.
    pub const Value = union(enum) {
        /// Result of an instruction, defined in `block`
        temp: struct {
            block: Block,
            index: usize,
        },
        /// A function parameter
        param: struct {
            func: Function,
            index: usize,
        },
        /// `$symbol` (address-like, always `.long`)
        global: Global,
        /// Integer literal, carrying its own type for validation
        int: struct {
            ty: ir.Type,
            val: u64,
        },
    };
};

/// Describes a function parameter at creation time.
pub const Param = struct {
    ty: ir.Type,
    /// Optional name. When `null` the builder synthesises `arg<N>`.
    name: ?[]const u8 = null,
};

/// One argument of a call instruction.
pub const CallArg = struct {
    ty: ir.Type,
    val: handle.Value,
};

/// Everything that can go wrong while building.
///
/// Note that `die_` never panics: it records a message in `last_error` and
/// returns one of these errors instead.
pub const Error = error{
    /// Allocation of builder owned state failed.
    OutOfMemory,
    /// The request was malformed (e.g. a variadic index out of range).
    InvalidBuilderUsage,
    /// A handle did not refer to anything the builder knows about.
    UnknownHandle,
    /// An instruction was emitted without a block to emit into.
    NoInsertPoint,
    /// The value/return types involved did not match.
    TypeMismatch,
    /// A type was used in a position where QBE does not accept it.
    InvalidType,
    /// An instruction was emitted after a block was already terminated.
    BlockTerminated,
    /// A value or branch target belonged to a different function.
    FunctionMismatch,
    /// A symbol (function, global, block, parameter) was defined twice.
    DuplicateSymbol,
    /// The requested operation cannot be expressed by the current IR model.
    Unsupported,
};

/// Per function bookkeeping that the `ir.zig` model does not carry.
const FunctionInfo = struct {
    name: []const u8,
    param_types: std.ArrayList(ir.Type),
    param_names: std.ArrayList([]const u8),
    /// Interned name of every temporary, indexed by `handle.Value.temp.index`.
    temp_names: std.ArrayList([]const u8),
    /// Base (ABI) type of every temporary, indexed like `temp_names`.
    temp_types: std.ArrayList(ir.Type),
    /// Names already taken inside this function, used to mint fresh temporaries.
    used_names: std.StringHashMapUnmanaged(void),
    /// Monotonic counter the temporary names are derived from.
    next_temp: usize,
    /// Monotonic counter the auto generated block labels are derived from.
    next_label: usize,
    return_ty: ?ir.Type,

    fn deinit(self: *FunctionInfo, gpa: std.mem.Allocator) void {
        self.param_types.deinit(gpa);
        self.param_names.deinit(gpa);
        self.temp_names.deinit(gpa);
        self.temp_types.deinit(gpa);
        self.used_names.deinit(gpa);
    }
};

/// Per global bookkeeping.
const GlobalInfo = struct {
    name: []const u8,
};

/// An LLVM-like IR builder for QBE.
pub const Builder = struct {
    /// Allocator backing the module and the builder's own bookkeeping.
    allocator: std.mem.Allocator,
    /// Arena owning every string and aggregate type handed to the module. The
    /// module borrows from it, so it has to outlive the module.
    arena: std.heap.ArenaAllocator,
    /// The module under construction. Its `types` list stays empty on purpose:
    /// aggregate types are stored separately so their addresses remain stable.
    module: ir.Module = .empty,
    /// Parallel to `module.functions`.
    funcs: std.ArrayList(FunctionInfo) = .empty,
    globals: std.ArrayList(GlobalInfo) = .empty,
    /// Maps the contents of a string created via `createGlobalString` to the
    /// global holding it, so identical strings share one definition.
    string_globals: std.StringHashMapUnmanaged(handle.Global) = .empty,
    /// Monotonic counter the auto generated string global names are derived from.
    next_str: usize = 0,
    /// Aggregate types, kept as stable pointers and printed before the module.
    types: std.ArrayList(*ir.TypeDef) = .empty,
    /// String interner, so that identical names share one allocation.
    interner: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Function the cursor currently points into (kept for convenience).
    cur_func: ?handle.Function = null,
    /// Block instructions are appended to.
    cur_block: ?handle.Block = null,
    /// Human readable description of the last error returned by `die_`.
    last_error: ?[]const u8 = null,

    /// Creates an empty builder and stores the allocator for all later operations
    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .module = .empty,
            .funcs = .empty,
            .globals = .empty,
            .string_globals = .empty,
            .next_str = 0,
            .types = .empty,
            .interner = .empty,
            .cur_func = null,
            .cur_block = null,
            .last_error = null,
        };
    }

    /// A builder backed by the page allocator, for quick throwaway use.
    pub const empty: Builder = Builder.init(std.heap.page_allocator);

    /// Releases everything the builder owns. The builder must not be used afterwards.
    pub fn deinit(self: *Builder) void {
        for (self.funcs.items) |*info| info.deinit(self.allocator);
        self.funcs.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.string_globals.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.interner.deinit(self.allocator);
        self.module.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Returns the message associated with the last error, if any.
    pub fn lastError(self: *const Builder) ?[]const u8 {
        return self.last_error;
    }

    // ---------------------------------------------------------------------
    // Types and data
    // ---------------------------------------------------------------------

    /// Defines an aggregate type. The returned value can be used anywhere an
    /// `ir.Type` is expected.
    pub fn createType(
        self: *Builder,
        name: []const u8,
        alignment: ?u64,
        items: []const ir.TypeDef.Item,
    ) Error!ir.Type {
        const tname = try self.intern(name);
        for (self.types.items) |td| {
            if (std.mem.eql(u8, td.name, tname)) {
                return self.die_(error.DuplicateSymbol, "type '{s}' is already defined", .{tname});
            }
        }

        const copied = try self.arena.allocator().alloc(ir.TypeDef.Item, items.len);
        for (items, 0..) |item, i| copied[i] = item;

        const td = try self.arena.allocator().create(ir.TypeDef);
        td.* = ir.TypeDef.init(tname, alignment, copied);
        try self.types.append(self.allocator, td);
        return .{ .aggregate = td };
    }

    /// Small helper to create a global string value. The symbol name is
    /// generated automatically. Strings with identical contents share a single
    /// global: the first definition (and the linkage it was created with) wins,
    /// and later calls return a handle to that same global.
    pub fn createGlobalString(self: *Builder, linkage: ir.Linkage, value: []const u8) Error!handle.Global {
        const interned = try self.intern(value);
        const gop = try self.string_globals.getOrPut(self.allocator, interned);
        if (gop.found_existing) {
            return gop.value_ptr.*;
        }
        gop.key_ptr.* = interned;
        errdefer _ = self.string_globals.remove(interned);

        const name = try std.fmt.allocPrint(self.arena.allocator(), ".Lstr.{d}", .{self.next_str});
        self.next_str += 1;

        const global = try self.createData(linkage, name, null, &.{
            .{ .ty = .byte, .item = .{ .str = interned } },
            .{ .ty = .byte, .item = .{ .@"const" = 0 } },
        });
        gop.value_ptr.* = global;
        return global;
    }

    /// Defines a global data symbol and returns a handle usable as an address.
    pub fn createData(
        self: *Builder,
        linkage: ir.Linkage,
        name: []const u8,
        alignment: ?u64,
        items: []const ir.DataDef.Item,
    ) Error!handle.Global {
        const gname = try self.intern(name);
        for (self.globals.items) |g| {
            if (std.mem.eql(u8, g.name, gname)) {
                return self.die_(error.DuplicateSymbol, "global '{s}' is already defined", .{gname});
            }
        }

        const copied = try self.arena.allocator().alloc(ir.DataDef.Item, items.len);
        for (items, 0..) |item, i| {
            copied[i] = item;
            switch (item.item) {
                .symbol => |s| copied[i].item = .{ .symbol = .{
                    .name = try self.intern(s.name),
                    .offset = s.offset,
                } },
                .str => |s| copied[i].item = .{ .str = try self.intern(s) },
                else => {},
            }
        }

        _ = try self.module.addData(self.allocator, ir.DataDef.init(linkage, gname, alignment, copied));
        try self.globals.append(self.allocator, .{ .name = gname });
        return @enumFromInt(self.globals.items.len - 1);
    }

    // ---------------------------------------------------------------------
    // Functions and blocks
    // ---------------------------------------------------------------------

    /// Creates a function. No entry block is created; use `createBlock`.
    pub fn createFunction(
        self: *Builder,
        linkage: ir.Linkage,
        name: []const u8,
        params: []const Param,
        return_ty: ?ir.Type,
    ) Error!handle.Function {
        const fname = try self.intern(name);
        if (return_ty) |rt| try self.validateValueType(rt);

        const arguments = try self.arena.allocator().alloc(ir.Argument, params.len);

        var info = FunctionInfo{
            .name = fname,
            .param_types = .empty,
            .param_names = .empty,
            .temp_names = .empty,
            .temp_types = .empty,
            .used_names = .empty,
            .next_temp = 0,
            .next_label = 0,
            .return_ty = return_ty,
        };
        var info_owned = true;
        errdefer if (info_owned) info.deinit(self.allocator);

        for (params, 0..) |param, i| {
            const pty = param.ty.intoAbi();
            try self.validateValueType(pty);
            const pname = if (param.name) |n|
                try self.intern(n)
            else
                try std.fmt.allocPrint(self.arena.allocator(), "arg{d}", .{i});

            const gop = try info.used_names.getOrPut(self.allocator, pname);
            if (gop.found_existing) {
                return self.die_(error.DuplicateSymbol, "parameter '{s}' is repeated", .{pname});
            }
            gop.key_ptr.* = pname;

            arguments[i] = .{ .ty = pty, .val = .{ .temporary = pname } };
            try info.param_types.append(self.allocator, pty);
            try info.param_names.append(self.allocator, pname);
        }

        _ = try self.module.addFunction(
            self.allocator,
            ir.Function.init(linkage, fname, arguments, return_ty, self.allocator),
        );
        try self.funcs.append(self.allocator, info);
        info_owned = false;

        return @enumFromInt(self.funcs.items.len - 1);
    }

    /// Appends a block to `func` with an optional label, and moves the cursor to it so instructions can be emitted right away.
    pub fn createBlock(self: *Builder, func: handle.Function, name: ?[]const u8) Error!handle.Block {
        const f = try self.funcPtr(func);
        const info = try self.funcInfo(func);

        const label = if (name) |n| try self.intern(n) else blk: {
            const generated = try std.fmt.allocPrint(
                self.arena.allocator(),
                "L{d}",
                .{info.next_label},
            );
            info.next_label += 1;
            break :blk try self.intern(generated);
        };

        for (f.blocks.items) |block| {
            if (std.mem.eql(u8, block.label, label)) {
                return self.die_(error.DuplicateSymbol, "block '@{s}' is already defined", .{label});
            }
        }

        _ = try f.addBlock(label);
        const block = handle.Block{ .func = func, .index = f.blocks.items.len - 1 };
        self.cur_func = func;
        self.cur_block = block;
        return block;
    }

    /// Moves the instruction cursor to `block`.
    pub fn setInsertPoint(self: *Builder, block: handle.Block) Error!void {
        _ = try self.blockPtr(block);
        self.cur_func = block.func;
        self.cur_block = block;
    }

    /// Returns the current insertion point, if any.
    pub fn insertPoint(self: *const Builder) ?handle.Block {
        return self.cur_block;
    }

    // ---------------------------------------------------------------------
    // Introspection
    // ---------------------------------------------------------------------

    /// Returns the interned name of `func`.
    pub fn functionName(self: *Builder, func: handle.Function) Error![]const u8 {
        return (try self.funcInfo(func)).name;
    }

    /// Returns the declared return type of `func`, if it is not void.
    pub fn returnType(self: *Builder, func: handle.Function) Error!?ir.Type {
        return (try self.funcInfo(func)).return_ty;
    }

    /// Returns the number of parameters `func` was created with.
    pub fn parameterCount(self: *Builder, func: handle.Function) Error!usize {
        return (try self.funcInfo(func)).param_names.items.len;
    }

    /// Returns the name of parameter `index` of `func`.
    pub fn parameterName(self: *Builder, func: handle.Function, index: usize) Error![]const u8 {
        const info = try self.funcInfo(func);
        if (index >= info.param_names.items.len) {
            return self.die_(error.UnknownHandle, "parameter index {d} out of range", .{index});
        }
        return info.param_names.items[index];
    }

    /// Returns the label of `block` (without the leading `@`).
    pub fn blockLabel(self: *Builder, block: handle.Block) Error![]const u8 {
        return (try self.blockPtr(block)).label;
    }

    /// Returns the number of blocks in `func`.
    pub fn blockCount(self: *Builder, func: handle.Function) Error!usize {
        return (try self.funcPtr(func)).blocks.items.len;
    }

    /// Returns the interned name of `global`.
    pub fn globalName(self: *Builder, global: handle.Global) Error![]const u8 {
        const idx = @intFromEnum(global);
        if (idx >= self.globals.items.len) {
            return self.die_(error.UnknownHandle, "unknown global handle", .{});
        }
        return self.globals.items[idx].name;
    }

    /// Returns the base type a value handle evaluates to.
    pub fn typeOf(self: *Builder, val: handle.Value) Error!ir.Type {
        return self.valueType(val);
    }

    // ---------------------------------------------------------------------
    // Value constructors
    // ---------------------------------------------------------------------

    /// Builds an integer literal handle. Only `word` and `long` are accepted.
    pub fn intConst(self: *Builder, ty: ir.Type, val: u64) Error!handle.Value {
        const base = ty.intoBase();
        switch (base) {
            .word, .long => {},
            else => return self.die_(error.InvalidType, "integer constant must be word or long, got {f}", .{ty}),
        }
        return .{ .int = .{ .ty = base, .val = val } };
    }

    /// Wraps a global definition as an address-like value.
    pub fn globalValue(self: *Builder, global: handle.Global) Error!handle.Value {
        if (@intFromEnum(global) >= self.globals.items.len) {
            return self.die_(error.UnknownHandle, "unknown global handle", .{});
        }
        return .{ .global = global };
    }

    /// Returns a handle for parameter `index` of `func`.
    pub fn getParam(self: *Builder, func: handle.Function, index: usize) Error!handle.Value {
        const f = try self.funcPtr(func);
        if (index >= f.arguments.len) {
            return self.die_(error.UnknownHandle, "parameter index {d} out of range", .{index});
        }
        return .{ .param = .{ .func = func, .index = index } };
    }

    // ---------------------------------------------------------------------
    // Arithmetic and bitwise instructions
    // ---------------------------------------------------------------------

    pub fn add(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.add, lhs, rhs);
    }
    pub fn sub(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.sub, lhs, rhs);
    }
    pub fn mul(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.mul, lhs, rhs);
    }
    pub fn div(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.div, lhs, rhs);
    }
    pub fn rem(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.rem, lhs, rhs);
    }
    pub fn udiv(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.udiv, lhs, rhs);
    }
    pub fn urem(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.urem, lhs, rhs);
    }
    pub fn sar(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.sar, lhs, rhs);
    }
    pub fn shr(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.shr, lhs, rhs);
    }
    pub fn shl(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.shl, lhs, rhs);
    }
    pub fn @"and"(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.@"and", lhs, rhs);
    }
    pub fn @"or"(self: *Builder, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        return self.arithmetic(.@"or", lhs, rhs);
    }

    /// Compares two values. The result is always a `word` (0 or 1).
    ///
    /// Floating point operands only support `eq`, `ne`, `o` and `uo`: the IR
    /// model cannot express ordered floating point comparisons.
    pub fn compare(self: *Builder, cmp: ir.Cmp, lhs: handle.Value, rhs: handle.Value) Error!handle.Value {
        const lty = (try self.valueType(lhs)).intoBase();
        const rty = (try self.valueType(rhs)).intoBase();
        if (!typeEq(lty, rty)) {
            return self.die_(error.TypeMismatch, "comparison operands have mismatched types", .{});
        }

        switch (lty) {
            .single, .double => switch (cmp) {
                .eq, .ne, .o, .uo => {},
                else => return self.die_(
                    error.Unsupported,
                    "ordered floating point comparison is not representable by the IR",
                    .{},
                ),
            },
            .word, .long => switch (cmp) {
                .o, .uo => return self.die_(
                    error.InvalidType,
                    "ordered/unordered comparison requires floating point operands",
                    .{},
                ),
                else => {},
            },
            else => return self.die_(error.InvalidType, "cannot compare values of type {f}", .{lty}),
        }

        try self.sameFunction(lhs);
        try self.sameFunction(rhs);

        const instr = ir.Instr{ .cmp = .{
            .ty = lty,
            .cmp = cmp,
            .lhs = try self.resolve(lhs),
            .rhs = try self.resolve(rhs),
        } };
        return self.emitValue(.word, instr);
    }

    /// Copies a value into a fresh temporary of the same type.
    pub fn copy(self: *Builder, val: handle.Value) Error!handle.Value {
        const ty = (try self.valueType(val)).intoBase();
        try self.sameFunction(val);
        return self.emitValue(ty, .{ .copy = try self.resolve(val) });
    }

    // ---------------------------------------------------------------------
    // Memory instructions
    // ---------------------------------------------------------------------

    /// Loads a value of `ty` from `addr`. `ty` is the load suffix: `word`,
    /// `long`, `single`, `double` or one of the sign/zero extending narrow
    /// types. Narrow loads produce a `word`.
    pub fn load(self: *Builder, ty: ir.Type, addr: handle.Value) Error!handle.Value {
        const result: ir.Type = switch (ty) {
            .signed_byte, .unsigned_byte, .signed_halfword, .unsigned_halfword => .word,
            .word => .word,
            .long => .long,
            .single => .single,
            .double => .double,
            else => return self.die_(error.InvalidType, "invalid load type {f}", .{ty}),
        };
        try self.expectPointer(addr);
        return self.emitValue(result, .{ .load = .{ .ty = ty, .src = try self.resolve(addr) } });
    }

    /// Loads through a sign/zero extending suffix while dictating the resulting
    /// temporary's type explicitly. `ir.zig` conflates the two, which is why
    /// this exists separately from `load`.
    pub fn loadExt(
        self: *Builder,
        ext: ir.Type,
        result_ty: ir.Type,
        addr: handle.Value,
    ) Error!handle.Value {
        switch (ext) {
            .signed_byte, .unsigned_byte, .signed_halfword, .unsigned_halfword => {},
            else => return self.die_(error.InvalidType, "invalid load extension type {f}", .{ext}),
        }
        try self.validateValueType(result_ty);
        try self.expectPointer(addr);
        return self.emitValue(
            result_ty,
            .{ .load = .{ .ty = ext, .src = try self.resolve(addr) } },
        );
    }

    /// Stores `val` at `addr`.
    ///
    /// `ty` is the store width. Byte and halfword stores take a `word` source;
    /// the other widths take a source of the matching type.
    pub fn store(self: *Builder, ty: ir.Type, addr: handle.Value, val: handle.Value) Error!void {
        const expected: ir.Type = switch (ty) {
            .byte, .halfword, .word => .word,
            .long => .long,
            .single => .single,
            .double => .double,
            else => return self.die_(error.InvalidType, "invalid store type {f}", .{ty}),
        };
        const vt = (try self.valueType(val)).intoBase();
        if (!typeEq(vt, expected)) {
            return self.die_(error.TypeMismatch, "store expects a {f} source, got {f}", .{ expected, vt });
        }
        try self.expectPointer(addr);
        try self.sameFunction(val);
        try self.emit(.{ .store = .{
            .ty = ty,
            .dest = try self.resolve(addr),
            .src = try self.resolve(val),
        } });
    }

    /// Allocates an aligned stack slot and returns its address.
    pub fn alloc4(self: *Builder, size: u32) Error!handle.Value {
        return self.emitValue(.long, .{ .alloc4 = size });
    }
    pub fn alloc8(self: *Builder, size: u64) Error!handle.Value {
        return self.emitValue(.long, .{ .alloc8 = size });
    }
    pub fn alloc16(self: *Builder, size: u128) Error!handle.Value {
        return self.emitValue(.long, .{ .alloc16 = size });
    }

    /// Copies `n` bytes from `src` to `dest`.
    pub fn blit(self: *Builder, src: handle.Value, dest: handle.Value, n: u64) Error!void {
        try self.expectPointer(src);
        try self.expectPointer(dest);
        try self.emit(.{ .blit = .{
            .src = try self.resolve(src),
            .dest = try self.resolve(dest),
            .n = n,
        } });
    }

    // ---------------------------------------------------------------------
    // Conversions
    // ---------------------------------------------------------------------

    pub fn extsw(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.extsw, .word, .long, val);
    }
    pub fn extuw(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.extuw, .word, .long, val);
    }
    pub fn extsh(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.extsh, .word, .word, val);
    }
    pub fn extuh(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.extuh, .word, .word, val);
    }
    pub fn extsb(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.extsb, .word, .word, val);
    }
    pub fn extub(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.extub, .word, .word, val);
    }
    pub fn exts(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.exts, .single, .double, val);
    }
    pub fn truncd(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.truncd, .double, .single, val);
    }
    pub fn stosi(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.stosi, .single, .word, val);
    }
    pub fn stoui(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.stoui, .single, .word, val);
    }
    pub fn dtosi(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.dtosi, .double, .long, val);
    }
    pub fn dtoui(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.dtoui, .double, .long, val);
    }
    pub fn swtof(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.swtof, .word, .single, val);
    }
    pub fn uwtof(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.uwtof, .word, .single, val);
    }
    pub fn sltof(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.sltof, .long, .double, val);
    }
    pub fn ultof(self: *Builder, val: handle.Value) Error!handle.Value {
        return self.unary(.ultof, .long, .double, val);
    }

    /// Bit-casts between same-width integer and floating point values.
    pub fn cast(self: *Builder, val: handle.Value) Error!handle.Value {
        const vt = (try self.valueType(val)).intoBase();
        const result: ir.Type = switch (vt) {
            .word => .single,
            .single => .word,
            .long => .double,
            .double => .long,
            else => return self.die_(error.InvalidType, "cannot cast a value of type {f}", .{vt}),
        };
        try self.sameFunction(val);
        return self.emitValue(result, .{ .cast = try self.resolve(val) });
    }

    /// Bit-casts `val` into `result_ty`, requiring a same-width round trip.
    pub fn castTo(self: *Builder, val: handle.Value, result_ty: ir.Type) Error!handle.Value {
        const vt = (try self.valueType(val)).intoBase();
        const rt = result_ty.intoBase();
        const ok = (typeEq(vt, .word) and typeEq(rt, .single)) or
            (typeEq(vt, .single) and typeEq(rt, .word)) or
            (typeEq(vt, .long) and typeEq(rt, .double)) or
            (typeEq(vt, .double) and typeEq(rt, .long));
        if (!ok) {
            return self.die_(error.TypeMismatch, "cannot cast {f} to {f}", .{ vt, rt });
        }
        try self.sameFunction(val);
        return self.emitValue(rt, .{ .cast = try self.resolve(val) });
    }

    // ---------------------------------------------------------------------
    // Variadic instructions
    // ---------------------------------------------------------------------

    /// Initialises a variable argument list at `ap`.
    pub fn vastart(self: *Builder, ap: handle.Value) Error!void {
        try self.expectPointer(ap);
        try self.emit(.{ .vastart = try self.resolve(ap) });
    }

    /// Fetches the next argument of type `ty` from the list at `ap`.
    pub fn vaarg(self: *Builder, ty: ir.Type, ap: handle.Value) Error!handle.Value {
        try self.validateValueType(ty);
        try self.expectPointer(ap);
        return self.emitValue(ty, .{ .vaarg = .{ .ty = ty, .val = try self.resolve(ap) } });
    }

    // ---------------------------------------------------------------------
    // Phi
    // ---------------------------------------------------------------------

    /// Emits a two-way phi node. Both values must share a type; that type
    /// becomes the type of the resulting temporary.
    pub fn phi(
        self: *Builder,
        label1: handle.Block,
        val1: handle.Value,
        label2: handle.Block,
        val2: handle.Value,
    ) Error!handle.Value {
        const cur = try self.requireBlock();
        if (label1.func != cur.func or label2.func != cur.func) {
            return self.die_(error.FunctionMismatch, "phi predecessors must belong to the current function", .{});
        }
        try self.sameFunction(val1);
        try self.sameFunction(val2);

        const ty = (try self.valueType(val1)).intoBase();
        if (!typeEq(ty, (try self.valueType(val2)).intoBase())) {
            return self.die_(error.TypeMismatch, "phi operands have mismatched types", .{});
        }
        switch (ty) {
            .word, .long, .single, .double => {},
            else => return self.die_(error.InvalidType, "cannot build a phi of type {f}", .{ty}),
        }

        const instr = ir.Instr{ .phi = .{
            .label1 = (try self.blockPtr(label1)).label,
            .val1 = try self.resolve(val1),
            .label2 = (try self.blockPtr(label2)).label,
            .val2 = try self.resolve(val2),
        } };
        return self.emitValue(ty, instr);
    }

    // ---------------------------------------------------------------------
    // Calls
    // ---------------------------------------------------------------------

    /// Emits a call to `name`. When `ret_ty` is non-null the result is assigned to a fresh temporary and returned; otherwise the call is void.
    pub fn call(
        self: *Builder,
        name: []const u8,
        ret_ty: ?ir.Type,
        args: []const CallArg,
        variadic_i: ?usize,
    ) Error!?handle.Value {
        if (variadic_i) |vi| {
            if (vi >= args.len) {
                return self.die_(error.InvalidBuilderUsage, "variadic index {d} out of range", .{vi});
            }
        }

        const callee = try self.intern(name);
        const arguments = try self.arena.allocator().alloc(ir.Argument, args.len);
        for (args, 0..) |arg, i| {
            const aty = arg.ty.intoAbi();
            try self.validateValueType(aty);
            try self.sameFunction(arg.val);
            arguments[i] = .{ .ty = aty, .val = try self.resolve(arg.val) };
        }

        const instr = ir.Instr{ .call = .{
            .name = callee,
            .args = arguments,
            .variadic_i = if (variadic_i) |vi| @intCast(vi) else null,
        } };

        if (ret_ty) |rt| {
            try self.validateValueType(rt);
            return try self.emitValue(rt, instr);
        }
        try self.emit(instr);
        return null;
    }

    // ---------------------------------------------------------------------
    // Terminators
    // ---------------------------------------------------------------------

    /// Returns from the current function, optionally with a value.
    pub fn ret(self: *Builder, val: ?handle.Value) Error!void {
        const cur = try self.requireBlock();
        const info = try self.funcInfo(cur.func);
        if (val) |v| {
            const rt = info.return_ty orelse {
                return self.die_(error.TypeMismatch, "cannot return a value from a void function", .{});
            };
            try self.sameFunction(v);
            const vt = (try self.valueType(v)).intoBase();
            if (!typeEq(vt, rt.intoBase())) {
                return self.die_(error.TypeMismatch, "return type mismatch: expected {f}, got {f}", .{ rt, vt });
            }
            try self.emit(.{ .ret = try self.resolve(v) });
        } else {
            if (info.return_ty != null) {
                return self.die_(error.TypeMismatch, "non-void function must return a value", .{});
            }
            try self.emit(.{ .ret = null });
        }
    }

    /// Unconditionally transfers control to `target`.
    pub fn jmp(self: *Builder, target: handle.Block) Error!void {
        try self.emit(.{ .jmp = try self.branchTarget(target) });
    }

    /// Transfers control to `non_zero` when `cond` is non-zero, else to `zero`.
    pub fn jnz(
        self: *Builder,
        cond: handle.Value,
        non_zero: handle.Block,
        zero: handle.Block,
    ) Error!void {
        try self.sameFunction(cond);
        try self.emit(.{ .jnz = .{
            .cond = try self.resolve(cond),
            .non_zero = try self.branchTarget(non_zero),
            .zero = try self.branchTarget(zero),
        } });
    }

    /// Halts the program with an error.
    pub fn hlt(self: *Builder) Error!void {
        try self.emit(.hlt);
    }

    // ---------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------

    /// Appends a comment to the current block.
    pub fn addComment(self: *Builder, contents: []const u8) Error!void {
        const block = try self.curBlockPtr();
        try block.addComment(self.allocator, try self.intern(contents));
    }

    /// Emits a `dbgfile` directive.
    pub fn addDebugFile(self: *Builder, file: []const u8) Error!void {
        try self.emit(.{ .dbg_file = try self.intern(file) });
    }

    /// Emits a `dbgloc` directive.
    pub fn addDebugLoc(self: *Builder, line: u64, column: ?u64) Error!void {
        try self.emit(.{ .dbg_loc = .{ .line = line, .column = column } });
    }

    // ---------------------------------------------------------------------
    // Output
    // ---------------------------------------------------------------------

    /// Renders the module as QBE IL text. The returned string is owned by the
    /// caller.
    pub fn toText(self: *Builder, allocator: std.mem.Allocator) ![:0]u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();

        const w = &writer.writer;
        for (self.types.items) |td| try w.print("{f}\n", .{td});
        try w.print("{f}", .{self.module});

        return try writer.toOwnedSliceSentinel(0);
    }

    /// Lowers the module through the embedded QBE backend, returning assembly
    /// text owned by the caller.
    pub fn compile(
        self: *Builder,
        allocator: std.mem.Allocator,
        target: qbe.Target,
    ) ![]u8 {
        const text = try self.toText(allocator);
        defer allocator.free(text);
        return qbe.compile(allocator, text, target);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// Records a diagnostic message and returns `err` instead of aborting.
    fn die_(self: *Builder, err: Error, comptime fmt: []const u8, args: anytype) Error {
        self.last_error = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch null;
        return err;
    }

    /// Interns `s`, returning a stable copy that lives as long as the builder.
    fn intern(self: *Builder, s: []const u8) Error![]const u8 {
        const gop = try self.interner.getOrPut(self.allocator, s);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.arena.allocator().dupe(u8, s);
        }
        return gop.key_ptr.*;
    }

    fn funcPtr(self: *Builder, func: handle.Function) Error!*ir.Function {
        const idx = @intFromEnum(func);
        if (idx >= self.module.functions.items.len) {
            return self.die_(error.UnknownHandle, "unknown function handle", .{});
        }
        return &self.module.functions.items[idx];
    }

    fn funcInfo(self: *Builder, func: handle.Function) Error!*FunctionInfo {
        const idx = @intFromEnum(func);
        if (idx >= self.funcs.items.len) {
            return self.die_(error.UnknownHandle, "unknown function handle", .{});
        }
        return &self.funcs.items[idx];
    }

    fn blockPtr(self: *Builder, block: handle.Block) Error!*ir.Block {
        const f = try self.funcPtr(block.func);
        if (block.index >= f.blocks.items.len) {
            return self.die_(error.UnknownHandle, "unknown block handle", .{});
        }
        return &f.blocks.items[block.index];
    }

    fn requireBlock(self: *Builder) Error!handle.Block {
        return self.cur_block orelse
            self.die_(error.NoInsertPoint, "no insertion point set; call createBlock or setInsertPoint", .{});
    }

    fn curBlockPtr(self: *Builder) Error!*ir.Block {
        return self.blockPtr(try self.requireBlock());
    }

    /// Returns the label of `target`, ensuring it belongs to the function the
    /// cursor points into.
    fn branchTarget(self: *Builder, target: handle.Block) Error![]const u8 {
        const cur = try self.requireBlock();
        if (target.func != cur.func) {
            return self.die_(error.FunctionMismatch, "branch target is in a different function", .{});
        }
        return (try self.blockPtr(target)).label;
    }

    /// Fails unless `val` belongs to the function the cursor points into.
    fn sameFunction(self: *Builder, val: handle.Value) Error!void {
        const cur = try self.requireBlock();
        switch (val) {
            .temp => |t| if (t.block.func != cur.func) {
                return self.die_(error.FunctionMismatch, "value belongs to a different function", .{});
            },
            .param => |p| if (p.func != cur.func) {
                return self.die_(error.FunctionMismatch, "value belongs to a different function", .{});
            },
            .global, .int => {},
        }
    }

    /// Fails unless `val` is a pointer-like (`long`) value.
    fn expectPointer(self: *Builder, val: handle.Value) Error!void {
        try self.sameFunction(val);
        const ty = (try self.valueType(val)).intoBase();
        if (!typeEq(ty, .long)) {
            return self.die_(error.TypeMismatch, "expected a pointer (long) value, got {f}", .{ty});
        }
    }

    /// Emits a statement that does not produce a value.
    fn emit(self: *Builder, instr: ir.Instr) Error!void {
        const block = try self.curBlockPtr();
        if (blockIsTerminated(block)) {
            return self.die_(error.BlockTerminated, "cannot append to an already terminated block", .{});
        }
        try block.addInstr(self.allocator, instr);
    }

    /// Emits a statement that assigns to a freshly minted temporary.
    fn emitValue(self: *Builder, ty: ir.Type, instr: ir.Instr) Error!handle.Value {
        const block_handle = try self.requireBlock();
        const block = try self.blockPtr(block_handle);
        if (blockIsTerminated(block)) {
            return self.die_(error.BlockTerminated, "cannot append to an already terminated block", .{});
        }

        const info = try self.funcInfo(block_handle.func);
        const name = try self.newTempName(info);
        const index = info.temp_names.items.len;
        try info.temp_names.append(self.allocator, name);
        try info.temp_types.append(self.allocator, ty.intoBase());

        try block.assignInstr(self.allocator, .{ .temporary = name }, ty, instr);
        return .{ .temp = .{ .block = block_handle, .index = index } };
    }

    /// Mints a temporary name that is not already used inside `info`.
    fn newTempName(self: *Builder, info: *FunctionInfo) Error![]const u8 {
        while (true) {
            const candidate = try std.fmt.allocPrint(
                self.arena.allocator(),
                "t{d}",
                .{info.next_temp},
            );
            info.next_temp += 1;
            const interned = try self.intern(candidate);
            const gop = try info.used_names.getOrPut(self.allocator, interned);
            if (!gop.found_existing) {
                gop.key_ptr.* = interned;
                return interned;
            }
        }
    }

    fn arithmetic(
        self: *Builder,
        comptime tag: std.meta.Tag(ir.Instr),
        lhs: handle.Value,
        rhs: handle.Value,
    ) Error!handle.Value {
        const lty = (try self.valueType(lhs)).intoBase();
        const rty = (try self.valueType(rhs)).intoBase();
        if (!typeEq(lty, rty)) {
            return self.die_(error.TypeMismatch, "operands of '{s}' have mismatched types", .{@tagName(tag)});
        }
        switch (lty) {
            .word, .long, .single, .double => {},
            else => return self.die_(
                error.InvalidType,
                "'{s}' requires word/long/single/double operands, got {f}",
                .{ @tagName(tag), lty },
            ),
        }

        try self.sameFunction(lhs);
        try self.sameFunction(rhs);

        const op = ir.Instr.BinaryOp{
            .lhs = try self.resolve(lhs),
            .rhs = try self.resolve(rhs),
        };
        return self.emitValue(lty, @unionInit(ir.Instr, @tagName(tag), op));
    }

    fn unary(
        self: *Builder,
        comptime tag: std.meta.Tag(ir.Instr),
        operand_ty: ir.Type,
        result_ty: ir.Type,
        val: handle.Value,
    ) Error!handle.Value {
        const vt = (try self.valueType(val)).intoBase();
        if (!typeEq(vt, operand_ty)) {
            return self.die_(
                error.TypeMismatch,
                "'{s}' expects a {f} operand, got {f}",
                .{ @tagName(tag), operand_ty, vt },
            );
        }
        try self.sameFunction(val);
        return self.emitValue(
            result_ty,
            @unionInit(ir.Instr, @tagName(tag), try self.resolve(val)),
        );
    }

    /// Resolves a handle into the concrete `ir.Value` the module stores.
    fn resolve(self: *Builder, val: handle.Value) Error!ir.Value {
        switch (val) {
            .temp => |t| {
                const info = try self.funcInfo(t.block.func);
                if (t.index >= info.temp_names.items.len) {
                    return self.die_(error.UnknownHandle, "unknown temporary handle", .{});
                }
                return .{ .temporary = info.temp_names.items[t.index] };
            },
            .param => |p| {
                const f = try self.funcPtr(p.func);
                if (p.index >= f.arguments.len) {
                    return self.die_(error.UnknownHandle, "unknown parameter handle", .{});
                }
                return f.arguments[p.index].val;
            },
            .global => |g| {
                const idx = @intFromEnum(g);
                if (idx >= self.globals.items.len) {
                    return self.die_(error.UnknownHandle, "unknown global handle", .{});
                }
                return .{ .global = self.globals.items[idx].name };
            },
            .int => |i| return .{ .@"const" = i.val },
        }
    }

    /// Returns the base type a handle evaluates to, validating it exists.
    fn valueType(self: *Builder, val: handle.Value) Error!ir.Type {
        switch (val) {
            .temp => |t| {
                const info = try self.funcInfo(t.block.func);
                if (t.index >= info.temp_types.items.len) {
                    return self.die_(error.UnknownHandle, "unknown temporary handle", .{});
                }
                return info.temp_types.items[t.index];
            },
            .param => |p| {
                const info = try self.funcInfo(p.func);
                if (p.index >= info.param_types.items.len) {
                    return self.die_(error.UnknownHandle, "unknown parameter handle", .{});
                }
                return info.param_types.items[p.index];
            },
            .global => return .long,
            .int => |i| return i.ty,
        }
    }

    /// Rejects types QBE does not accept where a value is expected.
    fn validateValueType(self: *Builder, ty: ir.Type) Error!void {
        switch (ty.intoAbi()) {
            .word, .long, .single, .double, .aggregate => {},
            else => return self.die_(error.InvalidType, "invalid value type {f}", .{ty}),
        }
    }
};

/// Reports whether `block` already ends in a control flow instruction.
///
/// This deliberately does not go through `ir.Block.jumps`, which inspects the
/// wrong field on the `volatile` statement payload.
fn blockIsTerminated(block: *const ir.Block) bool {
    if (block.items.items.len == 0) return false;
    const last = block.items.items[block.items.items.len - 1];
    return switch (last) {
        .comment => false,
        .statement => |stmt| switch (stmt) {
            .assign => false,
            .@"volatile" => |instr| switch (instr) {
                .ret, .jmp, .jnz, .hlt => true,
                else => false,
            },
        },
    };
}

/// Structural equality for `ir.Type`. Unions are not directly comparable in
/// Zig, and the aggregate payload is a pointer.
fn typeEq(a: ir.Type, b: ir.Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .aggregate => |p| p == b.aggregate,
        else => true,
    };
}

// --- TESTS ---

test "builder: hello world" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    const str = try builder.createData(.private(), "str", null, &.{
        .{ .ty = .byte, .item = .{ .str = "hello world" } },
        .{ .ty = .byte, .item = .{ .@"const" = 0 } },
    });

    const main = try builder.createFunction(.public(), "main", &.{}, .word);
    _ = try builder.createBlock(main, "start");

    _ = try builder.call(
        "puts",
        null,
        &.{.{ .ty = .long, .val = try builder.globalValue(str) }},
        null,
    );
    try builder.ret(try builder.intConst(.word, 0));

    const text = try builder.toText(gpa);
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "export function w $main() {\n" ++
            "@start\n" ++
            "\tcall $puts(l $str)\n" ++
            "\tret 0\n" ++
            "}\n" ++
            "data $str = { b \"hello world\", b 0 }\n",
        text,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), builder.lastError());
}

test "builder: global strings are deduplicated" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    const hello1 = try builder.createGlobalString(.private(), "hello");
    const hello2 = try builder.createGlobalString(.private(), "hello");
    const world = try builder.createGlobalString(.private(), "world");

    try std.testing.expect(hello1 == hello2);
    try std.testing.expect(hello1 != world);

    const main = try builder.createFunction(.public(), "main", &.{}, .word);
    _ = try builder.createBlock(main, "start");
    _ = try builder.call(
        "puts",
        null,
        &.{.{ .ty = .long, .val = try builder.globalValue(hello1) }},
        null,
    );
    try builder.ret(try builder.intConst(.word, 0));

    const text = try builder.toText(gpa);
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "export function w $main() {\n" ++
            "@start\n" ++
            "\tcall $puts(l $.Lstr.0)\n" ++
            "\tret 0\n" ++
            "}\n" ++
            "data $.Lstr.0 = { b \"hello\", b 0 }\n" ++
            "data $.Lstr.1 = { b \"world\", b 0 }\n",
        text,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), builder.lastError());
}

test "builder: function with parameters" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    const add = try builder.createFunction(.public(), "add", &.{
        .{ .ty = .word, .name = "a" },
        .{ .ty = .word, .name = "b" },
    }, .word);
    _ = try builder.createBlock(add, "entry");

    const sum = try builder.add(try builder.getParam(add, 0), try builder.getParam(add, 1));
    try builder.ret(sum);

    const text = try builder.toText(gpa);
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "export function w $add(w %a, w %b) {\n" ++
            "@entry\n" ++
            "\t%t0 =w add %a, %b\n" ++
            "\tret %t0\n" ++
            "}\n",
        text,
    );
}

test "builder: branches and phi" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    const choose = try builder.createFunction(.private(), "choose", &.{
        .{ .ty = .word, .name = "c" },
        .{ .ty = .word, .name = "x" },
        .{ .ty = .word, .name = "y" },
    }, .word);

    const entry = try builder.createBlock(choose, "entry");
    const then_block = try builder.createBlock(choose, "then");
    const else_block = try builder.createBlock(choose, "else");
    const join = try builder.createBlock(choose, "join");

    try builder.setInsertPoint(entry);
    try builder.jnz(try builder.getParam(choose, 0), then_block, else_block);

    try builder.setInsertPoint(then_block);
    const then_val = try builder.copy(try builder.getParam(choose, 1));
    try builder.jmp(join);

    try builder.setInsertPoint(else_block);
    const else_val = try builder.copy(try builder.getParam(choose, 2));
    try builder.jmp(join);

    try builder.setInsertPoint(join);
    const result = try builder.phi(then_block, then_val, else_block, else_val);
    try builder.ret(result);

    const text = try builder.toText(gpa);
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "function w $choose(w %c, w %x, w %y) {\n" ++
            "@entry\n" ++
            "\tjnz %c, @then, @else\n" ++
            "@then\n" ++
            "\t%t0 =w copy %x\n" ++
            "\tjmp @join\n" ++
            "@else\n" ++
            "\t%t1 =w copy %y\n" ++
            "\tjmp @join\n" ++
            "@join\n" ++
            "\t%t2 =w phi @then %t0, @else %t1\n" ++
            "\tret %t2\n" ++
            "}\n",
        text,
    );
}

test "builder: type and data definitions" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    const point = try builder.createType("point", null, &.{
        .{ .ty = .word, .repeat = 2 },
    });
    _ = try builder.createData(.public(), "origin", 8, &.{
        .{ .ty = point, .item = .{ .zero = 8 } },
    });

    const text = try builder.toText(gpa);
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "type :point = { w 2 }\n" ++
            "export data $origin = align 8 { :point z 8 }\n",
        text,
    );
}

test "builder: compiles through the embedded backend" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    const add = try builder.createFunction(.public(), "add", &.{
        .{ .ty = .word, .name = "a" },
        .{ .ty = .word, .name = "b" },
    }, .word);
    _ = try builder.createBlock(add, "entry");
    const sum = try builder.add(try builder.getParam(add, 0), try builder.getParam(add, 1));
    try builder.ret(sum);

    const asm_text = try builder.compile(gpa, .amd64_sysv);
    defer gpa.free(asm_text);

    try std.testing.expect(std.mem.indexOf(u8, asm_text, ".globl add") != null);
}

test "builder: introspection" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    const f = try builder.createFunction(.private(), "f", &.{
        .{ .ty = .word, .name = "a" },
        .{ .ty = .long },
    }, .long);
    const entry = try builder.createBlock(f, "entry");

    try std.testing.expectEqualStrings("f", try builder.functionName(f));
    try std.testing.expectEqual(@as(usize, 2), try builder.parameterCount(f));
    try std.testing.expectEqualStrings("a", try builder.parameterName(f, 0));
    try std.testing.expectEqualStrings("arg1", try builder.parameterName(f, 1));
    try std.testing.expectEqualStrings("entry", try builder.blockLabel(entry));
    try std.testing.expectEqual(@as(usize, 1), try builder.blockCount(f));

    const return_ty = (try builder.returnType(f)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(typeEq(return_ty, .long));
    try std.testing.expect(typeEq(try builder.typeOf(try builder.getParam(f, 0)), .word));
}

test "builder: rejects instructions after a terminator" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    const f = try builder.createFunction(.private(), "f", &.{}, null);
    _ = try builder.createBlock(f, "entry");
    try builder.ret(null);
    try std.testing.expectError(error.BlockTerminated, builder.ret(null));
}

test "builder: rejects mismatched operand types" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    const f = try builder.createFunction(.private(), "f", &.{
        .{ .ty = .word, .name = "a" },
        .{ .ty = .long, .name = "b" },
    }, null);
    _ = try builder.createBlock(f, "entry");
    try std.testing.expectError(
        error.TypeMismatch,
        builder.add(try builder.getParam(f, 0), try builder.getParam(f, 1)),
    );
}

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
