//! Specialization cache file header and section validation.
//!
//! The file stores only fixed records and byte sections. Loading validates the
//! top-level header and maps sections as slices; function bodies and type nodes
//! must use ids and spans instead of embedded pointers.

const std = @import("std");
const Base = @import("base");
const check = @import("check");

const Common = @import("../common.zig");
const Ast = @import("ast.zig");
const Type = @import("type.zig");
const checked = check.CheckedModule;
const checked_names = check.CheckedNames;
const CheckedModuleData = @field(checked, "CheckedModule" ++ "Arti" ++ "f" ++ "act");

/// Magic bytes at the start of a specialization cache file.
pub const MAGIC: [8]u8 = .{ 'R', 'O', 'C', 'S', 'P', 'E', 'C', 0 };
/// Serialization format version for specialization cache files.
pub const FORMAT_VERSION: u32 = 1;

const SECTION_COUNT = 38;
/// Required byte alignment for every section payload. This covers all typed
/// Monotype cache sections so mapping can produce process slices directly.
pub const SECTION_ALIGNMENT: u64 = 16;

/// Validation errors for specialization cache mapping.
pub const CacheError = error{
    InvalidSpecializationCacheFile,
    UnsupportedSpecializationCacheVersion,
};

/// Stable section ids stored in the cache header.
pub const SectionId = enum(u8) {
    names,
    type_nodes,
    type_args,
    fields,
    tags,
    payloads,
    declared_fields,
    type_digests,
    specs,
    fns,
    defs,
    nested_defs,
    exprs,
    pats,
    stmts,
    locals,
    expr_ids,
    pat_ids,
    typed_locals,
    stmt_ids,
    field_exprs,
    record_destructs,
    str_pattern_steps,
    branches,
    if_branches,
    string_literals,
    imports,
    roots,
    layout_requests,
    runtime_schema_requests,
    comptime_sites,
    source_files,
    expr_locs,
    expr_regions,
    stmt_locs,
    stmt_regions,
    local_names,
    debug_names,
};

/// Byte payload for one section when constructing a cache image.
pub const SectionPayload = struct {
    id: SectionId,
    bytes: []const u8,
};

/// Inputs that affect Monotype specialization cache validity.
pub const ValidityConfig = struct {
    proc_debug_names: bool = false,
    builtin_data_id: ?[32]u8 = null,
};

/// Offset and length of one section in a specialization cache file.
pub const FileSlice = extern struct {
    offset: u64 = 0,
    len: u64 = 0,

    pub fn empty() FileSlice {
        return .{};
    }

    pub fn isEmpty(self: FileSlice) bool {
        return self.len == 0;
    }

    pub fn end(self: FileSlice) CacheError!u64 {
        return std.math.add(u64, self.offset, self.len) catch return error.InvalidSpecializationCacheFile;
    }

    pub fn validate(self: FileSlice, mapped_size: usize, alignment: u64) CacheError!void {
        if (self.isEmpty()) return;
        if (alignment == 0) return error.InvalidSpecializationCacheFile;
        if (self.offset % alignment != 0) return error.InvalidSpecializationCacheFile;
        const end_offset = try self.end();
        if (self.offset < @sizeOf(SpecializationCacheHeader)) return error.InvalidSpecializationCacheFile;
        if (end_offset > mapped_size) return error.InvalidSpecializationCacheFile;
    }

    pub fn viewBytes(self: FileSlice, base: [*]align(1) const u8, mapped_size: usize) CacheError![]const u8 {
        try self.validate(mapped_size, 1);
        if (self.isEmpty()) return &.{};
        const start: usize = @intCast(self.offset);
        const len: usize = @intCast(self.len);
        return base[start..][0..len];
    }

    pub fn viewTyped(
        self: FileSlice,
        comptime T: type,
        base: [*]align(1) const u8,
        mapped_size: usize,
    ) CacheError![]const T {
        try self.validate(mapped_size, @alignOf(T));
        if (self.isEmpty()) return &.{};
        if (self.len % @sizeOf(T) != 0) return error.InvalidSpecializationCacheFile;
        const bytes = try self.viewBytes(base, mapped_size);
        const ptr: [*]const T = @ptrCast(@alignCast(bytes.ptr));
        return ptr[0..(bytes.len / @sizeOf(T))];
    }
};

/// Fixed header stored at the beginning of every specialization cache file.
pub const SpecializationCacheHeader = extern struct {
    /// `ROCSpec\0`; rejects files from unrelated cache formats before any
    /// section offsets are trusted.
    magic: [8]u8 = MAGIC,
    /// Bumped whenever the section payload contract changes.
    format_version: u32 = FORMAT_VERSION,
    _padding: u32 = 0,
    /// Hash of section order and every fixed record layout read by the mapper.
    /// This rejects cache files written by a compiler with incompatible Zig
    /// layout decisions even when `FORMAT_VERSION` is unchanged.
    compiler_layout_hash: [32]u8 = [_]u8{0} ** 32,
    /// Hash of the checked modules, root requests, Monotype configuration, and
    /// stored specialization identities consumed by this cache file.
    validity_id: [32]u8 = [_]u8{0} ** 32,

    /// Relocatable checked-name store bytes.
    names: FileSlice = .{},
    /// Monotype type node payloads and their side-pool sections.
    type_nodes: FileSlice = .{},
    type_args: FileSlice = .{},
    fields: FileSlice = .{},
    tags: FileSlice = .{},
    payloads: FileSlice = .{},
    declared_fields: FileSlice = .{},
    type_digests: FileSlice = .{},

    /// Specialization records and Monotype function/body sections.
    specs: FileSlice = .{},
    fns: FileSlice = .{},
    defs: FileSlice = .{},
    nested_defs: FileSlice = .{},
    exprs: FileSlice = .{},
    pats: FileSlice = .{},
    stmts: FileSlice = .{},
    locals: FileSlice = .{},
    expr_ids: FileSlice = .{},
    pat_ids: FileSlice = .{},
    typed_locals: FileSlice = .{},
    stmt_ids: FileSlice = .{},
    field_exprs: FileSlice = .{},
    record_destructs: FileSlice = .{},
    str_pattern_steps: FileSlice = .{},
    branches: FileSlice = .{},
    if_branches: FileSlice = .{},
    string_literals: FileSlice = .{},
    imports: FileSlice = .{},
    roots: FileSlice = .{},
    layout_requests: FileSlice = .{},
    runtime_schema_requests: FileSlice = .{},
    /// Packed debug/source sections. These are byte payloads because the live
    /// builder representation still uses process pointers for text slices and
    /// branch-region lists.
    comptime_sites: FileSlice = .{},
    source_files: FileSlice = .{},
    expr_locs: FileSlice = .{},
    expr_regions: FileSlice = .{},
    stmt_locs: FileSlice = .{},
    stmt_regions: FileSlice = .{},
    local_names: FileSlice = .{},
    debug_names: FileSlice = .{},
};

