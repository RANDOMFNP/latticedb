//! Explicit secondary indexes for node and edge properties.
//!
//! Definitions are stored separately from index entries. Entry keys use a
//! digest of the complete typed property value, followed by the entity ID.
//! This keeps keys fixed-size even for large strings, byte arrays, vectors,
//! lists, and maps. Callers must verify returned entities against the source
//! record, which also makes digest collisions harmless.

const std = @import("std");
const lattice = @import("lattice");

const Allocator = std.mem.Allocator;
const BTree = lattice.storage.btree.BTree;
const BTreeError = lattice.storage.btree.BTreeError;
const PropertyValue = lattice.core.types.PropertyValue;
const Property = lattice.graph.node.Property;
const SymbolId = lattice.graph.symbols.SymbolId;

pub const EntityKind = enum(u8) {
    node = 1,
    edge = 2,
};

pub const PropertyIndexError = error{
    NotFound,
    AlreadyExists,
    InvalidData,
    IoError,
    OutOfMemory,
};

const DEFINITION_KEY_SIZE = 5;
const ENTRY_PREFIX_SIZE = 36;
const ENTRY_KEY_SIZE = ENTRY_PREFIX_SIZE + 8;
const VALUE_DIGEST_SIZE = 32;

pub const Definition = struct {
    kind: EntityKind,
    scope_id: SymbolId,
    property_id: SymbolId,
};

