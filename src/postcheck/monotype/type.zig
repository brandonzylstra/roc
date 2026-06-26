//! Monomorphic type store used by Monotype and Monotype Lifted IR.
//!
//! This store contains closed checked types after static dispatch and numeric
//! defaulting have been finalized. It has no lambda sets and no layout data.

const std = @import("std");
const check = @import("check");

const Common = @import("../common.zig");
const names = check.CheckedNames;
const checked = check.CheckedModule;
const static_dispatch = check.StaticDispatchRegistry;

/// Identifier for a monomorphic type in this store.
pub const TypeId = enum(u32) { _ };

/// Slice descriptor for type, field, or tag arrays in this store.
pub const SidePoolSpan = extern struct {
    start: u32,
    len: u32,

    pub fn empty() SidePoolSpan {
        return .{ .start = 0, .len = 0 };
    }
};

/// Compatibility name for existing Monotype type side-pool spans.
pub const Span = SidePoolSpan;

/// Cached structural digest stored beside a durable Monotype type node.
pub const MonoTypeDigest = names.TypeDigest;

/// Primitive type copied from checked module data.
pub const Primitive = checked.CheckedPrimitive;

/// Static-dispatch owner head for a monomorphic receiver type.
pub const OwnerHead = union(enum(u8)) {
    none,
    builtin: static_dispatch.BuiltinOwner,
    named_type: TypeDef,
};

/// Named type definition owner.
pub const TypeDef = struct {
    module_name: names.ModuleNameId,
    type_name: names.TypeNameId,
    source_decl: ?u32 = null,
};

/// Named checked type instance.
pub const NamedType = struct {
    module: names.CheckedModuleDigest,
    ty: checked.CheckedTypeId,
};

/// How much of a named type's backing type later stages may inspect.
pub const BackingUse = enum(u8) {
    inspectable,
    runtime_layout_only,
};

/// Backing type for a named type when checking output one.
pub const NamedBacking = struct {
    ty: TypeId,
    use: BackingUse,
};

/// Kind of named type visible after checking.
pub const NamedKind = enum(u8) {
    nominal,
    @"opaque",
    alias,
};

/// Record field type entry.
pub const MonoTypeField = struct {
    name: names.RecordFieldNameId,
    ty: TypeId,
};

/// Compatibility name for existing Monotype record field entries.
pub const Field = MonoTypeField;

/// Tag-union variant type entry.
pub const MonoTypeTag = struct {
    name: names.TagNameId,
    checked_name: names.TagNameId,
    payloads: Span,
};

/// Compatibility name for existing Monotype tag-union variant entries.
pub const Tag = MonoTypeTag;

/// One entry of a nominal record's declared layout order. The backing row is
/// always lexicographic (for name resolution and digests); a nominal type
/// additionally carries this declared order, which the layout commit consumes to
/// place fields in source order with no internal padding. See design.md
/// "Nominal Record Field Order".
pub const DeclaredField = union(enum(u8)) {
    /// A named backing field, matched against the lexicographic backing row by
    /// name at layout time.
    named: names.RecordFieldNameId,
    /// An unnamed padding field reserving `sizeof(ty)` bytes at alignment 1. Its
    /// bytes are uninitialized and it is not accessible.
    padding: TypeId,
};

/// Durable monomorphic type node.
pub const MonoTypeNode = union(enum(u8)) {
    primitive: Primitive,
    named: struct {
        named_type: NamedType,
        def: TypeDef,
        kind: NamedKind,
        builtin_owner: ?static_dispatch.BuiltinOwner = null,
        args: Span,
        backing: ?NamedBacking = null,
        /// Declared field order for a nominal/opaque record backing; empty for
        /// every other named type (consumed only by layout).
        declared_order: Span = Span.empty(),
    },
    record: Span,
    tuple: Span,
    tag_union: Span,
    list: TypeId,
    box: TypeId,
    func: struct {
        args: Span,
        ret: TypeId,
    },
    erased: names.TypeDigest,
    zst,
};

/// Compatibility name for existing Monotype type-node content.
pub const Content = MonoTypeNode;

/// Payload stored by `MonoTypeNode.named`.
pub const NamedContent = std.meta.fieldInfo(MonoTypeNode, .named).type;