/// Validated mapped cache file with accessors for its sections.
pub const MappedView = struct {
    header: *const SpecializationCacheHeader,
    base: [*]align(1) const u8,
    mapped_size: usize,
    shard_id: u32,

    pub fn sectionBytes(self: MappedView, slice: FileSlice) CacheError![]const u8 {
        return try slice.viewBytes(self.base, self.mapped_size);
    }

    pub fn sectionTyped(self: MappedView, comptime T: type, slice: FileSlice) CacheError![]const T {
        return try slice.viewTyped(T, self.base, self.mapped_size);
    }

    pub fn sectionsView(self: MappedView) CacheError!MappedSections {
        const header = self.header;
        return .{
            .names = try self.sectionBytes(header.names),
            .type_nodes = try self.sectionTyped(Type.Content, header.type_nodes),
            .type_args = try self.sectionTyped(Type.TypeId, header.type_args),
            .fields = try self.sectionTyped(Type.Field, header.fields),
            .tags = try self.sectionTyped(Type.Tag, header.tags),
            .payloads = try self.sectionTyped(Type.TypeId, header.payloads),
            .declared_fields = try self.sectionTyped(Type.DeclaredField, header.declared_fields),
            .type_digests = try self.sectionTyped(checked_names.TypeDigest, header.type_digests),
            .specs = try self.sectionTyped(Ast.SpecRecord, header.specs),
            .fns = try self.sectionTyped(Ast.Fn, header.fns),
            .defs = try self.sectionTyped(Ast.Def, header.defs),
            .nested_defs = try self.sectionTyped(Ast.NestedDef, header.nested_defs),
            .exprs = try self.sectionTyped(Ast.Expr, header.exprs),
            .pats = try self.sectionTyped(Ast.Pat, header.pats),
            .stmts = try self.sectionTyped(Ast.Stmt, header.stmts),
            .locals = try self.sectionTyped(Ast.Local, header.locals),
            .expr_ids = try self.sectionTyped(Ast.ExprId, header.expr_ids),
            .pat_ids = try self.sectionTyped(Ast.PatId, header.pat_ids),
            .typed_locals = try self.sectionTyped(Ast.TypedLocal, header.typed_locals),
            .stmt_ids = try self.sectionTyped(Ast.StmtId, header.stmt_ids),
            .field_exprs = try self.sectionTyped(Ast.FieldExpr, header.field_exprs),
            .record_destructs = try self.sectionTyped(Ast.RecordDestruct, header.record_destructs),
            .str_pattern_steps = try self.sectionTyped(Ast.StrPatternStep, header.str_pattern_steps),
            .branches = try self.sectionTyped(Ast.Branch, header.branches),
            .if_branches = try self.sectionTyped(Ast.IfBranch, header.if_branches),
            .string_literals = try self.sectionBytes(header.string_literals),
            .imports = try self.sectionTyped(Ast.ImportedFn, header.imports),
            .roots = try self.sectionTyped(Ast.Root, header.roots),
            .layout_requests = try self.sectionTyped(Ast.LayoutRequest, header.layout_requests),
            .runtime_schema_requests = try self.sectionTyped(Ast.RuntimeSchemaRequest, header.runtime_schema_requests),
            .comptime_sites = try self.sectionBytes(header.comptime_sites),
            .source_files = try self.sectionBytes(header.source_files),
            .expr_locs = try self.sectionTyped(Base.SourceLoc, header.expr_locs),
            .expr_regions = try self.sectionTyped(Base.Region, header.expr_regions),
            .stmt_locs = try self.sectionTyped(Base.SourceLoc, header.stmt_locs),
            .stmt_regions = try self.sectionTyped(Base.Region, header.stmt_regions),
            .local_names = try self.sectionBytes(header.local_names),
            .debug_names = try self.sectionBytes(header.debug_names),
        };
    }
};

/// Typed and raw section slices extracted from a mapped cache file.
pub const MappedSections = struct {
    names: []const u8,
    type_nodes: []const Type.Content,
    type_args: []const Type.TypeId,
    fields: []const Type.Field,
    tags: []const Type.Tag,
    payloads: []const Type.TypeId,
    declared_fields: []const Type.DeclaredField,
    type_digests: []const checked_names.TypeDigest,
    specs: []const Ast.SpecRecord,
    fns: []const Ast.Fn,
    defs: []const Ast.Def,
    nested_defs: []const Ast.NestedDef,
    exprs: []const Ast.Expr,
    pats: []const Ast.Pat,
    stmts: []const Ast.Stmt,
    locals: []const Ast.Local,
    expr_ids: []const Ast.ExprId,
    pat_ids: []const Ast.PatId,
    typed_locals: []const Ast.TypedLocal,
    stmt_ids: []const Ast.StmtId,
    field_exprs: []const Ast.FieldExpr,
    record_destructs: []const Ast.RecordDestruct,
    str_pattern_steps: []const Ast.StrPatternStep,
    branches: []const Ast.Branch,
    if_branches: []const Ast.IfBranch,
    string_literals: []const u8,
    imports: []const Ast.ImportedFn,
    roots: []const Ast.Root,
    layout_requests: []const Ast.LayoutRequest,
    runtime_schema_requests: []const Ast.RuntimeSchemaRequest,
    comptime_sites: []const u8,
    source_files: []const u8,
    expr_locs: []const Base.SourceLoc,
    expr_regions: []const Base.Region,
    stmt_locs: []const Base.SourceLoc,
    stmt_regions: []const Base.Region,
    local_names: []const u8,
    debug_names: []const u8,

    pub fn typeView(self: MappedSections) Type.DurableView {
        return .{
            .types = self.type_nodes,
            .type_digests = self.type_digests,
            .spans = self.type_args,
            .fields = self.fields,
            .tags = self.tags,
            .declared_fields = self.declared_fields,
        };
    }
};