pub const PropertyIndex = struct {
    allocator: Allocator,
    catalog: *BTree,
    node_entries: *BTree,
    edge_entries: *BTree,

    const Self = @This();

    pub fn init(allocator: Allocator, catalog: *BTree, node_entries: *BTree, edge_entries: *BTree) Self {
        return .{
            .allocator = allocator,
            .catalog = catalog,
            .node_entries = node_entries,
            .edge_entries = edge_entries,
        };
    }

    pub fn createDefinition(self: *Self, definition: Definition) PropertyIndexError!void {
        const key = definitionKey(definition);
        if (self.catalog.contains(&key) catch return PropertyIndexError.IoError) {
            return PropertyIndexError.AlreadyExists;
        }
        self.catalog.insert(&key, &.{}) catch |err| return mapBTreeError(err);
    }

    pub fn dropDefinition(self: *Self, definition: Definition) PropertyIndexError!void {
        const key = definitionKey(definition);
        self.catalog.delete(&key) catch |err| return mapBTreeError(err);
        try self.clearEntries(definition);
    }

    pub fn hasDefinition(self: *Self, definition: Definition) PropertyIndexError!bool {
        const key = definitionKey(definition);
        return self.catalog.contains(&key) catch return PropertyIndexError.IoError;
    }

    pub fn add(
        self: *Self,
        definition: Definition,
        entity_id: u64,
        value: PropertyValue,
    ) PropertyIndexError!void {
        const key = entryKey(definition.scope_id, definition.property_id, value, entity_id);
        self.entryTree(definition.kind).insert(&key, &.{}) catch |err| switch (err) {
            BTreeError.DuplicateKey => return,
            else => return mapBTreeError(err),
        };
    }

    pub fn remove(
        self: *Self,
        definition: Definition,
        entity_id: u64,
        value: PropertyValue,
    ) PropertyIndexError!void {
        const key = entryKey(definition.scope_id, definition.property_id, value, entity_id);
        self.entryTree(definition.kind).delete(&key) catch |err| switch (err) {
            BTreeError.KeyNotFound => return,
            else => return mapBTreeError(err),
        };
    }

    pub fn indexNode(self: *Self, node_id: u64, labels: []const SymbolId, properties: []const Property) PropertyIndexError!void {
        var iter = try self.definitionIterator(.node);
        defer iter.deinit();
        while (try nextDefinition(&iter)) |definition| {
            if (!containsSymbol(labels, definition.scope_id)) continue;
            if (findProperty(properties, definition.property_id)) |property| {
                try self.add(definition, node_id, property.value);
            }
        }
    }

    pub fn removeNode(self: *Self, node_id: u64, labels: []const SymbolId, properties: []const Property) PropertyIndexError!void {
        var iter = try self.definitionIterator(.node);
        defer iter.deinit();
        while (try nextDefinition(&iter)) |definition| {
            if (!containsSymbol(labels, definition.scope_id)) continue;
            if (findProperty(properties, definition.property_id)) |property| {
                try self.remove(definition, node_id, property.value);
            }
        }
    }

    pub fn indexEdge(self: *Self, edge_id: u64, edge_type: SymbolId, properties: []const Property) PropertyIndexError!void {
        var iter = try self.definitionIterator(.edge);
        defer iter.deinit();
        while (try nextDefinition(&iter)) |definition| {
            if (definition.scope_id != edge_type) continue;
            if (findProperty(properties, definition.property_id)) |property| {
                try self.add(definition, edge_id, property.value);
            }
        }
    }

    pub fn removeEdge(self: *Self, edge_id: u64, edge_type: SymbolId, properties: []const Property) PropertyIndexError!void {
        var iter = try self.definitionIterator(.edge);
        defer iter.deinit();
        while (try nextDefinition(&iter)) |definition| {
            if (definition.scope_id != edge_type) continue;
            if (findProperty(properties, definition.property_id)) |property| {
                try self.remove(definition, edge_id, property.value);
            }
        }
    }

    pub fn lookup(
        self: *Self,
        definition: Definition,
        value: PropertyValue,
        limit: usize,
    ) PropertyIndexError![]u64 {
        if (!try self.hasDefinition(definition)) return PropertyIndexError.NotFound;

        const prefix = entryPrefix(definition.scope_id, definition.property_id, value);
        var end = prefix;
        if (!incrementBytes(&end)) return self.allocator.alloc(u64, 0) catch return PropertyIndexError.OutOfMemory;

        var iter = self.entryTree(definition.kind).range(&prefix, &end) catch |err| return mapBTreeError(err);
        defer iter.deinit();

        var results: std.ArrayList(u64) = .empty;
        errdefer results.deinit(self.allocator);
        while (results.items.len < limit) {
            const entry = iter.next() catch |err| return mapBTreeError(err);
            const found = entry orelse break;
            if (found.key.len != ENTRY_KEY_SIZE or !std.mem.eql(u8, found.key[0..ENTRY_PREFIX_SIZE], &prefix)) {
                return PropertyIndexError.InvalidData;
            }
            results.append(self.allocator, std.mem.readInt(u64, found.key[ENTRY_PREFIX_SIZE..ENTRY_KEY_SIZE], .big)) catch {
                return PropertyIndexError.OutOfMemory;
            };
        }
        return results.toOwnedSlice(self.allocator) catch return PropertyIndexError.OutOfMemory;
    }

    pub fn clearEntries(self: *Self, definition: Definition) PropertyIndexError!void {
        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u16, prefix[0..2], definition.scope_id, .big);
        std.mem.writeInt(u16, prefix[2..4], definition.property_id, .big);
        var end = prefix;
        if (!incrementBytes(&end)) return;

        var keys: std.ArrayList([ENTRY_KEY_SIZE]u8) = .empty;
        defer keys.deinit(self.allocator);
        var iter = self.entryTree(definition.kind).range(&prefix, &end) catch |err| return mapBTreeError(err);
        while (iter.next() catch |err| {
            iter.deinit();
            return mapBTreeError(err);
        }) |entry| {
            if (entry.key.len != ENTRY_KEY_SIZE) {
                iter.deinit();
                return PropertyIndexError.InvalidData;
            }
            keys.append(self.allocator, entry.key[0..ENTRY_KEY_SIZE].*) catch {
                iter.deinit();
                return PropertyIndexError.OutOfMemory;
            };
        }
        iter.deinit();

        for (keys.items) |key| {
            self.entryTree(definition.kind).delete(&key) catch |err| switch (err) {
                BTreeError.KeyNotFound => {},
                else => return mapBTreeError(err),
            };
        }
    }

    pub fn definitionIterator(self: *Self, kind: EntityKind) PropertyIndexError!BTree.Iterator {
        const start = [_]u8{@intFromEnum(kind)};
        const end = [_]u8{@intFromEnum(kind) + 1};
        return self.catalog.range(&start, &end) catch |err| return mapBTreeError(err);
    }

    pub fn nextDefinition(iter: *BTree.Iterator) PropertyIndexError!?Definition {
        const entry = iter.next() catch |err| return mapBTreeError(err);
        const found = entry orelse return null;
        if (found.key.len != DEFINITION_KEY_SIZE) return PropertyIndexError.InvalidData;
        const kind: EntityKind = switch (found.key[0]) {
            @intFromEnum(EntityKind.node) => .node,
            @intFromEnum(EntityKind.edge) => .edge,
            else => return PropertyIndexError.InvalidData,
        };
        return .{
            .kind = kind,
            .scope_id = std.mem.readInt(u16, found.key[1..3], .big),
            .property_id = std.mem.readInt(u16, found.key[3..5], .big),
        };
    }

    fn entryTree(self: *Self, kind: EntityKind) *BTree {
        return switch (kind) {
            .node => self.node_entries,
            .edge => self.edge_entries,
        };
    }
};