/// Store for monomorphic types and their shared spans.
pub const Store = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(Content),
    type_digests: std.ArrayList(?names.TypeDigest),
    spans: std.ArrayList(TypeId),
    fields: std.ArrayList(Field),
    tags: std.ArrayList(Tag),
    declared_fields: std.ArrayList(DeclaredField),
    frozen: bool,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .types = .empty,
            .type_digests = .empty,
            .spans = .empty,
            .fields = .empty,
            .tags = .empty,
            .declared_fields = .empty,
            .frozen = false,
        };
    }

    pub fn deinit(self: *Store) void {
        self.declared_fields.deinit(self.allocator);
        self.tags.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.type_digests.deinit(self.allocator);
        self.types.deinit(self.allocator);
    }

    pub fn freeze(self: *Store) void {
        self.frozen = true;
    }

    pub fn isFrozen(self: *const Store) bool {
        return self.frozen;
    }

    pub fn addSpan(self: *Store, values: []const TypeId) std.mem.Allocator.Error!Span {
        self.assertMutable();
        if (values.len == 0) return .empty();
        const start: u32 = @intCast(self.spans.items.len);
        try self.spans.appendSlice(self.allocator, values);
        return .{ .start = start, .len = @intCast(values.len) };
    }

    pub fn addFields(self: *Store, values: []const Field) std.mem.Allocator.Error!Span {
        self.assertMutable();
        if (values.len == 0) return .empty();
        const start: u32 = @intCast(self.fields.items.len);
        try self.fields.appendSlice(self.allocator, values);
        return .{ .start = start, .len = @intCast(values.len) };
    }

    /// Normalize record fields by label text before appending a durable span.
    pub fn addRecordFields(self: *Store, name_store: *const names.NameStore, values: []const Field) std.mem.Allocator.Error!Span {
        if (values.len == 0) return .empty();
        const normalized = try self.allocator.dupe(Field, values);
        defer self.allocator.free(normalized);
        std.mem.sort(Field, normalized, name_store, recordFieldLessThan);
        assertNoDuplicateRecordFields(name_store, normalized);
        return try self.addFields(normalized);
    }

    pub fn addTags(self: *Store, values: []const Tag) std.mem.Allocator.Error!Span {
        self.assertMutable();
        if (values.len == 0) return .empty();
        const start: u32 = @intCast(self.tags.items.len);
        try self.tags.appendSlice(self.allocator, values);
        return .{ .start = start, .len = @intCast(values.len) };
    }

    /// Normalize tag-union variants by label text before appending a durable span.
    pub fn addTagVariants(self: *Store, name_store: *const names.NameStore, values: []const Tag) std.mem.Allocator.Error!Span {
        if (values.len == 0) return .empty();
        const normalized = try self.allocator.dupe(Tag, values);
        defer self.allocator.free(normalized);
        std.mem.sort(Tag, normalized, name_store, tagLessThan);
        assertNoDuplicateTags(name_store, normalized);
        return try self.addTags(normalized);
    }

    pub fn add(self: *Store, content: Content) std.mem.Allocator.Error!TypeId {
        self.assertMutable();
        const index = self.types.items.len;
        try self.types.append(self.allocator, content);
        errdefer _ = self.types.pop();
        try self.type_digests.append(self.allocator, null);
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn set(self: *Store, ty: TypeId, content: Content) void {
        self.assertMutable();
        self.types.items[@intFromEnum(ty)] = content;
        self.clearTypeDigestCache();
    }

    pub fn get(self: *const Store, ty: TypeId) Content {
        return self.types.items[@intFromEnum(ty)];
    }

    pub fn span(self: *const Store, span_: Span) []const TypeId {
        return self.spans.items[span_.start..][0..span_.len];
    }

    pub fn fieldSpan(self: *const Store, span_: Span) []const Field {
        return self.fields.items[span_.start..][0..span_.len];
    }

    pub fn tagSpan(self: *const Store, span_: Span) []const Tag {
        return self.tags.items[span_.start..][0..span_.len];
    }

    pub fn addDeclaredFields(self: *Store, values: []const DeclaredField) std.mem.Allocator.Error!Span {
        self.assertMutable();
        if (values.len == 0) return .empty();
        const start: u32 = @intCast(self.declared_fields.items.len);
        try self.declared_fields.appendSlice(self.allocator, values);
        return .{ .start = start, .len = @intCast(values.len) };
    }

    pub fn declaredFieldSpan(self: *const Store, span_: Span) []const DeclaredField {
        return self.declared_fields.items[span_.start..][0..span_.len];
    }

    const Mark = struct {
        types_len: usize,
        type_digests_len: usize,
        spans_len: usize,
        fields_len: usize,
        tags_len: usize,
        declared_fields_len: usize,
    };

    fn mark(self: *const Store) Mark {
        return .{
            .types_len = self.types.items.len,
            .type_digests_len = self.type_digests.items.len,
            .spans_len = self.spans.items.len,
            .fields_len = self.fields.items.len,
            .tags_len = self.tags.items.len,
            .declared_fields_len = self.declared_fields.items.len,
        };
    }

    fn restore(self: *Store, mark_: Mark) void {
        self.assertMutable();
        self.types.items.len = mark_.types_len;
        self.type_digests.items.len = mark_.type_digests_len;
        self.spans.items.len = mark_.spans_len;
        self.fields.items.len = mark_.fields_len;
        self.tags.items.len = mark_.tags_len;
        self.declared_fields.items.len = mark_.declared_fields_len;
    }

    pub fn ownerHead(self: *const Store, ty: TypeId) OwnerHead {
        return switch (self.get(ty)) {
            .primitive => |primitive| .{ .builtin = builtinOwner(primitive) },
            .list => .{ .builtin = .list },
            .box => .{ .builtin = .box },
            .named => |named| if (named.builtin_owner) |owner|
                .{ .builtin = owner }
            else if (named.kind == .alias)
                // Aliases are transparent for static dispatch: the owner is the
                // backing's owner, mirroring the alias-transparent digest path
                // above. This unwraps alias-over-alias and alias-over-nominal
                // uniformly (the backing of an alias-over-nominal is itself a
                // `named` node carrying the nominal's owner). The recursion
                // terminates because alias chains in checked output are finite.
                (if (named.backing) |backing|
                    self.ownerHead(backing.ty)
                else
                    .none)
            else
                .{ .named_type = named.def },
            else => .none,
        };
    }

    pub fn typeDigest(self: *const Store, name_store: *const names.NameStore, ty: TypeId) names.TypeDigest {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var visiting = DigestVisiting{};
        self.writeTypeDigest(name_store, &hasher, ty, &visiting);
        return .{ .bytes = hasher.finalResult() };
    }

    pub const DigestStats = struct {
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,
        nodes_visited: u64 = 0,
    };

    pub const VerifyError = enum {
        type_digest_count_mismatch,
        type_span_out_of_bounds,
        field_span_out_of_bounds,
        tag_span_out_of_bounds,
        declared_field_span_out_of_bounds,
        type_ref_out_of_bounds,
        record_fields_not_sorted,
        tag_union_tags_not_sorted,
    };

    pub const View = struct {
        types: []const Content,
        type_digests: []const ?names.TypeDigest,
        spans: []const TypeId,
        fields: []const Field,
        tags: []const Tag,
        declared_fields: []const DeclaredField,
        frozen: bool,

        pub fn get(self: View, ty: TypeId) Content {
            return self.types[@intFromEnum(ty)];
        }

        pub fn span(self: View, span_: Span) []const TypeId {
            return self.spans[span_.start..][0..span_.len];
        }

        pub fn fieldSpan(self: View, span_: Span) []const Field {
            return self.fields[span_.start..][0..span_.len];
        }

        pub fn tagSpan(self: View, span_: Span) []const Tag {
            return self.tags[span_.start..][0..span_.len];
        }

        pub fn declaredFieldSpan(self: View, span_: Span) []const DeclaredField {
            return self.declared_fields[span_.start..][0..span_.len];
        }

        pub fn verify(self: View, name_store: *const names.NameStore) ?VerifyError {
            if (self.type_digests.len != self.types.len) return .type_digest_count_mismatch;

            for (self.spans) |ty| {
                if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds;
            }
            for (self.fields) |field| {
                if (!self.typeRefInBounds(field.ty)) return .type_ref_out_of_bounds;
            }
            for (self.tags) |tag| {
                if (!self.spanInBounds(self.spans.len, tag.payloads)) return .type_span_out_of_bounds;
                if (self.verifyTypeSpan(tag.payloads)) |err| return err;
            }
            for (self.declared_fields) |field| {
                switch (field) {
                    .named => {},
                    .padding => |ty| if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds,
                }
            }

            for (self.types) |content| {
                switch (content) {
                    .primitive, .erased, .zst => {},
                    .list, .box => |ty| if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds,
                    .tuple => |span_| if (self.verifyTypeSpan(span_)) |err| return err,
                    .record => |span_| if (self.verifyFieldSpan(name_store, span_)) |err| return err,
                    .tag_union => |span_| if (self.verifyTagSpan(name_store, span_)) |err| return err,
                    .func => |func| {
                        if (self.verifyTypeSpan(func.args)) |err| return err;
                        if (!self.typeRefInBounds(func.ret)) return .type_ref_out_of_bounds;
                    },
                    .named => |named| {
                        if (self.verifyTypeSpan(named.args)) |err| return err;
                        if (named.backing) |backing| {
                            if (!self.typeRefInBounds(backing.ty)) return .type_ref_out_of_bounds;
                        }
                        if (self.verifyDeclaredFieldSpan(named.declared_order)) |err| return err;
                    },
                }
            }

            return null;
        }

        fn typeRefInBounds(self: View, ty: TypeId) bool {
            return @intFromEnum(ty) < self.types.len;
        }

        fn spanInBounds(_: View, len: usize, span_: Span) bool {
            const start: usize = span_.start;
            const span_len: usize = span_.len;
            return start <= len and span_len <= len - start;
        }

        fn verifyTypeSpan(self: View, span_: Span) ?VerifyError {
            if (!self.spanInBounds(self.spans.len, span_)) return .type_span_out_of_bounds;
            for (self.span(span_)) |ty| {
                if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds;
            }
            return null;
        }

        fn verifyFieldSpan(self: View, name_store: *const names.NameStore, span_: Span) ?VerifyError {
            if (!self.spanInBounds(self.fields.len, span_)) return .field_span_out_of_bounds;
            const fields_ = self.fieldSpan(span_);
            for (fields_) |field| {
                if (!self.typeRefInBounds(field.ty)) return .type_ref_out_of_bounds;
            }
            if (fields_.len > 1) {
                for (fields_[1..], 1..) |field, index| {
                    if (!name_store.recordFieldLabelTextLessThan(fields_[index - 1].name, field.name)) {
                        return .record_fields_not_sorted;
                    }
                }
            }
            return null;
        }

        fn verifyTagSpan(self: View, name_store: *const names.NameStore, span_: Span) ?VerifyError {
            if (!self.spanInBounds(self.tags.len, span_)) return .tag_span_out_of_bounds;
            const tags_ = self.tagSpan(span_);
            for (tags_) |tag| {
                if (self.verifyTypeSpan(tag.payloads)) |err| return err;
            }
            if (tags_.len > 1) {
                for (tags_[1..], 1..) |tag, index| {
                    if (!name_store.tagLabelTextLessThan(tags_[index - 1].name, tag.name)) {
                        return .tag_union_tags_not_sorted;
                    }
                }
            }
            return null;
        }

        fn verifyDeclaredFieldSpan(self: View, span_: Span) ?VerifyError {
            if (!self.spanInBounds(self.declared_fields.len, span_)) return .declared_field_span_out_of_bounds;
            for (self.declaredFieldSpan(span_)) |field| {
                switch (field) {
                    .named => {},
                    .padding => |ty| if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds,
                }
            }
            return null;
        }
    };

    pub fn view(self: *const Store) View {
        return .{
            .types = self.types.items,
            .type_digests = self.type_digests.items,
            .spans = self.spans.items,
            .fields = self.fields.items,
            .tags = self.tags.items,
            .declared_fields = self.declared_fields.items,
            .frozen = self.frozen,
        };
    }

    pub fn verify(self: *const Store, name_store: *const names.NameStore) ?VerifyError {
        return self.view().verify(name_store);
    }

    pub fn typeDigestCached(
        self: *Store,
        name_store: *const names.NameStore,
        ty: TypeId,
        stats: ?*DigestStats,
    ) names.TypeDigest {
        var ctx = CachedDigestContext{};
        return self.cachedDigestInner(name_store, ty, &ctx, stats);
    }

    /// Exact structural equality for closed Monotype types.
    ///
    /// This mirrors the intentional identity rules used by `typeDigest`:
    /// aliases with backing compare as their backing, non-alias named types
    /// compare by named identity and arguments, and structural rows compare by
    /// label text and ordered children. Unlike the digest, this is authoritative
    /// and must be checked before one specialization can reuse another.
    pub fn typeEql(
        self: *const Store,
        name_store: *const names.NameStore,
        lhs: TypeId,
        rhs: TypeId,
    ) std.mem.Allocator.Error!bool {
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();
        return try self.typeEqlInner(name_store, lhs, rhs, &visited);
    }

    fn typeEqlInner(
        self: *const Store,
        name_store: *const names.NameStore,
        raw_lhs: TypeId,
        raw_rhs: TypeId,
        visited: *std.AutoHashMap(u64, void),
    ) std.mem.Allocator.Error!bool {
        if (raw_lhs == raw_rhs) return true;

        const lhs_content = self.get(raw_lhs);
        if (lhs_content == .named and lhs_content.named.kind == .alias) {
            if (lhs_content.named.backing) |backing| {
                return try self.typeEqlInner(name_store, backing.ty, raw_rhs, visited);
            }
        }

        const rhs_content = self.get(raw_rhs);
        if (rhs_content == .named and rhs_content.named.kind == .alias) {
            if (rhs_content.named.backing) |backing| {
                return try self.typeEqlInner(name_store, raw_lhs, backing.ty, visited);
            }
        }

        const pair = typePair(raw_lhs, raw_rhs);
        const gop = try visited.getOrPut(pair);
        if (gop.found_existing) return true;

        return switch (lhs_content) {
            .primitive => |lhs| switch (rhs_content) {
                .primitive => |rhs| lhs == rhs,
                else => false,
            },
            .named => |lhs| switch (rhs_content) {
                .named => |rhs| try self.namedTypeEql(name_store, lhs, rhs, visited),
                else => false,
            },
            .record => |lhs| switch (rhs_content) {
                .record => |rhs| try self.fieldSpanEql(name_store, lhs, rhs, visited),
                else => false,
            },
            .tuple => |lhs| switch (rhs_content) {
                .tuple => |rhs| try self.typeSpanEql(name_store, lhs, rhs, visited),
                else => false,
            },
            .tag_union => |lhs| switch (rhs_content) {
                .tag_union => |rhs| try self.tagSpanEql(name_store, lhs, rhs, visited),
                else => false,
            },
            .list => |lhs| switch (rhs_content) {
                .list => |rhs| try self.typeEqlInner(name_store, lhs, rhs, visited),
                else => false,
            },
            .box => |lhs| switch (rhs_content) {
                .box => |rhs| try self.typeEqlInner(name_store, lhs, rhs, visited),
                else => false,
            },
            .func => |lhs| switch (rhs_content) {
                .func => |rhs| blk: {
                    if (!try self.typeSpanEql(name_store, lhs.args, rhs.args, visited)) break :blk false;
                    break :blk try self.typeEqlInner(name_store, lhs.ret, rhs.ret, visited);
                },
                else => false,
            },
            .erased => |lhs| switch (rhs_content) {
                .erased => |rhs| std.mem.eql(u8, lhs.bytes[0..], rhs.bytes[0..]),
                else => false,
            },
            .zst => rhs_content == .zst,
        };
    }

    fn namedTypeEql(
        self: *const Store,
        name_store: *const names.NameStore,
        lhs: anytype,
        rhs: anytype,
        visited: *std.AutoHashMap(u64, void),
    ) std.mem.Allocator.Error!bool {
        if (lhs.kind != rhs.kind) return false;
        if (!std.mem.eql(u8, lhs.named_type.module.bytes[0..], rhs.named_type.module.bytes[0..])) return false;
        if (!std.mem.eql(u8, name_store.moduleNameText(lhs.def.module_name), name_store.moduleNameText(rhs.def.module_name))) return false;
        if (lhs.def.source_decl != rhs.def.source_decl) return false;
        if (lhs.def.source_decl == null and
            !std.mem.eql(u8, name_store.typeNameText(lhs.def.type_name), name_store.typeNameText(rhs.def.type_name)))
        {
            return false;
        }
        if (lhs.builtin_owner != rhs.builtin_owner) return false;
        if (!try self.typeSpanEql(name_store, lhs.args, rhs.args, visited)) return false;

        if (lhs.kind == .alias) {
            const lhs_backing = lhs.backing orelse return rhs.backing == null;
            const rhs_backing = rhs.backing orelse return false;
            return try self.typeEqlInner(name_store, lhs_backing.ty, rhs_backing.ty, visited);
        }

        if (lhs.builtin_owner) |owner| {
            if (owner == .fields) {
                const lhs_backing = lhs.backing orelse return rhs.backing == null;
                const rhs_backing = rhs.backing orelse return false;
                return try self.typeEqlInner(name_store, lhs_backing.ty, rhs_backing.ty, visited);
            }
        }

        return true;
    }

    fn typeSpanEql(
        self: *const Store,
        name_store: *const names.NameStore,
        lhs_span: Span,
        rhs_span: Span,
        visited: *std.AutoHashMap(u64, void),
    ) std.mem.Allocator.Error!bool {
        const lhs = self.span(lhs_span);
        const rhs = self.span(rhs_span);
        if (lhs.len != rhs.len) return false;
        for (lhs, rhs) |lhs_ty, rhs_ty| {
            if (!try self.typeEqlInner(name_store, lhs_ty, rhs_ty, visited)) return false;
        }
        return true;
    }

    fn fieldSpanEql(
        self: *const Store,
        name_store: *const names.NameStore,
        lhs_span: Span,
        rhs_span: Span,
        visited: *std.AutoHashMap(u64, void),
    ) std.mem.Allocator.Error!bool {
        const lhs = self.fieldSpan(lhs_span);
        const rhs = self.fieldSpan(rhs_span);
        if (lhs.len != rhs.len) return false;
        for (lhs, rhs) |lhs_field, rhs_field| {
            if (!std.mem.eql(u8, name_store.recordFieldLabelText(lhs_field.name), name_store.recordFieldLabelText(rhs_field.name))) return false;
            if (!try self.typeEqlInner(name_store, lhs_field.ty, rhs_field.ty, visited)) return false;
        }
        return true;
    }

    fn tagSpanEql(
        self: *const Store,
        name_store: *const names.NameStore,
        lhs_span: Span,
        rhs_span: Span,
        visited: *std.AutoHashMap(u64, void),
    ) std.mem.Allocator.Error!bool {
        const lhs = self.tagSpan(lhs_span);
        const rhs = self.tagSpan(rhs_span);
        if (lhs.len != rhs.len) return false;
        for (lhs, rhs) |lhs_tag, rhs_tag| {
            if (!std.mem.eql(u8, name_store.tagLabelText(lhs_tag.name), name_store.tagLabelText(rhs_tag.name))) return false;
            if (!try self.typeSpanEql(name_store, lhs_tag.payloads, rhs_tag.payloads, visited)) return false;
        }
        return true;
    }

    fn typePair(lhs: TypeId, rhs: TypeId) u64 {
        const lhs_int = @intFromEnum(lhs);
        const rhs_int = @intFromEnum(rhs);
        const low = @min(lhs_int, rhs_int);
        const high = @max(lhs_int, rhs_int);
        return (@as(u64, low) << 32) | @as(u64, high);
    }

    /// Stack of types currently being digested. Recursive types reference a
    /// type already on this stack; the digest encodes such a back reference by
    /// stack position so cyclic content digests deterministically.
    const DigestVisiting = struct {
        items: [digest_visiting_max]TypeId = undefined,
        len: usize = 0,
    };

    const digest_visiting_max = 256;

    const CachedDigestContext = struct {
        items: [digest_visiting_max]TypeId = undefined,
        len: usize = 0,
        saw_cycle: bool = false,
    };

    fn clearTypeDigestCache(self: *Store) void {
        @memset(self.type_digests.items, null);
    }

    fn assertMutable(self: *const Store) void {
        if (self.frozen) Common.invariant("frozen Monotype type store cannot be mutated");
    }

    fn typeRefInBounds(self: *const Store, ty: TypeId) bool {
        return @intFromEnum(ty) < self.types.items.len;
    }

    fn spanInBounds(_: *const Store, len: usize, span_: Span) bool {
        const start: usize = span_.start;
        const span_len: usize = span_.len;
        return start <= len and span_len <= len - start;
    }

    fn verifyTypeSpan(self: *const Store, span_: Span) ?VerifyError {
        if (!self.spanInBounds(self.spans.items.len, span_)) return .type_span_out_of_bounds;
        for (self.span(span_)) |ty| {
            if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds;
        }
        return null;
    }

    fn verifyFieldSpan(self: *const Store, name_store: *const names.NameStore, span_: Span) ?VerifyError {
        if (!self.spanInBounds(self.fields.items.len, span_)) return .field_span_out_of_bounds;
        const fields_ = self.fieldSpan(span_);
        for (fields_) |field| {
            if (!self.typeRefInBounds(field.ty)) return .type_ref_out_of_bounds;
        }
        if (fields_.len > 1) {
            for (fields_[1..], 1..) |field, index| {
                if (!name_store.recordFieldLabelTextLessThan(fields_[index - 1].name, field.name)) {
                    return .record_fields_not_sorted;
                }
            }
        }
        return null;
    }

    fn verifyTagSpan(self: *const Store, name_store: *const names.NameStore, span_: Span) ?VerifyError {
        if (!self.spanInBounds(self.tags.items.len, span_)) return .tag_span_out_of_bounds;
        const tags_ = self.tagSpan(span_);
        for (tags_) |tag| {
            if (self.verifyTypeSpan(tag.payloads)) |err| return err;
        }
        if (tags_.len > 1) {
            for (tags_[1..], 1..) |tag, index| {
                if (!name_store.tagLabelTextLessThan(tags_[index - 1].name, tag.name)) {
                    return .tag_union_tags_not_sorted;
                }
            }
        }
        return null;
    }

    fn verifyDeclaredFieldSpan(self: *const Store, span_: Span) ?VerifyError {
        if (!self.spanInBounds(self.declared_fields.items.len, span_)) return .declared_field_span_out_of_bounds;
        for (self.declaredFieldSpan(span_)) |field| {
            switch (field) {
                .named => {},
                .padding => |ty| if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds,
            }
        }
        return null;
    }

    fn cachedDigestInner(
        self: *Store,
        name_store: *const names.NameStore,
        ty: TypeId,
        ctx: *CachedDigestContext,
        stats: ?*DigestStats,
    ) names.TypeDigest {
        for (ctx.items[0..ctx.len], 0..) |open_ty, position| {
            if (open_ty == ty) {
                ctx.saw_cycle = true;
                return cycleDigest(@intCast(position));
            }
        }

        if (self.type_digests.items[@intFromEnum(ty)]) |digest| {
            if (stats) |s| s.cache_hits += 1;
            return digest;
        }

        if (stats) |s| {
            s.cache_misses += 1;
            s.nodes_visited += 1;
        }

        if (ctx.len == digest_visiting_max) {
            ctx.saw_cycle = true;
            return deepDigest(ty);
        }

        ctx.items[ctx.len] = ty;
        ctx.len += 1;
        const saw_cycle_before = ctx.saw_cycle;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        self.writeCachedTypeDigest(name_store, &hasher, ty, ctx, stats);
        ctx.len -= 1;

        const digest: names.TypeDigest = .{ .bytes = hasher.finalResult() };
        if (ctx.saw_cycle == saw_cycle_before) {
            self.type_digests.items[@intFromEnum(ty)] = digest;
        }
        return digest;
    }

    fn writeCachedChildDigest(
        self: *Store,
        name_store: *const names.NameStore,
        hasher: *std.crypto.hash.sha2.Sha256,
        child: TypeId,
        ctx: *CachedDigestContext,
        stats: ?*DigestStats,
    ) void {
        writeBytes(hasher, "type-digest");
        const digest = self.cachedDigestInner(name_store, child, ctx, stats);
        hasher.update(&digest.bytes);
    }

    fn writeCachedTypeSpanDigest(
        self: *Store,
        name_store: *const names.NameStore,
        hasher: *std.crypto.hash.sha2.Sha256,
        span_: Span,
        ctx: *CachedDigestContext,
        stats: ?*DigestStats,
    ) void {
        const values = self.span(span_);
        writeU32(hasher, @intCast(values.len));
        for (values) |child| {
            self.writeCachedChildDigest(name_store, hasher, child, ctx, stats);
        }
    }

    fn writeCachedTypeDigest(
        self: *Store,
        name_store: *const names.NameStore,
        hasher: *std.crypto.hash.sha2.Sha256,
        ty: TypeId,
        ctx: *CachedDigestContext,
        stats: ?*DigestStats,
    ) void {
        switch (self.get(ty)) {
            .primitive => |primitive| {
                writeBytes(hasher, "primitive");
                writeBytes(hasher, @tagName(primitive));
            },
            .named => |named| {
                if (named.kind == .alias) {
                    const backing = named.backing orelse {
                        writeBytes(hasher, "alias-without-backing");
                        return;
                    };
                    self.writeCachedChildDigest(name_store, hasher, backing.ty, ctx, stats);
                    return;
                }
                writeBytes(hasher, "named");
                hasher.update(&named.named_type.module.bytes);
                writeBytes(hasher, name_store.moduleNameText(named.def.module_name));
                writeOptionalU32(hasher, named.def.source_decl);
                if (named.def.source_decl == null) {
                    writeBytes(hasher, name_store.typeNameText(named.def.type_name));
                }
                writeBytes(hasher, @tagName(named.kind));
                if (named.builtin_owner) |owner| {
                    writeBytes(hasher, "builtin");
                    writeBytes(hasher, @tagName(owner));
                    if (owner == .fields) {
                        writeBytes(hasher, "fields-backing");
                        if (named.backing) |backing| {
                            self.writeCachedChildDigest(name_store, hasher, backing.ty, ctx, stats);
                        } else {
                            writeBytes(hasher, "none");
                        }
                    }
                } else {
                    writeBytes(hasher, "not-builtin");
                }
                self.writeCachedTypeSpanDigest(name_store, hasher, named.args, ctx, stats);
            },
            .record => |fields| {
                writeBytes(hasher, "record");
                const field_slice = self.fieldSpan(fields);
                writeU32(hasher, @intCast(field_slice.len));
                for (field_slice) |field| {
                    writeBytes(hasher, name_store.recordFieldLabelText(field.name));
                    self.writeCachedChildDigest(name_store, hasher, field.ty, ctx, stats);
                }
            },
            .tuple => |items| {
                writeBytes(hasher, "tuple");
                self.writeCachedTypeSpanDigest(name_store, hasher, items, ctx, stats);
            },
            .tag_union => |tags| {
                writeBytes(hasher, "tag_union");
                const tag_slice = self.tagSpan(tags);
                writeU32(hasher, @intCast(tag_slice.len));
                for (tag_slice) |tag| {
                    writeBytes(hasher, name_store.tagLabelText(tag.name));
                    self.writeCachedTypeSpanDigest(name_store, hasher, tag.payloads, ctx, stats);
                }
            },
            .list => |elem| {
                writeBytes(hasher, "list");
                self.writeCachedChildDigest(name_store, hasher, elem, ctx, stats);
            },
            .box => |elem| {
                writeBytes(hasher, "box");
                self.writeCachedChildDigest(name_store, hasher, elem, ctx, stats);
            },
            .func => |function| {
                writeBytes(hasher, "func");
                self.writeCachedTypeSpanDigest(name_store, hasher, function.args, ctx, stats);
                self.writeCachedChildDigest(name_store, hasher, function.ret, ctx, stats);
            },
            .erased => |erased| {
                writeBytes(hasher, "erased");
                hasher.update(&erased.bytes);
            },
            .zst => writeBytes(hasher, "zst"),
        }
    }

    fn writeTypeDigest(
        self: *const Store,
        name_store: *const names.NameStore,
        hasher: *std.crypto.hash.sha2.Sha256,
        ty: TypeId,
        visiting: *DigestVisiting,
    ) void {
        for (visiting.items[0..visiting.len], 0..) |open_ty, position| {
            if (open_ty == ty) {
                writeBytes(hasher, "cycle");
                writeU32(hasher, @intCast(position));
                return;
            }
        }
        if (visiting.len == digest_visiting_max) {
            // Deeper nesting than the stack tracks cannot contain an
            // unrecorded cycle shorter than the stack, so digest the type's
            // identity instead of recursing further.
            writeBytes(hasher, "deep");
            writeU32(hasher, @intFromEnum(ty));
            return;
        }
        visiting.items[visiting.len] = ty;
        visiting.len += 1;
        defer visiting.len -= 1;
        switch (self.get(ty)) {
            .primitive => |primitive| {
                writeBytes(hasher, "primitive");
                writeBytes(hasher, @tagName(primitive));
            },
            .named => |named| {
                // Aliases are transparent: their digest is their backing's.
                if (named.kind == .alias) {
                    const backing = named.backing orelse {
                        writeBytes(hasher, "alias-without-backing");
                        return;
                    };
                    self.writeTypeDigest(name_store, hasher, backing.ty, visiting);
                    return;
                }
                writeBytes(hasher, "named");
                hasher.update(&named.named_type.module.bytes);
                writeBytes(hasher, name_store.moduleNameText(named.def.module_name));
                writeOptionalU32(hasher, named.def.source_decl);
                if (named.def.source_decl == null) {
                    writeBytes(hasher, name_store.typeNameText(named.def.type_name));
                }
                writeBytes(hasher, @tagName(named.kind));
                if (named.builtin_owner) |owner| {
                    writeBytes(hasher, "builtin");
                    writeBytes(hasher, @tagName(owner));
                    if (owner == .fields) {
                        writeBytes(hasher, "fields-backing");
                        if (named.backing) |backing| {
                            self.writeTypeDigest(name_store, hasher, backing.ty, visiting);
                        } else {
                            writeBytes(hasher, "none");
                        }
                    }
                } else {
                    writeBytes(hasher, "not-builtin");
                }
                self.writeTypeSpanDigest(name_store, hasher, named.args, visiting);
            },
            .record => |fields| {
                writeBytes(hasher, "record");
                const field_slice = self.fieldSpan(fields);
                writeU32(hasher, @intCast(field_slice.len));
                for (field_slice) |field| {
                    writeBytes(hasher, name_store.recordFieldLabelText(field.name));
                    self.writeTypeDigest(name_store, hasher, field.ty, visiting);
                }
            },
            .tuple => |items| {
                writeBytes(hasher, "tuple");
                self.writeTypeSpanDigest(name_store, hasher, items, visiting);
            },
            .tag_union => |tags| {
                writeBytes(hasher, "tag_union");
                const tag_slice = self.tagSpan(tags);
                writeU32(hasher, @intCast(tag_slice.len));
                for (tag_slice) |tag| {
                    writeBytes(hasher, name_store.tagLabelText(tag.name));
                    self.writeTypeSpanDigest(name_store, hasher, tag.payloads, visiting);
                }
            },
            .list => |elem| {
                writeBytes(hasher, "list");
                self.writeTypeDigest(name_store, hasher, elem, visiting);
            },
            .box => |elem| {
                writeBytes(hasher, "box");
                self.writeTypeDigest(name_store, hasher, elem, visiting);
            },
            .func => |function| {
                writeBytes(hasher, "func");
                self.writeTypeSpanDigest(name_store, hasher, function.args, visiting);
                self.writeTypeDigest(name_store, hasher, function.ret, visiting);
            },
            .erased => |erased| {
                writeBytes(hasher, "erased");
                hasher.update(&erased.bytes);
            },
            .zst => writeBytes(hasher, "zst"),
        }
    }

    fn writeTypeSpanDigest(
        self: *const Store,
        name_store: *const names.NameStore,
        hasher: *std.crypto.hash.sha2.Sha256,
        span_: Span,
        visiting: *DigestVisiting,
    ) void {
        const values = self.span(span_);
        writeU32(hasher, @intCast(values.len));
        for (values) |child| {
            self.writeTypeDigest(name_store, hasher, child, visiting);
        }
    }
};