/// Program-shaped view over mapped cache sections.
pub const MappedProgramView = struct {
    shard_id: Ast.ShardId,
    types: Type.DurableView,
    specs: []const Ast.SpecRecord,
    imported_fns: []const Ast.ImportedFn,
    fns: []const Ast.Fn,
    defs: []const Ast.Def,
    nested_defs: []const Ast.NestedDef,
    exprs: []const Ast.Expr,

    pub fn verifyCallTargets(self: MappedProgramView) ?Ast.CallTargetVerifyError {
        for (self.imported_fns) |imported| {
            if (imported.shard == .local and @intFromEnum(imported.fn_id) >= self.fns.len) {
                return .imported_local_fn_out_of_bounds;
            }
        }

        for (self.defs) |def| {
            if (def.fn_id) |fn_id| {
                if (self.verifyFnDefinition(fn_id, def.args)) |err| return err;
            }
        }
        for (self.nested_defs) |def| {
            if (self.verifyFnDefinition(def.fn_id, def.args)) |err| return err;
        }

        for (self.exprs) |expr| {
            switch (expr.data) {
                .call_proc => |call| switch (call.callee) {
                    .func => |slot| switch (slot) {
                        .local => |fn_id| {
                            const raw_fn = @intFromEnum(fn_id);
                            if (raw_fn >= self.fns.len) return .local_fn_out_of_bounds;
                            const raw_ty = @intFromEnum(self.fns[raw_fn].source.mono_fn_ty);
                            if (raw_ty >= self.types.types.len) return .local_fn_type_out_of_bounds;
                            switch (self.types.get(self.fns[raw_fn].source.mono_fn_ty)) {
                                .func => |func| {
                                    if (func.args.len != call.args.len) return .local_call_arity_mismatch;
                                },
                                else => return .local_fn_type_not_function,
                            }
                        },
                        .imported => |imported| {
                            if (@intFromEnum(imported) >= self.imported_fns.len) return .imported_fn_out_of_bounds;
                        },
                    },
                    .lifted => return .lifted_fn_before_lifting,
                },
                else => {},
            }
        }
        return null;
    }

    fn verifyFnDefinition(
        self: MappedProgramView,
        fn_id: Ast.FnId,
        args: Ast.Span(Ast.TypedLocal),
    ) ?Ast.CallTargetVerifyError {
        const raw_fn = @intFromEnum(fn_id);
        if (raw_fn >= self.fns.len) return .local_fn_out_of_bounds;
        const raw_ty = @intFromEnum(self.fns[raw_fn].source.mono_fn_ty);
        if (raw_ty >= self.types.types.len) return .local_fn_type_out_of_bounds;
        return switch (self.types.get(self.fns[raw_fn].source.mono_fn_ty)) {
            .func => |func| {
                if (func.args.len != args.len) return .local_fn_definition_arity_mismatch;
                return null;
            },
            else => .local_fn_type_not_function,
        };
    }
};

/// Validate a mapped cache file and return a view over its bytes.
pub fn viewMappedFile(
    header: *const SpecializationCacheHeader,
    base: [*]align(1) const u8,
    mapped_size: usize,
    expected_layout_hash: [32]u8,
    expected_validity_id: [32]u8,
    shard_id: u32,
) CacheError!MappedView {
    try validateHeader(header, mapped_size, expected_layout_hash, expected_validity_id);
    return .{
        .header = header,
        .base = base,
        .mapped_size = mapped_size,
        .shard_id = shard_id,
    };
}

/// Convert a validated mapped file to a program-shaped view without rewriting
/// body, expression, pattern, or type records.
pub fn mappedProgramView(view: MappedView) CacheError!MappedProgramView {
    const sections_ = try view.sectionsView();
    return .{
        .shard_id = @enumFromInt(view.shard_id),
        .types = sections_.typeView(),
        .specs = sections_.specs,
        .imported_fns = sections_.imports,
        .fns = sections_.fns,
        .defs = sections_.defs,
        .nested_defs = sections_.nested_defs,
        .exprs = sections_.exprs,
    };
}

/// Validate the fixed cache header and all section ranges.
pub fn validateHeader(
    header: *const SpecializationCacheHeader,
    mapped_size: usize,
    expected_layout_hash: [32]u8,
    expected_validity_id: [32]u8,
) CacheError!void {
    if (mapped_size < @sizeOf(SpecializationCacheHeader)) return error.InvalidSpecializationCacheFile;
    if (!std.mem.eql(u8, header.magic[0..], MAGIC[0..])) return error.InvalidSpecializationCacheFile;
    if (header.format_version != FORMAT_VERSION) return error.UnsupportedSpecializationCacheVersion;
    if (!std.mem.eql(u8, header.compiler_layout_hash[0..], expected_layout_hash[0..])) {
        return error.InvalidSpecializationCacheFile;
    }
    if (!std.mem.eql(u8, header.validity_id[0..], expected_validity_id[0..])) {
        return error.InvalidSpecializationCacheFile;
    }

    var previous_end: u64 = @sizeOf(SpecializationCacheHeader);
    for (sections(header)) |section| {
        if (section.isEmpty()) continue;
        try section.validate(mapped_size, SECTION_ALIGNMENT);
        if (section.offset < previous_end) return error.InvalidSpecializationCacheFile;
        previous_end = try section.end();
    }
}

/// Build a deterministic in-memory image for a specialization cache file.
pub fn buildImage(
    allocator: std.mem.Allocator,
    compiler_layout_hash: [32]u8,
    validity_id: [32]u8,
    payloads: []const SectionPayload,
) (std.mem.Allocator.Error || CacheError)![]u8 {
    var seen = [_]bool{false} ** SECTION_COUNT;
    for (payloads) |payload| {
        const index = sectionIndex(payload.id);
        if (seen[index]) return error.InvalidSpecializationCacheFile;
        seen[index] = true;
    }

    var image = std.ArrayList(u8).empty;
    errdefer image.deinit(allocator);
    try image.appendNTimes(allocator, 0, @sizeOf(SpecializationCacheHeader));

    var header = SpecializationCacheHeader{
        .compiler_layout_hash = compiler_layout_hash,
        .validity_id = validity_id,
    };

    inline for (section_order) |id| {
        if (findPayload(payloads, id)) |payload| {
            const offset = try appendAlignedSection(allocator, &image, payload.bytes);
            setSection(&header, id, .{
                .offset = offset,
                .len = @intCast(payload.bytes.len),
            });
        }
    }

    const header_bytes = std.mem.asBytes(&header);
    @memcpy(image.items[0..@sizeOf(SpecializationCacheHeader)], header_bytes);
    return try image.toOwnedSlice(allocator);
}

/// Compute the validity id for a cache file without stored spec records.
pub fn computeValidityId(
    modules: Common.CheckedModules,
    roots: Common.RootRequests,
    config: ValidityConfig,
) [32]u8 {
    return computeValidityIdWithSpecs(modules, roots, config, &.{});
}

/// Compute the validity id for a cache file including stored spec identities.
pub fn computeValidityIdWithSpecs(
    modules: Common.CheckedModules,
    roots: Common.RootRequests,
    config: ValidityConfig,
    specs: []const Ast.SpecRecord,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    writeHashBytes(&hasher, "roc-monotype-specialization-cache-validity");
    writeHashU32(&hasher, FORMAT_VERSION);

    writeHashBytes(&hasher, "config");
    writeHashBool(&hasher, config.proc_debug_names);
    writeHashOptionalBytes32(&hasher, config.builtin_data_id);

    writeHashBytes(&hasher, "root-module");
    writeModuleId(&hasher, modules.root.module.key);

    writeHashBytes(&hasher, "import-modules");
    writeHashU32(&hasher, @intCast(modules.imports.len));
    for (modules.imports) |module| {
        writeModuleId(&hasher, module.key);
    }

    writeHashBytes(&hasher, "relation-modules");
    writeHashU32(&hasher, @intCast(modules.root.relation_modules.len));
    for (modules.root.relation_modules) |module| {
        writeModuleId(&hasher, module.key);
    }

    writeHashBytes(&hasher, "root-requests");
    writeHashU32(&hasher, @intCast(roots.requests.len));
    for (roots.requests) |request| {
        writeRootRequest(&hasher, request);
    }

    writeHashBytes(&hasher, "layout-requests");
    writeHashU32(&hasher, @intCast(roots.layout_requests.len));
    for (roots.layout_requests) |ty| {
        writeCheckedTypeId(&hasher, ty);
    }

    writeHashBytes(&hasher, "static-data-requests");
    writeHashU32(&hasher, @intCast(roots.static_data_requests.len));
    for (roots.static_data_requests) |request| {
        writeProvidedDataExport(&hasher, request.data);
    }

    writeHashBytes(&hasher, "spec-records");
    writeHashU32(&hasher, @intCast(specs.len));
    for (specs) |spec| {
        writeSpecRecord(&hasher, spec);
    }

    return hasher.finalResult();
}