fn definitionKey(definition: Definition) [DEFINITION_KEY_SIZE]u8 {
    var key: [DEFINITION_KEY_SIZE]u8 = undefined;
    key[0] = @intFromEnum(definition.kind);
    std.mem.writeInt(u16, key[1..3], definition.scope_id, .big);
    std.mem.writeInt(u16, key[3..5], definition.property_id, .big);
    return key;
}

fn entryPrefix(scope_id: SymbolId, property_id: SymbolId, value: PropertyValue) [ENTRY_PREFIX_SIZE]u8 {
    var prefix: [ENTRY_PREFIX_SIZE]u8 = undefined;
    std.mem.writeInt(u16, prefix[0..2], scope_id, .big);
    std.mem.writeInt(u16, prefix[2..4], property_id, .big);
    hashPropertyValue(value, prefix[4..36]);
    return prefix;
}

fn entryKey(scope_id: SymbolId, property_id: SymbolId, value: PropertyValue, entity_id: u64) [ENTRY_KEY_SIZE]u8 {
    var key: [ENTRY_KEY_SIZE]u8 = undefined;
    const prefix = entryPrefix(scope_id, property_id, value);
    @memcpy(key[0..ENTRY_PREFIX_SIZE], &prefix);
    std.mem.writeInt(u64, key[ENTRY_PREFIX_SIZE..ENTRY_KEY_SIZE], entity_id, .big);
    return key;
}

fn hashPropertyValue(value: PropertyValue, output: *[VALUE_DIGEST_SIZE]u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashValue(&hasher, value);
    hasher.final(output);
}

fn hashValue(hasher: *std.crypto.hash.sha2.Sha256, value: PropertyValue) void {
    const tag: u8 = @intFromEnum(value);
    hasher.update(&.{tag});
    switch (value) {
        .null_val => {},
        .bool_val => |v| hasher.update(&.{@intFromBool(v)}),
        .int_val => |v| hashInt(hasher, i64, v),
        .float_val => |v| hashInt(hasher, u64, @bitCast(if (v == 0) @as(f64, 0) else v)),
        .string_val => |v| hashBytes(hasher, v),
        .bytes_val => |v| hashBytes(hasher, v),
        .vector_val => |values| {
            hashInt(hasher, u64, values.len);
            for (values) |v| hashInt(hasher, u32, @bitCast(if (v == 0) @as(f32, 0) else v));
        },
        .list_val => |values| {
            hashInt(hasher, u64, values.len);
            for (values) |item| hashValue(hasher, item);
        },
        .map_val => |entries| {
            hashInt(hasher, u64, entries.len);
            for (entries) |entry| {
                hashBytes(hasher, entry.key);
                hashValue(hasher, entry.value);
            }
        },
    }
}

fn hashBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hashInt(hasher, u64, bytes.len);
    hasher.update(bytes);
}

fn hashInt(hasher: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    hasher.update(&bytes);
}

fn containsSymbol(values: []const SymbolId, needle: SymbolId) bool {
    for (values) |value| if (value == needle) return true;
    return false;
}

fn findProperty(properties: []const Property, property_id: SymbolId) ?Property {
    for (properties) |property| if (property.key_id == property_id) return property;
    return null;
}

fn incrementBytes(bytes: []u8) bool {
    var index = bytes.len;
    while (index > 0) {
        index -= 1;
        if (bytes[index] != 0xff) {
            bytes[index] += 1;
            @memset(bytes[index + 1 ..], 0);
            return true;
        }
    }
    return false;
}

fn mapBTreeError(err: BTreeError) PropertyIndexError {
    return switch (err) {
        BTreeError.KeyNotFound => PropertyIndexError.NotFound,
        BTreeError.DuplicateKey => PropertyIndexError.AlreadyExists,
        BTreeError.OutOfMemory => PropertyIndexError.OutOfMemory,
        BTreeError.InvalidPage => PropertyIndexError.InvalidData,
        else => PropertyIndexError.IoError,
    };
}

test "property value digest normalizes signed zero" {
    var positive: [VALUE_DIGEST_SIZE]u8 = undefined;
    var negative: [VALUE_DIGEST_SIZE]u8 = undefined;
    hashPropertyValue(.{ .float_val = 0.0 }, &positive);
    hashPropertyValue(.{ .float_val = -0.0 }, &negative);
    try std.testing.expectEqualSlices(u8, &positive, &negative);
}