/// Read-only type-store view backed by durable cache sections.
pub const DurableView = struct {
    types: []const Content,
    type_digests: []const names.TypeDigest,
    spans: []const TypeId,
    fields: []const Field,
    tags: []const Tag,
    declared_fields: []const DeclaredField,

    pub fn get(self: DurableView, ty: TypeId) Content {
        return self.types[@intFromEnum(ty)];
    }

    pub fn span(self: DurableView, span_: Span) []const TypeId {
        return self.spans[span_.start..][0..span_.len];
    }

    pub fn fieldSpan(self: DurableView, span_: Span) []const Field {
        return self.fields[span_.start..][0..span_.len];
    }

    pub fn tagSpan(self: DurableView, span_: Span) []const Tag {
        return self.tags[span_.start..][0..span_.len];
    }

    pub fn declaredFieldSpan(self: DurableView, span_: Span) []const DeclaredField {
        return self.declared_fields[span_.start..][0..span_.len];
    }

    pub fn verify(self: DurableView, name_store: *const names.NameStore) ?Store.VerifyError {
        if (self.type_digests.len != self.types.len) return .type_digest_count_mismatch;

        for (self.spans) |ty| {
            if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds;
        }
        for (self.fields) |field| {
            if (!self.typeRefInBounds(field.ty)) return .type_ref_out_of_bounds;
        }
        for (self.tags) |tag| {
            if (!self.spanInBounds(self.spans.len, tag.payloads)) return .type_span_out_of_bounds;
            if (self.verifyTypeSpan(tag.payloads)) |err| return err;
        }
        for (self.declared_fields) |field| {
            switch (field) {
                .named => {},
                .padding => |ty| if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds,
            }
        }

        for (self.types) |content| {
            switch (content) {
                .primitive, .erased, .zst => {},
                .list, .box => |ty| if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds,
                .tuple => |span_| if (self.verifyTypeSpan(span_)) |err| return err,
                .record => |span_| if (self.verifyFieldSpan(name_store, span_)) |err| return err,
                .tag_union => |span_| if (self.verifyTagSpan(name_store, span_)) |err| return err,
                .func => |func| {
                    if (self.verifyTypeSpan(func.args)) |err| return err;
                    if (!self.typeRefInBounds(func.ret)) return .type_ref_out_of_bounds;
                },
                .named => |named| {
                    if (self.verifyTypeSpan(named.args)) |err| return err;
                    if (named.backing) |backing| {
                        if (!self.typeRefInBounds(backing.ty)) return .type_ref_out_of_bounds;
                    }
                    if (self.verifyDeclaredFieldSpan(named.declared_order)) |err| return err;
                },
            }
        }

        return null;
    }

    fn typeRefInBounds(self: DurableView, ty: TypeId) bool {
        return @intFromEnum(ty) < self.types.len;
    }

    fn spanInBounds(_: DurableView, len: usize, span_: Span) bool {
        const start: usize = span_.start;
        const span_len: usize = span_.len;
        return start <= len and span_len <= len - start;
    }

    fn verifyTypeSpan(self: DurableView, span_: Span) ?Store.VerifyError {
        if (!self.spanInBounds(self.spans.len, span_)) return .type_span_out_of_bounds;
        for (self.span(span_)) |ty| {
            if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds;
        }
        return null;
    }

    fn verifyFieldSpan(self: DurableView, name_store: *const names.NameStore, span_: Span) ?Store.VerifyError {
        if (!self.spanInBounds(self.fields.len, span_)) return .field_span_out_of_bounds;
        const fields_ = self.fieldSpan(span_);
        for (fields_) |field| {
            if (!self.typeRefInBounds(field.ty)) return .type_ref_out_of_bounds;
        }
        if (fields_.len > 1) {
            for (fields_[1..], 1..) |field, index| {
                if (!name_store.recordFieldLabelTextLessThan(fields_[index - 1].name, field.name)) {
                    return .record_fields_not_sorted;
                }
            }
        }
        return null;
    }

    fn verifyTagSpan(self: DurableView, name_store: *const names.NameStore, span_: Span) ?Store.VerifyError {
        if (!self.spanInBounds(self.tags.len, span_)) return .tag_span_out_of_bounds;
        const tags_ = self.tagSpan(span_);
        for (tags_) |tag| {
            if (self.verifyTypeSpan(tag.payloads)) |err| return err;
        }
        if (tags_.len > 1) {
            for (tags_[1..], 1..) |tag, index| {
                if (!name_store.tagLabelTextLessThan(tags_[index - 1].name, tag.name)) {
                    return .tag_union_tags_not_sorted;
                }
            }
        }
        return null;
    }

    fn verifyDeclaredFieldSpan(self: DurableView, span_: Span) ?Store.VerifyError {
        if (!self.spanInBounds(self.declared_fields.len, span_)) return .declared_field_span_out_of_bounds;
        for (self.declaredFieldSpan(span_)) |field| {
            switch (field) {
                .named => {},
                .padding => |ty| if (!self.typeRefInBounds(ty)) return .type_ref_out_of_bounds,
            }
        }
        return null;
    }
};