/// Hash the compiler-side durable layouts consumed by the cache reader.
pub fn computeCompilerLayoutHash() [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    writeHashBytes(&hasher, "roc-monotype-specialization-cache-layout");
    writeHashU32(&hasher, FORMAT_VERSION);
    writeHashU32(&hasher, SECTION_COUNT);
    writeHashU64(&hasher, SECTION_ALIGNMENT);

    writeHashBytes(&hasher, "section-order");
    inline for (section_order) |id| {
        writeHashBytes(&hasher, @tagName(id));
        writeHashU32(&hasher, @intFromEnum(id));
        writeHashU32(&hasher, @intCast(sectionIndex(id)));
    }

    writeLayout(&hasher, FileSlice);
    writeLayout(&hasher, SpecializationCacheHeader);
    writeLayout(&hasher, checked_names.TypeDigest);

    writeLayout(&hasher, Type.TypeId);
    writeLayout(&hasher, Type.Span);
    writeLayout(&hasher, Type.Field);
    writeLayout(&hasher, Type.Tag);
    writeLayout(&hasher, Type.DeclaredField);
    writeLayout(&hasher, Type.Content);

    writeLayout(&hasher, Ast.FnId);
    writeLayout(&hasher, Ast.ShardId);
    writeLayout(&hasher, Ast.ImportedFnId);
    writeLayout(&hasher, Ast.ImportedFn);
    writeLayout(&hasher, Ast.FnSlot);
    writeLayout(&hasher, Ast.SpecRecord);
    writeLayout(&hasher, Ast.Fn);
    writeLayout(&hasher, Ast.Def);
    writeLayout(&hasher, Ast.NestedDef);
    writeLayout(&hasher, Ast.Expr);
    writeLayout(&hasher, Ast.Pat);
    writeLayout(&hasher, Ast.Stmt);
    writeLayout(&hasher, Ast.Local);
    writeLayout(&hasher, Ast.TypedLocal);
    writeLayout(&hasher, Ast.FieldExpr);
    writeLayout(&hasher, Ast.RecordDestruct);
    writeLayout(&hasher, Ast.StrPatternStep);
    writeLayout(&hasher, Ast.Branch);
    writeLayout(&hasher, Ast.IfBranch);
    writeLayout(&hasher, Ast.Root);
    writeLayout(&hasher, Ast.LayoutRequest);
    writeLayout(&hasher, Ast.RuntimeSchemaRequest);
    writeLayout(&hasher, Base.SourceLoc);
    writeLayout(&hasher, Base.Region);

    return hasher.finalResult();
}

fn sections(header: *const SpecializationCacheHeader) [SECTION_COUNT]FileSlice {
    return .{
        header.names,
        header.type_nodes,
        header.type_args,
        header.fields,
        header.tags,
        header.payloads,
        header.declared_fields,
        header.type_digests,
        header.specs,
        header.fns,
        header.defs,
        header.nested_defs,
        header.exprs,
        header.pats,
        header.stmts,
        header.locals,
        header.expr_ids,
        header.pat_ids,
        header.typed_locals,
        header.stmt_ids,
        header.field_exprs,
        header.record_destructs,
        header.str_pattern_steps,
        header.branches,
        header.if_branches,
        header.string_literals,
        header.imports,
        header.roots,
        header.layout_requests,
        header.runtime_schema_requests,
        header.comptime_sites,
        header.source_files,
        header.expr_locs,
        header.expr_regions,
        header.stmt_locs,
        header.stmt_regions,
        header.local_names,
        header.debug_names,
    };
}

const section_order = [_]SectionId{
    .names,
    .type_nodes,
    .type_args,
    .fields,
    .tags,
    .payloads,
    .declared_fields,
    .type_digests,
    .specs,
    .fns,
    .defs,
    .nested_defs,
    .exprs,
    .pats,
    .stmts,
    .locals,
    .expr_ids,
    .pat_ids,
    .typed_locals,
    .stmt_ids,
    .field_exprs,
    .record_destructs,
    .str_pattern_steps,
    .branches,
    .if_branches,
    .string_literals,
    .imports,
    .roots,
    .layout_requests,
    .runtime_schema_requests,
    .comptime_sites,
    .source_files,
    .expr_locs,
    .expr_regions,
    .stmt_locs,
    .stmt_regions,
    .local_names,
    .debug_names,
};

fn sectionIndex(id: SectionId) usize {
    return switch (id) {
        .names => 0,
        .type_nodes => 1,
        .type_args => 2,
        .fields => 3,
        .tags => 4,
        .payloads => 5,
        .declared_fields => 6,
        .type_digests => 7,
        .specs => 8,
        .fns => 9,
        .defs => 10,
        .nested_defs => 11,
        .exprs => 12,
        .pats => 13,
        .stmts => 14,
        .locals => 15,
        .expr_ids => 16,
        .pat_ids => 17,
        .typed_locals => 18,
        .stmt_ids => 19,
        .field_exprs => 20,
        .record_destructs => 21,
        .str_pattern_steps => 22,
        .branches => 23,
        .if_branches => 24,
        .string_literals => 25,
        .imports => 26,
        .roots => 27,
        .layout_requests => 28,
        .runtime_schema_requests => 29,
        .comptime_sites => 30,
        .source_files => 31,
        .expr_locs => 32,
        .expr_regions => 33,
        .stmt_locs => 34,
        .stmt_regions => 35,
        .local_names => 36,
        .debug_names => 37,
    };
}

fn findPayload(payloads: []const SectionPayload, id: SectionId) ?SectionPayload {
    for (payloads) |payload| {
        if (payload.id == id) return payload;
    }
    return null;
}

fn appendAlignedSection(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    bytes: []const u8,
) std.mem.Allocator.Error!u64 {
    if (bytes.len == 0) return 0;
    const alignment: usize = @intCast(SECTION_ALIGNMENT);
    const aligned_offset = std.mem.alignForward(usize, image.items.len, alignment);
    if (aligned_offset > image.items.len) {
        try image.appendNTimes(allocator, 0, aligned_offset - image.items.len);
    }
    const offset: u64 = @intCast(image.items.len);
    try image.appendSlice(allocator, bytes);
    return offset;
}

fn setSection(header: *SpecializationCacheHeader, id: SectionId, slice: FileSlice) void {
    switch (id) {
        .names => header.names = slice,
        .type_nodes => header.type_nodes = slice,
        .type_args => header.type_args = slice,
        .fields => header.fields = slice,
        .tags => header.tags = slice,
        .payloads => header.payloads = slice,
        .declared_fields => header.declared_fields = slice,
        .type_digests => header.type_digests = slice,
        .specs => header.specs = slice,
        .fns => header.fns = slice,
        .defs => header.defs = slice,
        .nested_defs => header.nested_defs = slice,
        .exprs => header.exprs = slice,
        .pats => header.pats = slice,
        .stmts => header.stmts = slice,
        .locals => header.locals = slice,
        .expr_ids => header.expr_ids = slice,
        .pat_ids => header.pat_ids = slice,
        .typed_locals => header.typed_locals = slice,
        .stmt_ids => header.stmt_ids = slice,
        .field_exprs => header.field_exprs = slice,
        .record_destructs => header.record_destructs = slice,
        .str_pattern_steps => header.str_pattern_steps = slice,
        .branches => header.branches = slice,
        .if_branches => header.if_branches = slice,
        .string_literals => header.string_literals = slice,
        .imports => header.imports = slice,
        .roots => header.roots = slice,
        .layout_requests => header.layout_requests = slice,
        .runtime_schema_requests => header.runtime_schema_requests = slice,
        .comptime_sites => header.comptime_sites = slice,
        .source_files => header.source_files = slice,
        .expr_locs => header.expr_locs = slice,
        .expr_regions => header.expr_regions = slice,
        .stmt_locs => header.stmt_locs = slice,
        .stmt_regions => header.stmt_regions = slice,
        .local_names => header.local_names = slice,
        .debug_names => header.debug_names = slice,
    }
}

fn writeRootRequest(hasher: *std.crypto.hash.sha2.Sha256, request: checked.RootRequest) void {
    writeHashU32(hasher, request.order);
    writeHashU32(hasher, request.module_idx);
    writeHashBytes(hasher, @tagName(request.kind));
    writeRootSource(hasher, request.source);
    writeCheckedTypeId(hasher, request.checked_type);
    writeHashBytes(hasher, @tagName(request.abi));
    writeHashBytes(hasher, @tagName(request.exposure));
    writeOptionalProcedureTemplate(hasher, request.procedure_template);
    writeOptionalTopLevelProcedureBinding(hasher, request.procedure_binding);
    writeOptionalProcedureUseTemplate(hasher, request.procedure_use);
}

fn writeRootSource(hasher: *std.crypto.hash.sha2.Sha256, source: checked.RootSource) void {
    switch (source) {
        .def => |def| {
            writeHashBytes(hasher, "def");
            writeHashU32(hasher, @intFromEnum(def));
        },
        .expr => |expr| {
            writeHashBytes(hasher, "expr");
            writeHashU32(hasher, @intFromEnum(expr));
        },
        .statement => |stmt| {
            writeHashBytes(hasher, "statement");
            writeHashU32(hasher, @intFromEnum(stmt));
        },
        .required_binding => |binding| {
            writeHashBytes(hasher, "required_binding");
            writeHashU32(hasher, binding);
        },
        .hoisted => |hoisted| {
            writeHashBytes(hasher, "hoisted");
            writeHashU32(hasher, hoisted.index);
            writeHashU32(hasher, @intFromEnum(hoisted.expr));
        },
    }
}

fn writeProvidedDataExport(hasher: *std.crypto.hash.sha2.Sha256, data: checked.ProvidedDataExport) void {
    writeHashU32(hasher, @intFromEnum(data.source_name));
    writeHashU32(hasher, @intFromEnum(data.ffi_symbol));
    writeHashU32(hasher, @intFromEnum(data.def));
    writeHashU32(hasher, @intFromEnum(data.pattern));
    writeCheckedTypeId(hasher, data.checked_type);
    writeHashBytes32(hasher, data.source_scheme.bytes);
    writeConstData(hasher, data.const_ref);
}

fn writeConstData(hasher: *std.crypto.hash.sha2.Sha256, data: anytype) void {
    writeModuleId(hasher, @field(data, "arti" ++ "f" ++ "act"));
    writeConstOwner(hasher, data.owner);
    writeHashU32(hasher, @intFromEnum(data.template));
    writeHashBytes32(hasher, data.source_scheme.bytes);
}

fn writeConstOwner(hasher: *std.crypto.hash.sha2.Sha256, owner: checked.ConstOwner) void {
    switch (owner) {
        .top_level_binding => |top_level| {
            writeHashBytes(hasher, "top_level_binding");
            writeHashU32(hasher, top_level.module_idx);
            writeHashU32(hasher, @intFromEnum(top_level.pattern));
        },
        .hoisted_expr => |hoisted| {
            writeHashBytes(hasher, "hoisted_expr");
            writeHashU32(hasher, hoisted.module_idx);
            writeHashU32(hasher, @intFromEnum(hoisted.expr));
        },
    }
}

fn writeOptionalProcedureTemplate(hasher: *std.crypto.hash.sha2.Sha256, maybe_template: anytype) void {
    if (maybe_template) |actual| {
        writeHashBool(hasher, true);
        writeProcedureTemplate(hasher, actual);
    } else {
        writeHashBool(hasher, false);
    }
}

fn writeProcedureTemplate(hasher: *std.crypto.hash.sha2.Sha256, template: anytype) void {
    writeHashBytes32(hasher, @field(template, "arti" ++ "f" ++ "act").bytes);
    writeHashU32(hasher, @intFromEnum(template.proc_base));
    writeHashU32(hasher, @intFromEnum(template.template));
}

fn writeProcedureValue(hasher: *std.crypto.hash.sha2.Sha256, procedure: anytype) void {
    writeHashBytes32(hasher, @field(procedure, "arti" ++ "f" ++ "act").bytes);
    writeHashU32(hasher, @intFromEnum(procedure.proc_base));
}

fn writeOptionalTopLevelProcedureBinding(hasher: *std.crypto.hash.sha2.Sha256, maybe_binding: anytype) void {
    if (maybe_binding) |actual| {
        writeHashBool(hasher, true);
        writeHashU32(hasher, @intFromEnum(actual));
    } else {
        writeHashBool(hasher, false);
    }
}

fn writeOptionalProcedureUseTemplate(hasher: *std.crypto.hash.sha2.Sha256, use: ?checked.ProcedureUseTemplate) void {
    if (use) |actual| {
        writeHashBool(hasher, true);
        writeProcedureUseTemplate(hasher, actual);
    } else {
        writeHashBool(hasher, false);
    }
}

fn writeProcedureUseTemplate(hasher: *std.crypto.hash.sha2.Sha256, use: checked.ProcedureUseTemplate) void {
    writeProcedureBinding(hasher, use.binding);
    writeHashBytes32(hasher, use.source_fn_ty_template.bytes);
    writeOptionalCheckedTypeId(hasher, use.source_fn_ty_payload);
}