/// Exact structural equality for closed Monotype types that live in two
/// different type stores. Type ids are interpreted only against the view they
/// came from; equality follows the same identity rules as `Store.typeEql`.
pub fn typeEqlAcrossStores(
    allocator: std.mem.Allocator,
    name_store: *const names.NameStore,
    lhs_view: anytype,
    lhs: TypeId,
    rhs_view: anytype,
    rhs: TypeId,
) std.mem.Allocator.Error!bool {
    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();
    return try typeEqlAcrossStoresInner(name_store, lhs_view, lhs, rhs_view, rhs, &visited);
}

fn typeEqlAcrossStoresInner(
    name_store: *const names.NameStore,
    lhs_view: anytype,
    raw_lhs: TypeId,
    rhs_view: anytype,
    raw_rhs: TypeId,
    visited: *std.AutoHashMap(u64, void),
) std.mem.Allocator.Error!bool {
    const lhs_content = lhs_view.get(raw_lhs);
    if (lhs_content == .named and lhs_content.named.kind == .alias) {
        if (lhs_content.named.backing) |backing| {
            return try typeEqlAcrossStoresInner(name_store, lhs_view, backing.ty, rhs_view, raw_rhs, visited);
        }
    }

    const rhs_content = rhs_view.get(raw_rhs);
    if (rhs_content == .named and rhs_content.named.kind == .alias) {
        if (rhs_content.named.backing) |backing| {
            return try typeEqlAcrossStoresInner(name_store, lhs_view, raw_lhs, rhs_view, backing.ty, visited);
        }
    }

    const pair = directionalTypePair(raw_lhs, raw_rhs);
    const gop = try visited.getOrPut(pair);
    if (gop.found_existing) return true;

    return switch (lhs_content) {
        .primitive => |lhs_primitive| switch (rhs_content) {
            .primitive => |rhs_primitive| lhs_primitive == rhs_primitive,
            else => false,
        },
        .named => |lhs_named| switch (rhs_content) {
            .named => |rhs_named| try namedTypeEqlAcrossStores(name_store, lhs_view, lhs_named, rhs_view, rhs_named, visited),
            else => false,
        },
        .record => |lhs_fields| switch (rhs_content) {
            .record => |rhs_fields| try fieldSpanEqlAcrossStores(name_store, lhs_view, lhs_fields, rhs_view, rhs_fields, visited),
            else => false,
        },
        .tuple => |lhs_items| switch (rhs_content) {
            .tuple => |rhs_items| try typeSpanEqlAcrossStores(name_store, lhs_view, lhs_items, rhs_view, rhs_items, visited),
            else => false,
        },
        .tag_union => |lhs_tags| switch (rhs_content) {
            .tag_union => |rhs_tags| try tagSpanEqlAcrossStores(name_store, lhs_view, lhs_tags, rhs_view, rhs_tags, visited),
            else => false,
        },
        .list => |lhs_elem| switch (rhs_content) {
            .list => |rhs_elem| try typeEqlAcrossStoresInner(name_store, lhs_view, lhs_elem, rhs_view, rhs_elem, visited),
            else => false,
        },
        .box => |lhs_elem| switch (rhs_content) {
            .box => |rhs_elem| try typeEqlAcrossStoresInner(name_store, lhs_view, lhs_elem, rhs_view, rhs_elem, visited),
            else => false,
        },
        .func => |lhs_func| switch (rhs_content) {
            .func => |rhs_func| blk: {
                if (!try typeSpanEqlAcrossStores(name_store, lhs_view, lhs_func.args, rhs_view, rhs_func.args, visited)) break :blk false;
                break :blk try typeEqlAcrossStoresInner(name_store, lhs_view, lhs_func.ret, rhs_view, rhs_func.ret, visited);
            },
            else => false,
        },
        .erased => |lhs_digest| switch (rhs_content) {
            .erased => |rhs_digest| std.mem.eql(u8, lhs_digest.bytes[0..], rhs_digest.bytes[0..]),
            else => false,
        },
        .zst => rhs_content == .zst,
    };
}