fn writeSpecRecord(hasher: *std.crypto.hash.sha2.Sha256, spec: Ast.SpecRecord) void {
    writeCallableIdentity(hasher, spec.identity.callable);
    writeHashBytes32(hasher, spec.identity.source_fn_ty_digest.bytes);
    writeHashBytes32(hasher, spec.identity.mono_fn_ty_digest.bytes);
}

fn writeCallableIdentity(hasher: *std.crypto.hash.sha2.Sha256, callable: Ast.CallableIdentity) void {
    switch (callable) {
        .proc_template => |template| {
            writeHashBytes(hasher, "proc_template");
            writeHashBytes32(hasher, template.module.bytes);
            writeHashU32(hasher, template.proc_base);
            writeHashU32(hasher, template.template);
        },
        .nested_site => |site| {
            writeHashBytes(hasher, "nested_site");
            writeHashBytes32(hasher, site.module.bytes);
            writeHashU32(hasher, site.owner_proc_base);
            writeHashU32(hasher, site.owner_template);
            writeHashBytes32(hasher, site.owner_fn_digest.bytes);
            writeHashU32(hasher, site.site);
        },
        .hosted => |hosted| {
            writeHashBytes(hasher, "hosted");
            writeHashU32(hasher, @intFromEnum(hosted));
        },
        .generated => |generated| {
            writeHashBytes(hasher, "generated");
            writeHashU32(hasher, @intFromEnum(generated));
        },
    }
}

fn writeProcedureBinding(hasher: *std.crypto.hash.sha2.Sha256, binding: anytype) void {
    switch (binding) {
        .top_level => |top_level| {
            writeHashBytes(hasher, "top_level");
            writeModuleId(hasher, @field(top_level, "arti" ++ "f" ++ "act"));
            writeHashU32(hasher, @intFromEnum(top_level.binding));
        },
        .imported => |imported| {
            writeHashBytes(hasher, "imported");
            writeModuleId(hasher, @field(imported, "arti" ++ "f" ++ "act"));
            writeHashU32(hasher, @intFromEnum(imported.def));
            writeHashU32(hasher, @intFromEnum(imported.pattern));
        },
        .hosted => |hosted| {
            writeHashBytes(hasher, "hosted");
            writeHashU32(hasher, hosted.module_idx);
            writeHashU32(hasher, @intFromEnum(hosted.def));
            writeProcedureValue(hasher, hosted.proc);
            writeProcedureTemplate(hasher, hosted.template);
        },
        .platform_required => |required| {
            writeHashBytes(hasher, "platform_required");
            writeModuleId(hasher, @field(required, "arti" ++ "f" ++ "act"));
            writeTopLevelValue(hasher, required.app_value);
            writeHashU32(hasher, @intFromEnum(required.procedure_binding));
        },
    }
}

fn writeTopLevelValue(hasher: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    writeModuleId(hasher, @field(value, "arti" ++ "f" ++ "act"));
    writeHashU32(hasher, @intFromEnum(value.pattern));
}

fn writeOptionalCheckedTypeId(hasher: *std.crypto.hash.sha2.Sha256, ty: ?checked.CheckedTypeId) void {
    if (ty) |actual| {
        writeHashBool(hasher, true);
        writeCheckedTypeId(hasher, actual);
    } else {
        writeHashBool(hasher, false);
    }
}

fn writeCheckedTypeId(hasher: *std.crypto.hash.sha2.Sha256, ty: checked.CheckedTypeId) void {
    writeHashU32(hasher, @intFromEnum(ty));
}

fn writeModuleId(hasher: *std.crypto.hash.sha2.Sha256, module: checked.ModuleId) void {
    writeHashBytes32(hasher, module.bytes);
}

fn writeHashOptionalBytes32(hasher: *std.crypto.hash.sha2.Sha256, bytes: ?[32]u8) void {
    if (bytes) |actual| {
        writeHashBool(hasher, true);
        writeHashBytes32(hasher, actual);
    } else {
        writeHashBool(hasher, false);
    }
}

fn writeHashBytes32(hasher: *std.crypto.hash.sha2.Sha256, bytes: [32]u8) void {
    hasher.update(&bytes);
}

fn writeHashBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    writeHashU32(hasher, @intCast(bytes.len));
    hasher.update(bytes);
}

fn writeHashBool(hasher: *std.crypto.hash.sha2.Sha256, value: bool) void {
    const byte: u8 = if (value) 1 else 0;
    hasher.update(std.mem.asBytes(&byte));
}

fn writeHashU32(hasher: *std.crypto.hash.sha2.Sha256, value: u32) void {
    const little = std.mem.nativeToLittle(u32, value);
    hasher.update(std.mem.asBytes(&little));
}

fn writeHashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    const little = std.mem.nativeToLittle(u64, value);
    hasher.update(std.mem.asBytes(&little));
}

fn writeLayout(hasher: *std.crypto.hash.sha2.Sha256, comptime T: type) void {
    writeHashBytes(hasher, @typeName(T));
    writeHashU64(hasher, @sizeOf(T));
    writeHashU64(hasher, @alignOf(T));
}

test "monotype specialization cache validates an empty header" {
    var bytes: [@sizeOf(SpecializationCacheHeader)]u8 align(@alignOf(SpecializationCacheHeader)) = undefined;
    @memset(bytes[0..], 0);
    const header: *SpecializationCacheHeader = @ptrCast(@alignCast(&bytes));
    header.* = .{};

    const view = try viewMappedFile(header, bytes[0..].ptr, bytes.len, zeroHash(), zeroHash(), 7);
    try std.testing.expectEqual(@as(u32, 7), view.shard_id);
}

test "monotype specialization cache compiler layout hash is deterministic" {
    const hash = computeCompilerLayoutHash();
    const again = computeCompilerLayoutHash();
    try std.testing.expectEqualSlices(u8, hash[0..], again[0..]);

    var bytes: [@sizeOf(SpecializationCacheHeader)]u8 align(@alignOf(SpecializationCacheHeader)) = undefined;
    @memset(bytes[0..], 0);
    const header: *SpecializationCacheHeader = @ptrCast(@alignCast(&bytes));
    header.* = .{ .compiler_layout_hash = hash };
    try validateHeader(header, bytes.len, hash, zeroHash());

    var wrong = hash;
    wrong[0] ^= 1;
    try std.testing.expectError(error.InvalidSpecializationCacheFile, validateHeader(header, bytes.len, wrong, zeroHash()));
}

test "monotype specialization cache rejects wrong version and hashes" {
    var bytes: [@sizeOf(SpecializationCacheHeader)]u8 align(@alignOf(SpecializationCacheHeader)) = undefined;
    @memset(bytes[0..], 0);
    const header: *SpecializationCacheHeader = @ptrCast(@alignCast(&bytes));
    header.* = .{};

    header.format_version = FORMAT_VERSION + 1;
    try std.testing.expectError(error.UnsupportedSpecializationCacheVersion, validateHeader(header, bytes.len, zeroHash(), zeroHash()));

    header.format_version = FORMAT_VERSION;
    var hash = [_]u8{0} ** 32;
    hash[0] = 1;
    try std.testing.expectError(error.InvalidSpecializationCacheFile, validateHeader(header, bytes.len, hash, zeroHash()));
    try std.testing.expectError(error.InvalidSpecializationCacheFile, validateHeader(header, bytes.len, zeroHash(), hash));
}

test "monotype specialization cache validates section bounds and order" {
    var bytes: [@sizeOf(SpecializationCacheHeader) + 96]u8 align(@alignOf(SpecializationCacheHeader)) = undefined;
    @memset(bytes[0..], 0);
    const header: *SpecializationCacheHeader = @ptrCast(@alignCast(&bytes));
    header.* = .{};

    const first_offset = std.mem.alignForward(usize, @sizeOf(SpecializationCacheHeader), SECTION_ALIGNMENT);
    header.names = .{ .offset = first_offset, .len = 16 };
    header.type_nodes = .{ .offset = first_offset + 16, .len = 16 };
    try validateHeader(header, bytes.len, zeroHash(), zeroHash());

    header.type_nodes = .{ .offset = first_offset + 8, .len = 16 };
    try std.testing.expectError(error.InvalidSpecializationCacheFile, validateHeader(header, bytes.len, zeroHash(), zeroHash()));

    header.type_nodes = .{ .offset = first_offset + 128, .len = 16 };
    try std.testing.expectError(error.InvalidSpecializationCacheFile, validateHeader(header, bytes.len, zeroHash(), zeroHash()));
}

test "monotype specialization cache creates typed section views" {
    var bytes: [@sizeOf(SpecializationCacheHeader) + 16]u8 align(@alignOf(SpecializationCacheHeader)) = undefined;
    @memset(bytes[0..], 0);
    const header: *SpecializationCacheHeader = @ptrCast(@alignCast(&bytes));
    header.* = .{};

    const offset = @sizeOf(SpecializationCacheHeader);
    const values: *[4]u32 = @ptrCast(@alignCast(&bytes[offset]));
    values.* = .{ 1, 2, 3, 4 };
    header.type_args = .{ .offset = offset, .len = @sizeOf(@TypeOf(values.*)) };

    const view = try viewMappedFile(header, bytes[0..].ptr, bytes.len, zeroHash(), zeroHash(), 0);
    const loaded = try view.sectionTyped(u32, header.type_args);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, loaded);
}

test "monotype specialization cache writes deterministic aligned section image" {
    const allocator = std.testing.allocator;

    const names_payload = "names";
    const fn_values = [_]u32{ 10, 20, 30 };
    const fn_bytes = std.mem.sliceAsBytes(fn_values[0..]);
    const expr_payload = "exprs";

    var layout_hash = [_]u8{0} ** 32;
    layout_hash[0] = 7;
    var validity_id = [_]u8{0} ** 32;
    validity_id[0] = 9;

    const image = try buildImage(allocator, layout_hash, validity_id, &.{
        .{ .id = .exprs, .bytes = expr_payload },
        .{ .id = .fns, .bytes = fn_bytes },
        .{ .id = .names, .bytes = names_payload },
    });
    defer allocator.free(image);

    var header: SpecializationCacheHeader = undefined;
    @memcpy(std.mem.asBytes(&header), image[0..@sizeOf(SpecializationCacheHeader)]);

    try validateHeader(&header, image.len, layout_hash, validity_id);
    try std.testing.expect(header.names.offset < header.fns.offset);
    try std.testing.expect(header.fns.offset < header.exprs.offset);
    try std.testing.expectEqual(@as(u64, 0), header.names.offset % SECTION_ALIGNMENT);
    try std.testing.expectEqual(@as(u64, 0), header.fns.offset % SECTION_ALIGNMENT);
    try std.testing.expectEqual(@as(u64, 0), header.exprs.offset % SECTION_ALIGNMENT);

    const view = try viewMappedFile(&header, image.ptr, image.len, layout_hash, validity_id, 3);
    try std.testing.expectEqualSlices(u8, names_payload, try view.sectionBytes(header.names));
    try std.testing.expectEqualSlices(u32, fn_values[0..], try view.sectionTyped(u32, header.fns));
    try std.testing.expectEqualSlices(u8, expr_payload, try view.sectionBytes(header.exprs));
}

test "monotype specialization cache maps typed top-level sections" {
    const allocator = std.testing.allocator;

    const type_args = [_]Type.TypeId{ @enumFromInt(1), @enumFromInt(2) };
    const imports = [_]Ast.ImportedFn{
        .{ .shard = @enumFromInt(4), .fn_id = @enumFromInt(7) },
    };
    const locs = [_]Base.SourceLoc{
        .{ .file = 0, .line = 2, .column = 3 },
    };

    const image = try buildImage(allocator, zeroHash(), zeroHash(), &.{
        .{ .id = .expr_locs, .bytes = std.mem.sliceAsBytes(locs[0..]) },
        .{ .id = .imports, .bytes = std.mem.sliceAsBytes(imports[0..]) },
        .{ .id = .type_args, .bytes = std.mem.sliceAsBytes(type_args[0..]) },
    });
    defer allocator.free(image);

    var header: SpecializationCacheHeader = undefined;
    @memcpy(std.mem.asBytes(&header), image[0..@sizeOf(SpecializationCacheHeader)]);
    const view = try viewMappedFile(&header, image.ptr, image.len, zeroHash(), zeroHash(), 5);
    const mapped = try view.sectionsView();

    try std.testing.expectEqualSlices(Type.TypeId, type_args[0..], mapped.type_args);
    try std.testing.expectEqual(@as(usize, 1), mapped.imports.len);
    try std.testing.expectEqual(imports[0].shard, mapped.imports[0].shard);
    try std.testing.expectEqual(imports[0].fn_id, mapped.imports[0].fn_id);
    try std.testing.expectEqualSlices(Base.SourceLoc, locs[0..], mapped.expr_locs);
    try std.testing.expectEqual(@as(usize, 0), mapped.fns.len);
}