fn namedTypeEqlAcrossStores(
    name_store: *const names.NameStore,
    lhs_view: anytype,
    lhs: NamedContent,
    rhs_view: anytype,
    rhs: NamedContent,
    visited: *std.AutoHashMap(u64, void),
) std.mem.Allocator.Error!bool {
    if (lhs.kind != rhs.kind) return false;
    if (!std.mem.eql(u8, lhs.named_type.module.bytes[0..], rhs.named_type.module.bytes[0..])) return false;
    if (!std.mem.eql(u8, name_store.moduleNameText(lhs.def.module_name), name_store.moduleNameText(rhs.def.module_name))) return false;
    if (lhs.def.source_decl != rhs.def.source_decl) return false;
    if (lhs.def.source_decl == null and
        !std.mem.eql(u8, name_store.typeNameText(lhs.def.type_name), name_store.typeNameText(rhs.def.type_name)))
    {
        return false;
    }
    if (lhs.builtin_owner != rhs.builtin_owner) return false;
    if (!try typeSpanEqlAcrossStores(name_store, lhs_view, lhs.args, rhs_view, rhs.args, visited)) return false;

    if (lhs.kind == .alias) {
        const lhs_backing = lhs.backing orelse return rhs.backing == null;
        const rhs_backing = rhs.backing orelse return false;
        return try typeEqlAcrossStoresInner(name_store, lhs_view, lhs_backing.ty, rhs_view, rhs_backing.ty, visited);
    }

    if (lhs.builtin_owner) |owner| {
        if (owner == .fields) {
            const lhs_backing = lhs.backing orelse return rhs.backing == null;
            const rhs_backing = rhs.backing orelse return false;
            return try typeEqlAcrossStoresInner(name_store, lhs_view, lhs_backing.ty, rhs_view, rhs_backing.ty, visited);
        }
    }

    return true;
}

fn typeSpanEqlAcrossStores(
    name_store: *const names.NameStore,
    lhs_view: anytype,
    lhs_span: Span,
    rhs_view: anytype,
    rhs_span: Span,
    visited: *std.AutoHashMap(u64, void),
) std.mem.Allocator.Error!bool {
    const lhs = lhs_view.span(lhs_span);
    const rhs = rhs_view.span(rhs_span);
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_ty, rhs_ty| {
        if (!try typeEqlAcrossStoresInner(name_store, lhs_view, lhs_ty, rhs_view, rhs_ty, visited)) return false;
    }
    return true;
}

fn fieldSpanEqlAcrossStores(
    name_store: *const names.NameStore,
    lhs_view: anytype,
    lhs_span: Span,
    rhs_view: anytype,
    rhs_span: Span,
    visited: *std.AutoHashMap(u64, void),
) std.mem.Allocator.Error!bool {
    const lhs = lhs_view.fieldSpan(lhs_span);
    const rhs = rhs_view.fieldSpan(rhs_span);
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_field, rhs_field| {
        if (!std.mem.eql(u8, name_store.recordFieldLabelText(lhs_field.name), name_store.recordFieldLabelText(rhs_field.name))) return false;
        if (!try typeEqlAcrossStoresInner(name_store, lhs_view, lhs_field.ty, rhs_view, rhs_field.ty, visited)) return false;
    }
    return true;
}

fn tagSpanEqlAcrossStores(
    name_store: *const names.NameStore,
    lhs_view: anytype,
    lhs_span: Span,
    rhs_view: anytype,
    rhs_span: Span,
    visited: *std.AutoHashMap(u64, void),
) std.mem.Allocator.Error!bool {
    const lhs = lhs_view.tagSpan(lhs_span);
    const rhs = rhs_view.tagSpan(rhs_span);
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_tag, rhs_tag| {
        if (!std.mem.eql(u8, name_store.tagLabelText(lhs_tag.name), name_store.tagLabelText(rhs_tag.name))) return false;
        if (!try typeSpanEqlAcrossStores(name_store, lhs_view, lhs_tag.payloads, rhs_view, rhs_tag.payloads, visited)) return false;
    }
    return true;
}

fn directionalTypePair(lhs: TypeId, rhs: TypeId) u64 {
    return (@as(u64, @intFromEnum(lhs)) << 32) | @as(u64, @intFromEnum(rhs));
}