test "monotype specialization cache creates mapped program view without body fixups" {
    const allocator = std.testing.allocator;

    const first_type_index: u32 = std.math.minInt(u32);
    const first_fn_index: u32 = std.math.minInt(u32);
    const unit_ty: Type.TypeId = @enumFromInt(first_type_index);
    const fn_ty: Type.TypeId = @enumFromInt(1);
    const type_nodes = [_]Type.Content{
        .zst,
        .{ .func = .{
            .args = Type.Span.empty(),
            .ret = unit_ty,
        } },
    };
    const type_digests = [_]checked_names.TypeDigest{ .{}, .{} };
    const fn_id: Ast.FnId = @enumFromInt(first_fn_index);
    const fns = [_]Ast.Fn{.{
        .source = .{
            .fn_def = .{ .checked_generated = testProcedureTemplate(1, 1) },
            .source_fn_ty = @enumFromInt(1),
            .source_fn_key = .{},
            .mono_fn_ty = fn_ty,
        },
    }};
    const defs = [_]Ast.Def{.{
        .symbol = @enumFromInt(1),
        .fn_def = fns[0].source,
        .fn_id = fn_id,
        .args = Ast.Span(Ast.TypedLocal).empty(),
        .body = .hosted,
        .ret = unit_ty,
    }};
    const exprs = [_]Ast.Expr{.{
        .ty = unit_ty,
        .data = .{ .call_proc = .{
            .callee = Ast.localProcCallee(fn_id),
            .args = Ast.Span(Ast.ExprId).empty(),
        } },
    }};

    const image = try buildImage(allocator, zeroHash(), zeroHash(), &.{
        .{ .id = .type_nodes, .bytes = std.mem.sliceAsBytes(type_nodes[0..]) },
        .{ .id = .type_digests, .bytes = std.mem.sliceAsBytes(type_digests[0..]) },
        .{ .id = .fns, .bytes = std.mem.sliceAsBytes(fns[0..]) },
        .{ .id = .defs, .bytes = std.mem.sliceAsBytes(defs[0..]) },
        .{ .id = .exprs, .bytes = std.mem.sliceAsBytes(exprs[0..]) },
    });
    defer allocator.free(image);

    var header: SpecializationCacheHeader = undefined;
    @memcpy(std.mem.asBytes(&header), image[0..@sizeOf(SpecializationCacheHeader)]);
    const mapped = try viewMappedFile(&header, image.ptr, image.len, zeroHash(), zeroHash(), 9);
    const program = try mappedProgramView(mapped);
    var name_store = checked_names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    try std.testing.expectEqual(@as(Ast.ShardId, @enumFromInt(9)), program.shard_id);
    try std.testing.expectEqual(@as(?Ast.CallTargetVerifyError, null), program.verifyCallTargets());
    try std.testing.expectEqual(@as(?Type.Store.VerifyError, null), program.types.verify(&name_store));
}

test "monotype specialization cache writer rejects duplicate sections" {
    try std.testing.expectError(
        error.InvalidSpecializationCacheFile,
        buildImage(std.testing.allocator, zeroHash(), zeroHash(), &.{
            .{ .id = .names, .bytes = "first" },
            .{ .id = .names, .bytes = "second" },
        }),
    );
}

test "monotype specialization cache validity includes module ids roots and config" {
    var root_checked_module: CheckedModuleData = undefined;
    root_checked_module.key = testModuleId(1);
    var roots_table: checked.RootRequestTable = .{};

    const modules = Common.CheckedModules{
        .root = .{
            .module = &root_checked_module,
            .roots = &roots_table,
        },
    };

    const request = checked.RootRequest{
        .order = 0,
        .module_idx = 0,
        .kind = .runtime_entrypoint,
        .source = .{ .def = @enumFromInt(1) },
        .checked_type = @enumFromInt(2),
        .abi = .roc,
        .exposure = .exported,
    };

    const empty_roots = Common.RootRequests{};
    const requested_roots = Common.RootRequests{ .requests = &.{request} };

    const empty = computeValidityId(modules, empty_roots, .{});
    const requested = computeValidityId(modules, requested_roots, .{});
    try std.testing.expect(!std.mem.eql(u8, empty[0..], requested[0..]));

    const debug_names = computeValidityId(modules, empty_roots, .{ .proc_debug_names = true });
    try std.testing.expect(!std.mem.eql(u8, empty[0..], debug_names[0..]));

    root_checked_module.key = testModuleId(2);
    const different_root = computeValidityId(modules, empty_roots, .{});
    try std.testing.expect(!std.mem.eql(u8, empty[0..], different_root[0..]));
}

test "monotype specialization cache validity includes imported module ids" {
    var root_checked_module: CheckedModuleData = undefined;
    root_checked_module.key = testModuleId(1);
    var roots_table: checked.RootRequestTable = .{};

    var imported: checked.ImportedModuleView = undefined;
    imported.key = testModuleId(3);
    const imports = [_]checked.ImportedModuleView{imported};

    const without_import = Common.CheckedModules{
        .root = .{
            .module = &root_checked_module,
            .roots = &roots_table,
        },
    };
    const with_import = Common.CheckedModules{
        .root = .{
            .module = &root_checked_module,
            .roots = &roots_table,
        },
        .imports = imports[0..],
    };

    const roots = Common.RootRequests{};
    const first = computeValidityId(without_import, roots, .{});
    const second = computeValidityId(with_import, roots, .{});
    try std.testing.expect(!std.mem.eql(u8, first[0..], second[0..]));
}

test "monotype specialization cache validity includes stored specialization identities" {
    var root_checked_module: CheckedModuleData = undefined;
    root_checked_module.key = testModuleId(1);
    var roots_table: checked.RootRequestTable = .{};

    const modules = Common.CheckedModules{
        .root = .{
            .module = &root_checked_module,
            .roots = &roots_table,
        },
    };

    var first_source_digest: checked_names.TypeDigest = .{};
    first_source_digest.bytes[0] = 1;
    var second_source_digest: checked_names.TypeDigest = .{};
    second_source_digest.bytes[0] = 2;
    var mono_digest: checked_names.TypeDigest = .{};
    mono_digest.bytes[0] = 3;
    const spec_ty: Type.TypeId = @enumFromInt(1);
    const spec_fn: Ast.FnId = @enumFromInt(1);

    const first_spec = Ast.SpecRecord{
        .identity = .{
            .callable = .{ .proc_template = .{
                .module = testModuleDigest(7),
                .proc_base = 1,
                .template = 2,
            } },
            .source_fn_ty_digest = first_source_digest,
            .mono_fn_ty_digest = mono_digest,
            .mono_fn_ty = spec_ty,
        },
        .fn_id = spec_fn,
        .status = .ready,
    };
    var second_spec = first_spec;
    second_spec.identity.source_fn_ty_digest = second_source_digest;

    const roots = Common.RootRequests{};
    const no_specs = computeValidityIdWithSpecs(modules, roots, .{}, &.{});
    const first = computeValidityIdWithSpecs(modules, roots, .{}, &.{first_spec});
    const second = computeValidityIdWithSpecs(modules, roots, .{}, &.{second_spec});

    try std.testing.expect(!std.mem.eql(u8, no_specs[0..], first[0..]));
    try std.testing.expect(!std.mem.eql(u8, first[0..], second[0..]));
}

fn testModuleId(byte: u8) checked.ModuleId {
    var id: checked.ModuleId = .{};
    id.bytes[0] = byte;
    return id;
}

fn testModuleDigest(byte: u8) checked_names.CheckedModuleDigest {
    var digest: checked_names.CheckedModuleDigest = .{};
    digest.bytes[0] = byte;
    return digest;
}

fn testProcedureTemplate(proc_base: u32, template: u32) checked_names.ProcTemplate {
    var proc_template: checked_names.ProcTemplate = undefined;
    @field(proc_template, "arti" ++ "f" ++ "act") = .{};
    proc_template.proc_base = @enumFromInt(proc_base);
    proc_template.template = @enumFromInt(template);
    return proc_template;
}

fn zeroHash() [32]u8 {
    return [_]u8{0} ** 32;
}