/// Mutable builder for immutable Monotype type nodes.
///
/// The interner is child-first for acyclic types: callers provide
/// already-interned child `TypeId`s, and every successful call returns a
/// `TypeId` whose content is not mutated by the interner afterwards. Recursive
/// roots are sealed through `internRecursiveRoot`, which keeps the temporary
/// back-reference slots private until the root has immutable content and a
/// digest/equality bucket.
pub const Interner = struct {
    allocator: std.mem.Allocator,
    name_store: *const names.NameStore,
    store: Store,
    by_digest: std.AutoHashMap(InternerLookupDigest, std.ArrayList(TypeId)),

    pub fn init(allocator: std.mem.Allocator, name_store: *const names.NameStore) Interner {
        return .{
            .allocator = allocator,
            .name_store = name_store,
            .store = Store.init(allocator),
            .by_digest = std.AutoHashMap(InternerLookupDigest, std.ArrayList(TypeId)).init(allocator),
        };
    }

    pub fn deinit(self: *Interner) void {
        var lists = self.by_digest.valueIterator();
        while (lists.next()) |list| list.deinit(self.allocator);
        self.by_digest.deinit();
        self.store.deinit();
    }

    pub fn view(self: *const Interner) Store.View {
        return self.store.view();
    }

    pub fn internPrimitive(self: *Interner, primitive: Primitive) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const ty = try self.store.add(.{ .primitive = primitive });
        return try self.internCandidate(mark_, ty);
    }

    pub fn internZst(self: *Interner) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const ty = try self.store.add(.zst);
        return try self.internCandidate(mark_, ty);
    }

    pub fn internList(self: *Interner, elem: TypeId) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const ty = try self.store.add(.{ .list = elem });
        return try self.internCandidate(mark_, ty);
    }

    pub fn internBox(self: *Interner, elem: TypeId) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const ty = try self.store.add(.{ .box = elem });
        return try self.internCandidate(mark_, ty);
    }

    pub fn internTuple(self: *Interner, items: []const TypeId) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const span_ = try self.store.addSpan(items);
        const ty = try self.store.add(.{ .tuple = span_ });
        return try self.internCandidate(mark_, ty);
    }

    pub fn internFunc(self: *Interner, args: []const TypeId, ret: TypeId) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const span_ = try self.store.addSpan(args);
        const ty = try self.store.add(.{ .func = .{ .args = span_, .ret = ret } });
        return try self.internCandidate(mark_, ty);
    }

    pub fn internRecord(self: *Interner, raw_fields: []const Field) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const span_ = try self.store.addRecordFields(self.name_store, raw_fields);
        const ty = try self.store.add(.{ .record = span_ });
        return try self.internCandidate(mark_, ty);
    }

    pub fn internTagUnion(self: *Interner, raw_tags: []const Tag) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const span_ = try self.store.addTagVariants(self.name_store, raw_tags);
        const ty = try self.store.add(.{ .tag_union = span_ });
        return try self.internCandidate(mark_, ty);
    }

    pub fn internNamed(self: *Interner, named: NamedContent) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const ty = try self.store.add(.{ .named = named });
        return try self.internCandidate(mark_, ty);
    }

    pub fn internErased(self: *Interner, digest: names.TypeDigest) std.mem.Allocator.Error!TypeId {
        const mark_ = self.store.mark();
        const ty = try self.store.add(.{ .erased = digest });
        return try self.internCandidate(mark_, ty);
    }

    pub const RecursiveLink = union(enum(u8)) {
        interned: TypeId,
        node: RecursiveNodeId,
        root,
    };

    pub const RecursiveNodeId = enum(u32) { _ };

    pub fn recursiveNodeId(index: usize) RecursiveNodeId {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub const RecursiveField = struct {
        name: names.RecordFieldNameId,
        ty: RecursiveLink,
    };

    pub const RecursiveTag = struct {
        name: names.TagNameId,
        checked_name: names.TagNameId,
        payloads: []const RecursiveLink,
    };

    pub const RecursiveNamedBacking = struct {
        ty: RecursiveLink,
        use: BackingUse,
    };

    pub const RecursiveNamed = struct {
        named_type: NamedType,
        def: TypeDef,
        kind: NamedKind,
        builtin_owner: ?static_dispatch.BuiltinOwner = null,
        args: []const RecursiveLink,
        backing: ?RecursiveNamedBacking = null,
        declared_order: Span = Span.empty(),
    };

    pub const RecursiveContent = union(enum(u8)) {
        primitive: Primitive,
        named: RecursiveNamed,
        record: []const RecursiveField,
        tuple: []const RecursiveLink,
        tag_union: []const RecursiveTag,
        list: RecursiveLink,
        box: RecursiveLink,
        func: struct {
            args: []const RecursiveLink,
            ret: RecursiveLink,
        },
        erased: names.TypeDigest,
        zst,
    };

    /// Intern one recursive root without exposing the reserved root id before
    /// its content has been sealed. The input may refer to the root with
    /// `RecursiveLink.root`; every other child must already be an immutable
    /// interned `TypeId`.
    pub fn internRecursiveRoot(self: *Interner, content: RecursiveContent) std.mem.Allocator.Error!TypeId {
        return try self.internRecursiveGroupRoot(&.{content}, recursiveNodeId(0));
    }

    /// Intern one public root from a private recursive group. Group nodes may
    /// reference each other through `RecursiveLink.node`; only the selected root
    /// is returned to the caller, and it is returned only after every private
    /// node has been filled exactly once.
    pub fn internRecursiveGroupRoot(
        self: *Interner,
        contents: []const RecursiveContent,
        root_node: RecursiveNodeId,
    ) std.mem.Allocator.Error!TypeId {
        if (@intFromEnum(root_node) >= contents.len) {
            Common.invariant("Monotype recursive type group root is outside the group");
        }

        const mark_ = self.store.mark();
        errdefer self.store.restore(mark_);

        const ids = try self.allocator.alloc(TypeId, contents.len);
        defer self.allocator.free(ids);

        for (ids) |*id| {
            id.* = try self.store.add(.zst);
        }
        const root = ids[@intFromEnum(root_node)];
        for (contents, 0..) |content, index| {
            const lowered = try self.lowerRecursiveContent(ids, root, content);
            self.store.set(ids[index], lowered);
        }
        return try self.internCandidate(mark_, root);
    }

    fn lowerRecursiveLink(_: *Interner, ids: []const TypeId, root: TypeId, link: RecursiveLink) TypeId {
        return switch (link) {
            .interned => |ty| ty,
            .node => |node| blk: {
                const raw = @intFromEnum(node);
                if (raw >= ids.len) Common.invariant("Monotype recursive type reference is outside the group");
                break :blk ids[raw];
            },
            .root => root,
        };
    }

    fn lowerRecursiveLinkSpan(
        self: *Interner,
        ids: []const TypeId,
        root: TypeId,
        links: []const RecursiveLink,
    ) std.mem.Allocator.Error!Span {
        if (links.len == 0) return .empty();
        const lowered = try self.allocator.alloc(TypeId, links.len);
        defer self.allocator.free(lowered);
        for (links, 0..) |link, index| {
            lowered[index] = self.lowerRecursiveLink(ids, root, link);
        }
        return try self.store.addSpan(lowered);
    }

    fn lowerRecursiveFields(
        self: *Interner,
        ids: []const TypeId,
        root: TypeId,
        fields: []const RecursiveField,
    ) std.mem.Allocator.Error!Span {
        if (fields.len == 0) return .empty();
        const lowered = try self.allocator.alloc(Field, fields.len);
        defer self.allocator.free(lowered);
        for (fields, 0..) |field, index| {
            lowered[index] = .{
                .name = field.name,
                .ty = self.lowerRecursiveLink(ids, root, field.ty),
            };
        }
        return try self.store.addRecordFields(self.name_store, lowered);
    }

    fn lowerRecursiveTags(
        self: *Interner,
        ids: []const TypeId,
        root: TypeId,
        tags_: []const RecursiveTag,
    ) std.mem.Allocator.Error!Span {
        if (tags_.len == 0) return .empty();
        const lowered = try self.allocator.alloc(Tag, tags_.len);
        defer self.allocator.free(lowered);
        for (tags_, 0..) |tag, index| {
            lowered[index] = .{
                .name = tag.name,
                .checked_name = tag.checked_name,
                .payloads = try self.lowerRecursiveLinkSpan(ids, root, tag.payloads),
            };
        }
        return try self.store.addTagVariants(self.name_store, lowered);
    }

    fn lowerRecursiveNamed(
        self: *Interner,
        ids: []const TypeId,
        root: TypeId,
        named: RecursiveNamed,
    ) std.mem.Allocator.Error!NamedContent {
        return .{
            .named_type = named.named_type,
            .def = named.def,
            .kind = named.kind,
            .builtin_owner = named.builtin_owner,
            .args = try self.lowerRecursiveLinkSpan(ids, root, named.args),
            .backing = if (named.backing) |backing| .{
                .ty = self.lowerRecursiveLink(ids, root, backing.ty),
                .use = backing.use,
            } else null,
            .declared_order = named.declared_order,
        };
    }

    fn lowerRecursiveContent(
        self: *Interner,
        ids: []const TypeId,
        root: TypeId,
        content: RecursiveContent,
    ) std.mem.Allocator.Error!Content {
        return switch (content) {
            .primitive => |primitive| .{ .primitive = primitive },
            .named => |named| .{ .named = try self.lowerRecursiveNamed(ids, root, named) },
            .record => |fields| .{ .record = try self.lowerRecursiveFields(ids, root, fields) },
            .tuple => |items| .{ .tuple = try self.lowerRecursiveLinkSpan(ids, root, items) },
            .tag_union => |tags_| .{ .tag_union = try self.lowerRecursiveTags(ids, root, tags_) },
            .list => |elem| .{ .list = self.lowerRecursiveLink(ids, root, elem) },
            .box => |elem| .{ .box = self.lowerRecursiveLink(ids, root, elem) },
            .func => |function| .{ .func = .{
                .args = try self.lowerRecursiveLinkSpan(ids, root, function.args),
                .ret = self.lowerRecursiveLink(ids, root, function.ret),
            } },
            .erased => |digest| .{ .erased = digest },
            .zst => .zst,
        };
    }

    fn internCandidate(self: *Interner, mark_: Store.Mark, candidate: TypeId) std.mem.Allocator.Error!TypeId {
        errdefer self.store.restore(mark_);

        const digest = self.store.typeDigestCached(self.name_store, candidate, null);
        const key = InternerLookupDigest.from(digest);
        if (self.by_digest.getPtr(key)) |bucket| {
            for (bucket.items) |existing| {
                if (try self.store.typeEql(self.name_store, existing, candidate)) {
                    self.store.restore(mark_);
                    return existing;
                }
            }
            try bucket.append(self.allocator, candidate);
            return candidate;
        }

        var bucket = std.ArrayList(TypeId).empty;
        errdefer bucket.deinit(self.allocator);
        try bucket.append(self.allocator, candidate);
        try self.by_digest.put(key, bucket);
        return candidate;
    }
};

const InternerLookupDigest = struct {
    bytes: [32]u8,

    fn from(digest: names.TypeDigest) InternerLookupDigest {
        return .{ .bytes = digest.bytes };
    }
};

fn recordFieldLessThan(name_store: *const names.NameStore, lhs: Field, rhs: Field) bool {
    return name_store.recordFieldLabelTextLessThan(lhs.name, rhs.name);
}

fn tagLessThan(name_store: *const names.NameStore, lhs: Tag, rhs: Tag) bool {
    return name_store.tagLabelTextLessThan(lhs.name, rhs.name);
}

fn assertNoDuplicateRecordFields(name_store: *const names.NameStore, fields: []const Field) void {
    if (fields.len < 2) return;
    for (fields[1..], 1..) |field, index| {
        if (name_store.recordFieldLabelTextEql(fields[index - 1].name, field.name)) {
            Common.invariant("Monotype record type was constructed with duplicate fields");
        }
    }
}

fn assertNoDuplicateTags(name_store: *const names.NameStore, tags_: []const Tag) void {
    if (tags_.len < 2) return;
    for (tags_[1..], 1..) |tag, index| {
        if (name_store.tagLabelTextEql(tags_[index - 1].name, tag.name)) {
            Common.invariant("Monotype tag union type was constructed with duplicate tags");
        }
    }
}

fn cycleDigest(position: u32) names.TypeDigest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    writeBytes(&hasher, "cycle");
    writeU32(&hasher, position);
    return .{ .bytes = hasher.finalResult() };
}

fn deepDigest(ty: TypeId) names.TypeDigest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    writeBytes(&hasher, "deep");
    writeU32(&hasher, @intFromEnum(ty));
    return .{ .bytes = hasher.finalResult() };
}

fn writeBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    writeU32(hasher, @intCast(bytes.len));
    hasher.update(bytes);
}

fn writeU32(hasher: *std.crypto.hash.sha2.Sha256, value: u32) void {
    const little = std.mem.nativeToLittle(u32, value);
    hasher.update(std.mem.asBytes(&little));
}

fn writeOptionalU32(hasher: *std.crypto.hash.sha2.Sha256, value: ?u32) void {
    const present: u8 = if (value == null) 0 else 1;
    hasher.update(std.mem.asBytes(&present));
    if (value) |v| writeU32(hasher, v);
}

fn builtinOwner(primitive: Primitive) static_dispatch.BuiltinOwner {
    return switch (primitive) {
        .bool => .bool,
        .str => .str,
        .u8 => .u8,
        .i8 => .i8,
        .u16 => .u16,
        .i16 => .i16,
        .u32 => .u32,
        .i32 => .i32,
        .u64 => .u64,
        .i64 => .i64,
        .u128 => .u128,
        .i128 => .i128,
        .f32 => .f32,
        .f64 => .f64,
        .dec => .dec,
    };
}

test "monotype type declarations are referenced" {
    std.testing.refAllDecls(@This());
}

test "monotype type interner reuses child-first function nodes" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    var interner = Interner.init(std.testing.allocator, &name_store);
    defer interner.deinit();

    const unit = try interner.internZst();
    const first = try interner.internFunc(&.{unit}, unit);
    const second = try interner.internFunc(&.{unit}, unit);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 2), interner.view().types.len);
}

test "monotype type interner normalizes record and tag rows" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const a_field = try name_store.internRecordFieldLabel("a");
    const b_field = try name_store.internRecordFieldLabel("b");
    const a_tag = try name_store.internTagLabel("A");
    const b_tag = try name_store.internTagLabel("B");

    var interner = Interner.init(std.testing.allocator, &name_store);
    defer interner.deinit();

    const unit = try interner.internZst();
    const first_record = try interner.internRecord(&.{
        .{ .name = b_field, .ty = unit },
        .{ .name = a_field, .ty = unit },
    });
    const second_record = try interner.internRecord(&.{
        .{ .name = a_field, .ty = unit },
        .{ .name = b_field, .ty = unit },
    });
    try std.testing.expectEqual(first_record, second_record);

    const payloads = try interner.store.addSpan(&.{unit});
    const first_tags = try interner.internTagUnion(&.{
        .{ .name = b_tag, .checked_name = b_tag, .payloads = payloads },
        .{ .name = a_tag, .checked_name = a_tag, .payloads = payloads },
    });
    const second_tags = try interner.internTagUnion(&.{
        .{ .name = a_tag, .checked_name = a_tag, .payloads = payloads },
        .{ .name = b_tag, .checked_name = b_tag, .payloads = payloads },
    });
    try std.testing.expectEqual(first_tags, second_tags);

    const record_fields = interner.store.fieldSpan(interner.store.get(first_record).record);
    try std.testing.expectEqual(a_field, record_fields[0].name);
    try std.testing.expectEqual(b_field, record_fields[1].name);
    const tag_fields = interner.store.tagSpan(interner.store.get(first_tags).tag_union);
    try std.testing.expectEqual(a_tag, tag_fields[0].name);
    try std.testing.expectEqual(b_tag, tag_fields[1].name);
}

test "monotype type interner preserves tag payload order" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const tag_name = try name_store.internTagLabel("Pair");

    var interner = Interner.init(std.testing.allocator, &name_store);
    defer interner.deinit();

    const first = try interner.internPrimitive(.i64);
    const second = try interner.internPrimitive(.str);
    const payloads = try interner.store.addSpan(&.{ first, second });
    const tag_ty = try interner.internTagUnion(&.{
        .{ .name = tag_name, .checked_name = tag_name, .payloads = payloads },
    });

    const tags_ = interner.store.tagSpan(interner.store.get(tag_ty).tag_union);
    const stored_payloads = interner.store.span(tags_[0].payloads);
    try std.testing.expectEqual(first, stored_payloads[0]);
    try std.testing.expectEqual(second, stored_payloads[1]);
}

test "monotype type interner checks exact equality after digest match" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const module_name = try name_store.internModuleName("Test");
    const first_name = try name_store.internTypeName("First");
    const second_name = try name_store.internTypeName("Second");

    var interner = Interner.init(std.testing.allocator, &name_store);
    defer interner.deinit();

    const first = try interner.internNamed(.{
        .named_type = .{ .module = .{}, .ty = @enumFromInt(1) },
        .def = .{ .module_name = module_name, .type_name = first_name },
        .kind = .alias,
        .args = Span.empty(),
        .backing = null,
    });
    const second = try interner.internNamed(.{
        .named_type = .{ .module = .{}, .ty = @enumFromInt(2) },
        .def = .{ .module_name = module_name, .type_name = second_name },
        .kind = .alias,
        .args = Span.empty(),
        .backing = null,
    });

    const first_digest = interner.store.typeDigestCached(&name_store, first, null);
    const second_digest = interner.store.typeDigestCached(&name_store, second, null);
    try std.testing.expectEqualSlices(u8, first_digest.bytes[0..], second_digest.bytes[0..]);
    try std.testing.expect(first != second);
}

test "monotype type interner seals recursive root before exposing type id" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const field_name = try name_store.internRecordFieldLabel("next");

    var interner = Interner.init(std.testing.allocator, &name_store);
    defer interner.deinit();

    const root = try interner.internRecursiveRoot(.{ .record = &.{
        .{ .name = field_name, .ty = .root },
    } });

    const fields = interner.store.fieldSpan(interner.store.get(root).record);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqual(root, fields[0].ty);
    try std.testing.expectEqual(@as(?Store.VerifyError, null), interner.store.verify(&name_store));
}

test "monotype type interner reuses equivalent recursive roots" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const field_name = try name_store.internRecordFieldLabel("next");

    var interner = Interner.init(std.testing.allocator, &name_store);
    defer interner.deinit();

    const first = try interner.internRecursiveRoot(.{ .record = &.{
        .{ .name = field_name, .ty = .root },
    } });
    const second = try interner.internRecursiveRoot(.{ .record = &.{
        .{ .name = field_name, .ty = .root },
    } });

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), interner.view().types.len);
}

test "monotype type interner seals multi-node recursive group privately" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const field_name = try name_store.internRecordFieldLabel("step");

    var interner = Interner.init(std.testing.allocator, &name_store);
    defer interner.deinit();

    const record_node = Interner.recursiveNodeId(0);
    const func_node = Interner.recursiveNodeId(1);
    const first = try interner.internRecursiveGroupRoot(&.{
        .{ .record = &.{
            .{ .name = field_name, .ty = .{ .node = func_node } },
        } },
        .{ .func = .{
            .args = &.{},
            .ret = .{ .node = record_node },
        } },
    }, record_node);
    const second = try interner.internRecursiveGroupRoot(&.{
        .{ .record = &.{
            .{ .name = field_name, .ty = .{ .node = func_node } },
        } },
        .{ .func = .{
            .args = &.{},
            .ret = .{ .node = record_node },
        } },
    }, record_node);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 2), interner.view().types.len);

    const step_ty = interner.store.fieldSpan(interner.store.get(first).record)[0].ty;
    const step_fn = interner.store.get(step_ty).func;
    try std.testing.expectEqual(first, step_fn.ret);
}

test "monotype type interner keeps distinct recursive roots with different children" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const next_name = try name_store.internRecordFieldLabel("next");
    const done_name = try name_store.internRecordFieldLabel("done");

    var interner = Interner.init(std.testing.allocator, &name_store);
    defer interner.deinit();

    const bool_ty = try interner.internPrimitive(.bool);
    const recursive_only = try interner.internRecursiveRoot(.{ .record = &.{
        .{ .name = next_name, .ty = .root },
    } });
    const recursive_with_bool = try interner.internRecursiveRoot(.{ .record = &.{
        .{ .name = next_name, .ty = .root },
        .{ .name = done_name, .ty = .{ .interned = bool_ty } },
    } });

    try std.testing.expect(recursive_only != recursive_with_bool);
    try std.testing.expect(!try interner.store.typeEql(&name_store, recursive_only, recursive_with_bool));
}

test "monotype named type digest includes generic arguments" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const module_name = try name_store.internModuleName("Test");
    const type_name = try name_store.internTypeName("Box");

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const i64_ty = try store.add(.{ .primitive = .i64 });
    const str = try store.add(.{ .primitive = .str });
    const i64_args = try store.addSpan(&.{i64_ty});
    const str_args = try store.addSpan(&.{str});
    const checked_ty: checked.CheckedTypeId = @enumFromInt(1);

    const named_i64 = try store.add(.{ .named = .{
        .named_type = .{ .module = .{}, .ty = checked_ty },
        .def = .{ .module_name = module_name, .type_name = type_name },
        .kind = .nominal,
        .args = i64_args,
    } });
    const named_str = try store.add(.{ .named = .{
        .named_type = .{ .module = .{}, .ty = checked_ty },
        .def = .{ .module_name = module_name, .type_name = type_name },
        .kind = .nominal,
        .args = str_args,
    } });

    const i64_digest = store.typeDigest(&name_store, named_i64);
    const str_digest = store.typeDigest(&name_store, named_str);
    try std.testing.expect(!std.mem.eql(u8, i64_digest.bytes[0..], str_digest.bytes[0..]));
}

test "monotype store keeps function-containing shapes distinct" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const unit = try store.add(.zst);
    const args = try store.addSpan(&.{unit});

    const fn_a = try store.add(.{ .func = .{ .args = args, .ret = unit } });
    const fn_b = try store.add(.{ .func = .{ .args = args, .ret = unit } });
    try std.testing.expect(fn_a != fn_b);

    const list_a = try store.add(.{ .list = fn_a });
    const list_b = try store.add(.{ .list = fn_a });
    try std.testing.expect(list_a != list_b);
}

test "monotype row entries retain checked label ids" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const field_name = try name_store.internRecordFieldLabel("age");
    const tag_name = try name_store.internTagLabel("Adult");

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const i64_ty = try store.add(.{ .primitive = .i64 });
    const fields = try store.addFields(&.{.{ .name = field_name, .ty = i64_ty }});
    const payloads = try store.addSpan(&.{i64_ty});
    const tags = try store.addTags(&.{.{ .name = tag_name, .checked_name = tag_name, .payloads = payloads }});

    try std.testing.expectEqual(field_name, store.fieldSpan(fields)[0].name);
    try std.testing.expectEqual(tag_name, store.tagSpan(tags)[0].name);
}

test "monotype empty spans use shared empty descriptor" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const unit = try store.add(.zst);
    const nonempty_span = try store.addSpan(&.{unit});
    const nonempty_fields = try store.addFields(&.{.{ .name = @enumFromInt(1), .ty = unit }});
    const nonempty_tags = try store.addTags(&.{.{ .name = @enumFromInt(2), .checked_name = @enumFromInt(2), .payloads = nonempty_span }});
    try std.testing.expect(nonempty_span.len == 1);
    try std.testing.expect(nonempty_fields.len == 1);
    try std.testing.expect(nonempty_tags.len == 1);

    try std.testing.expectEqual(Span.empty(), try store.addSpan(&.{}));
    try std.testing.expectEqual(Span.empty(), try store.addFields(&.{}));
    try std.testing.expectEqual(Span.empty(), try store.addTags(&.{}));
}

test "monotype type verifier accepts normalized rows" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const a_field = try name_store.internRecordFieldLabel("a");
    const b_field = try name_store.internRecordFieldLabel("b");
    const a_tag = try name_store.internTagLabel("A");
    const b_tag = try name_store.internTagLabel("B");

    const i64_ty = try store.add(.{ .primitive = .i64 });
    const fields = try store.addFields(&.{
        .{ .name = a_field, .ty = i64_ty },
        .{ .name = b_field, .ty = i64_ty },
    });
    const payloads = try store.addSpan(&.{i64_ty});
    const tags = try store.addTags(&.{
        .{ .name = a_tag, .checked_name = a_tag, .payloads = payloads },
        .{ .name = b_tag, .checked_name = b_tag, .payloads = Span.empty() },
    });
    _ = try store.add(.{ .record = fields });
    _ = try store.add(.{ .tag_union = tags });

    try std.testing.expectEqual(@as(?Store.VerifyError, null), store.verify(&name_store));
}

test "monotype type verifier rejects malformed rows and references" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    const a_field = try name_store.internRecordFieldLabel("a");
    const b_field = try name_store.internRecordFieldLabel("b");

    {
        var store = Store.init(std.testing.allocator);
        defer store.deinit();

        const i64_ty = try store.add(.{ .primitive = .i64 });
        const unsorted = try store.addFields(&.{
            .{ .name = b_field, .ty = i64_ty },
            .{ .name = a_field, .ty = i64_ty },
        });
        _ = try store.add(.{ .record = unsorted });
        try std.testing.expectEqual(Store.VerifyError.record_fields_not_sorted, store.verify(&name_store).?);
    }

    {
        var store = Store.init(std.testing.allocator);
        defer store.deinit();

        const bad_fields = try store.addFields(&.{.{ .name = a_field, .ty = @enumFromInt(99) }});
        _ = try store.add(.{ .record = bad_fields });
        try std.testing.expectEqual(Store.VerifyError.type_ref_out_of_bounds, store.verify(&name_store).?);
    }
}

test "monotype digest terminates on recursive structural types" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const field_name = try name_store.internRecordFieldLabel("step");

    // A record whose field is a function returning the record itself.
    const rec_a = try store.add(.zst);
    const fn_a = try store.add(.{ .func = .{ .args = Span.empty(), .ret = rec_a } });
    const fields_a = try store.addFields(&.{.{ .name = field_name, .ty = fn_a }});
    store.set(rec_a, .{ .record = fields_a });

    const first = store.typeDigest(&name_store, rec_a);
    const again = store.typeDigest(&name_store, rec_a);
    try std.testing.expect(std.mem.eql(u8, first.bytes[0..], again.bytes[0..]));

    // An isomorphic cycle at different ids digests identically: cycles are
    // encoded as back references by position, not by id.
    const rec_b = try store.add(.zst);
    const fn_b = try store.add(.{ .func = .{ .args = Span.empty(), .ret = rec_b } });
    const fields_b = try store.addFields(&.{.{ .name = field_name, .ty = fn_b }});
    store.set(rec_b, .{ .record = fields_b });

    const other = store.typeDigest(&name_store, rec_b);
    try std.testing.expect(std.mem.eql(u8, first.bytes[0..], other.bytes[0..]));
}

test "monotype cached digest reuses acyclic child digests and invalidates on refill" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const inner_field = try name_store.internRecordFieldLabel("inner");
    const outer_field = try name_store.internRecordFieldLabel("outer");

    const i64_ty = try store.add(.{ .primitive = .i64 });
    const inner_fields = try store.addFields(&.{.{ .name = inner_field, .ty = i64_ty }});
    const inner = try store.add(.{ .record = inner_fields });

    var inner_stats: Store.DigestStats = .{};
    const inner_digest = store.typeDigestCached(&name_store, inner, &inner_stats);
    try std.testing.expectEqual(@as(u64, 0), inner_stats.cache_hits);
    try std.testing.expectEqual(@as(u64, 2), inner_stats.cache_misses);
    try std.testing.expectEqual(@as(u64, 2), inner_stats.nodes_visited);

    const outer_fields = try store.addFields(&.{.{ .name = outer_field, .ty = inner }});
    const outer = try store.add(.{ .record = outer_fields });

    var outer_stats: Store.DigestStats = .{};
    _ = store.typeDigestCached(&name_store, outer, &outer_stats);
    try std.testing.expectEqual(@as(u64, 1), outer_stats.cache_hits);
    try std.testing.expectEqual(@as(u64, 1), outer_stats.cache_misses);
    try std.testing.expectEqual(@as(u64, 1), outer_stats.nodes_visited);

    store.set(inner, .{ .record = Span.empty() });

    var after_refill_stats: Store.DigestStats = .{};
    const after_refill = store.typeDigestCached(&name_store, inner, &after_refill_stats);
    try std.testing.expect(!std.mem.eql(u8, inner_digest.bytes[0..], after_refill.bytes[0..]));
    try std.testing.expectEqual(@as(u64, 0), after_refill_stats.cache_hits);
    try std.testing.expectEqual(@as(u64, 1), after_refill_stats.cache_misses);
    try std.testing.expectEqual(@as(u64, 1), after_refill_stats.nodes_visited);
}

test "monotype type equality accepts isomorphic recursive structural types" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const field_name = try name_store.internRecordFieldLabel("step");

    const rec_a = try store.add(.zst);
    const fn_a = try store.add(.{ .func = .{ .args = Span.empty(), .ret = rec_a } });
    const fields_a = try store.addFields(&.{.{ .name = field_name, .ty = fn_a }});
    store.set(rec_a, .{ .record = fields_a });

    const rec_b = try store.add(.zst);
    const fn_b = try store.add(.{ .func = .{ .args = Span.empty(), .ret = rec_b } });
    const fields_b = try store.addFields(&.{.{ .name = field_name, .ty = fn_b }});
    store.set(rec_b, .{ .record = fields_b });

    try std.testing.expect(try store.typeEql(&name_store, rec_a, rec_b));

    const str = try store.add(.{ .primitive = .str });
    const rec_c = try store.add(.zst);
    const fields_c = try store.addFields(&.{.{ .name = field_name, .ty = str }});
    store.set(rec_c, .{ .record = fields_c });
    try std.testing.expect(!try store.typeEql(&name_store, rec_a, rec_c));
}

test "monotype digest treats aliases as their backing" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const module_name = try name_store.internModuleName("Test");
    const type_name = try name_store.internTypeName("Pretty");
    const checked_ty: checked.CheckedTypeId = @enumFromInt(1);

    const str = try store.add(.{ .primitive = .str });
    const aliased = try store.add(.{ .named = .{
        .named_type = .{ .module = .{}, .ty = checked_ty },
        .def = .{ .module_name = module_name, .type_name = type_name },
        .kind = .alias,
        .args = Span.empty(),
        .backing = .{ .ty = str, .use = .inspectable },
    } });
    const nominal = try store.add(.{ .named = .{
        .named_type = .{ .module = .{}, .ty = checked_ty },
        .def = .{ .module_name = module_name, .type_name = type_name },
        .kind = .nominal,
        .args = Span.empty(),
        .backing = .{ .ty = str, .use = .inspectable },
    } });

    const str_digest = store.typeDigest(&name_store, str);
    const alias_digest = store.typeDigest(&name_store, aliased);
    const nominal_digest = store.typeDigest(&name_store, nominal);
    try std.testing.expect(std.mem.eql(u8, str_digest.bytes[0..], alias_digest.bytes[0..]));
    try std.testing.expect(!std.mem.eql(u8, str_digest.bytes[0..], nominal_digest.bytes[0..]));
}

test "monotype type equality treats aliases as their backing" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const module_name = try name_store.internModuleName("Test");
    const type_name = try name_store.internTypeName("Pretty");
    const checked_ty: checked.CheckedTypeId = @enumFromInt(1);

    const str = try store.add(.{ .primitive = .str });
    const aliased = try store.add(.{ .named = .{
        .named_type = .{ .module = .{}, .ty = checked_ty },
        .def = .{ .module_name = module_name, .type_name = type_name },
        .kind = .alias,
        .args = Span.empty(),
        .backing = .{ .ty = str, .use = .inspectable },
    } });
    const nominal = try store.add(.{ .named = .{
        .named_type = .{ .module = .{}, .ty = checked_ty },
        .def = .{ .module_name = module_name, .type_name = type_name },
        .kind = .nominal,
        .args = Span.empty(),
        .backing = .{ .ty = str, .use = .inspectable },
    } });

    try std.testing.expect(try store.typeEql(&name_store, str, aliased));
    try std.testing.expect(!try store.typeEql(&name_store, str, nominal));
}

test "monotype type equality compares exact types across stores" {
    const allocator = std.testing.allocator;

    var name_store = names.NameStore.init(allocator);
    defer name_store.deinit();

    var current = Store.init(allocator);
    defer current.deinit();
    var loaded = Store.init(allocator);
    defer loaded.deinit();

    const field_name = try name_store.internRecordFieldLabel("value");
    const module_name = try name_store.internModuleName("Test");
    const type_name = try name_store.internTypeName("Alias");

    const current_unit = try current.add(.zst);
    const current_fields = try current.addFields(&.{.{ .name = field_name, .ty = current_unit }});
    const current_record = try current.add(.{ .record = current_fields });
    const current_args = try current.addSpan(&.{current_record});
    const current_fn = try current.add(.{ .func = .{
        .args = current_args,
        .ret = current_unit,
    } });
    const current_alias = try current.add(.{ .named = .{
        .named_type = .{ .module = .{}, .ty = @enumFromInt(1) },
        .def = .{ .module_name = module_name, .type_name = type_name },
        .kind = .alias,
        .args = Span.empty(),
        .backing = .{ .ty = current_record, .use = .inspectable },
    } });

    _ = try loaded.add(.{ .primitive = .str });
    const loaded_unit = try loaded.add(.zst);
    const loaded_fields = try loaded.addFields(&.{.{ .name = field_name, .ty = loaded_unit }});
    const loaded_record = try loaded.add(.{ .record = loaded_fields });
    const loaded_args = try loaded.addSpan(&.{loaded_record});
    const loaded_fn = try loaded.add(.{ .func = .{
        .args = loaded_args,
        .ret = loaded_unit,
    } });

    const loaded_view = loaded.view();
    const loaded_digests = try allocator.alloc(names.TypeDigest, loaded_view.types.len);
    defer allocator.free(loaded_digests);
    for (loaded_digests, 0..) |*digest, index| {
        digest.* = loaded.typeDigest(&name_store, @enumFromInt(@as(u32, @intCast(index))));
    }
    const loaded_durable = DurableView{
        .types = loaded_view.types,
        .type_digests = loaded_digests,
        .spans = loaded_view.spans,
        .fields = loaded_view.fields,
        .tags = loaded_view.tags,
        .declared_fields = loaded_view.declared_fields,
    };

    try std.testing.expect(try typeEqlAcrossStores(allocator, &name_store, current.view(), current_fn, loaded_durable, loaded_fn));
    try std.testing.expect(try typeEqlAcrossStores(allocator, &name_store, current.view(), current_alias, loaded_durable, loaded_record));
    try std.testing.expect(!try typeEqlAcrossStores(allocator, &name_store, current.view(), current_fn, loaded_durable, loaded_record));
}

test "monotype type equality rejects digest-equal aliases without backing" {
    var name_store = names.NameStore.init(std.testing.allocator);
    defer name_store.deinit();

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const module_name = try name_store.internModuleName("Test");
    const first_name = try name_store.internTypeName("First");
    const second_name = try name_store.internTypeName("Second");

    const first = try store.add(.{ .named = .{
        .named_type = .{ .module = .{}, .ty = @enumFromInt(1) },
        .def = .{ .module_name = module_name, .type_name = first_name },
        .kind = .alias,
        .args = Span.empty(),
        .backing = null,
    } });
    const second = try store.add(.{ .named = .{
        .named_type = .{ .module = .{}, .ty = @enumFromInt(2) },
        .def = .{ .module_name = module_name, .type_name = second_name },
        .kind = .alias,
        .args = Span.empty(),
        .backing = null,
    } });

    const first_digest = store.typeDigest(&name_store, first);
    const second_digest = store.typeDigest(&name_store, second);
    try std.testing.expect(std.mem.eql(u8, first_digest.bytes[0..], second_digest.bytes[0..]));
    try std.testing.expect(!try store.typeEql(&name_store, first, second));
}
