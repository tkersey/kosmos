// Copyright (c) 2026 World contributors. MIT license.
//! Immutable aggregate evaluation. Exportable data has one canonical blob form.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const g = data.graph;
const Store = @import("store.zig").Store;
const DataProjection = @import("store.zig").DataProjection;
const Error = @import("runtime_types.zig").Error;
const read = @import("operands.zig").read;
pub const Parts = struct { tag: p.Id = 0, fields: []const g.Value };
pub const EvaluationError = Error || error{ CollectionCapacity, ElementIndex, WrongVariant };

/// Logical cardinality is independent of the amount of storage. Exportable
/// collections retain their canonical element bytes; internal values retain
/// the store's owned field records.
const Collection = struct {
    element: p.Id,
    count: u64,
    origin: ?g.NodeRef = null,
    offset: usize = 0,
    encoded_origin: ?g.BlobRef = null,
    byte_offset: usize = 0,
    whole_encoded: bool = false,
    storage: union(enum) { encoded: []const u8, fields: []const g.Value },

    // A range owns the immutable collection view it was checked against. It
    // cannot accidentally certify a later, different collection or index.
    const CheckedRange = struct {
        collection: Collection,
        start: u64,
        count: u64,
        fn materialize(self: @This(), values: *Values) Error!Collection {
            const collection = self.collection;
            const start = self.start;
            const count = self.count;
            if (start == 0 and count == collection.count) return collection;
            var byte_offset = collection.byte_offset;
            const storage: @FieldType(Collection, "storage") = switch (collection.storage) {
                .fields => |fields| .{ .fields = fields[@intCast(start)..][0..@intCast(count)] },
                .encoded => |encoded| blk: {
                    const facts = try values.schemaFacts();
                    // A zero minimum denotes one empty encoding only for public
                    // data. Internal schemas can also have a zero minimum.
                    const element: usize = @intCast(collection.element);
                    if (facts.exportable[element] and facts.minimum[element] == 0)
                        break :blk .{ .encoded = &.{} };
                    var reader: data.wire.Reader = .{ .input = encoded };
                    var remaining = start;
                    while (remaining != 0) : (remaining -= 1)
                        _ = try data.admission.readValue(
                            values.allocator,
                            values.schemas,
                            facts,
                            collection.element,
                            &reader,
                        );
                    const offset = reader.position;
                    byte_offset += offset;
                    if (start + count == collection.count)
                        break :blk .{ .encoded = encoded[offset..] };
                    remaining = count;
                    while (remaining != 0) : (remaining -= 1)
                        _ = try data.admission.readValue(
                            values.allocator,
                            values.schemas,
                            facts,
                            collection.element,
                            &reader,
                        );
                    break :blk .{ .encoded = encoded[offset..reader.position] };
                },
            };
            return .{
                .element = collection.element,
                .count = count,
                .storage = storage,
                .origin = collection.origin,
                .encoded_origin = collection.encoded_origin,
                .byte_offset = byte_offset,
                .offset = if (collection.origin != null) collection.offset + @as(
                    usize,
                    @intCast(start),
                ) else 0,
            };
        }
    };
    fn slice(self: Collection, values: *Values, start: u64, count: u64) Error!Collection {
        if (values.store.statistics) |statistics| statistics.collection_range_checks +|= 1;
        if (start > self.count or count > self.count - start) return error.InvalidLength;
        return (CheckedRange{
            .collection = self,
            .start = start,
            .count = count,
        }).materialize(values);
    }
    fn find(self: Collection, values: *Values, index: u64) Error!?g.Value {
        if (values.store.statistics) |statistics| statistics.collection_index_checks +|= 1;
        if (index >= self.count) return null;
        return try self.elementAt(values, index);
    }
    fn elementAt(self: Collection, values: *Values, index: u64) Error!g.Value {
        // Memoize only a whole encoded container with nonempty elements. A
        // huge zero-width collection or many overlapping views must not grow
        // a cache in proportion to access history instead of its source bytes.
        const key: ?DataProjection = if (values.aggregate_storage == .structured and
            self.whole_encoded and self.encoded_origin != null and
            (try values.schemaFacts()).minimum[
                @intCast(self.element)
            ] != 0)
            .{
                .blob = self.encoded_origin.?.id,
                .schema = self.element,
                .field = index,
                .element = true,
                .offset = self.byte_offset,
            }
        else
            null;
        if (key) |selected| if (values.store.data_projections.get(selected)) |cached| {
            if (values.store.statistics) |statistics| statistics.element_projection_hits +|= 1;
            return cached.value;
        };
        // index < count proves that [index, index+1) is in this exact view,
        // including the maximum-u64 and zero-width element cases.
        const item = try (CheckedRange{
            .collection = self,
            .start = index,
            .count = 1,
        }).materialize(values);
        const result = try decodeItem(item, values);
        if (key) |selected| try values.store.rememberProjection(selected, result);
        return result;
    }
    fn decodeItem(item: Collection, values: *Values) Error!g.Value {
        return switch (item.storage) {
            .fields => |fields| fields[0],
            .encoded => |encoded| values.store.literal(values.schemas, .{
                .schema = item.element,
                .bytes = encoded,
            }),
        };
    }

    fn get(self: Collection, values: *Values, index: u64) Error!g.Value {
        if (values.store.statistics) |statistics| statistics.collection_range_checks +|= 1;
        if (index >= self.count) return error.InvalidLength;
        return self.elementAt(values, index);
    }

    fn write(self: Collection, values: *Values, writer: *data.wire.Writer) Error!void {
        switch (self.storage) {
            .encoded => |encoded| try writer.put(encoded),
            .fields => |fields| for (fields) |*field| try writer.put(try values.bytes(field)),
        }
    }
};

pub const Values = struct {
    allocator: std.mem.Allocator,
    schemas: []const p.Schema,
    store: *Store,
    facts: ?data.admission.SchemaFacts = null,
    traits: ?data.traits.Facts = null,
    /// The restricted base retains ordinary recursive data as shared records.
    /// Historical guest execution keeps its existing eager encoding policy.
    aggregate_storage: enum { encoded, structured } = .encoded,

    fn schemaFacts(self: *Values) Error!data.admission.SchemaFacts {
        if (self.facts == null) self.facts = try data.admission.schemas(
            self.allocator,
            self.schemas,
        );
        return self.facts.?;
    }
    pub fn bytes(self: Values, value: *const g.Value) Error![]const u8 {
        return switch (value.body) {
            .scalar => |*scalar| scalar[0..data.scalar.width(
                self.schemas[@intCast(value.schema)],
            ).?],
            .blob => |ref| self.store.blobs.items[@intCast(ref.id)].bytes,
            .reference => blk: {
                const encoded = try @import("value_encoding.zig").encode(
                    self.store.allocator,
                    self.schemas,
                    self.store,
                    value.*,
                );
                errdefer self.store.allocator.free(encoded);
                const stored = try self.store.literalOwned(self.schemas, value.schema, encoded);
                break :blk self.store.blobs.items[@intCast(stored.body.blob.id)].bytes;
            },
            else => error.InvalidValue,
        };
    }
    pub fn natural(schema: p.Id, n: u64) g.Value {
        var bytes_value: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes_value, n, .little);
        return .{ .schema = schema, .body = .{ .scalar = bytes_value } };
    }
    fn write(self: Values, writer: *data.wire.Writer, schema: p.Id, parts: Parts) Error!void {
        switch (self.schemas[@intCast(schema)]) {
            .product, .array => {},
            .sum => try writer.natural(parts.tag),
            .seq, .vector => try writer.natural(parts.fields.len),
            else => return error.TypeMismatch,
        }
        for (parts.fields) |*field| try writer.put(try self.bytes(field));
    }
    pub fn aggregate(self: *Values, schema: p.Id, parts: Parts) Error!g.Value {
        var deferred = false;
        for (parts.fields) |field| if (field.body == .reference or field.body == .owned) {
            deferred = true;
        };
        if (self.aggregate_storage == .encoded and
            !deferred and (try self.schemaFacts()).exportable[@intCast(schema)])
        {
            var measure: data.wire.Writer = .{};
            try self.write(&measure, schema, parts);
            const buffer = try self.store.allocator.alloc(u8, measure.position);
            errdefer self.store.allocator.free(buffer);
            var writer: data.wire.Writer = .{ .output = buffer };
            try self.write(&writer, schema, parts);
            return self.store.literalOwned(self.schemas, schema, buffer);
        }
        if (self.traits == null) self.traits = try data.traits.derive(self.allocator, self.schemas);
        const reference = try self.store.add(.{ .aggregate = .{
            .schema = schema,
            .tag = parts.tag,
            .fields = parts.fields,
        } });
        return .{
            .schema = schema,
            .body = if (self.traits.?.copy[
                @intCast(
                    schema,
                )
            ]) .{ .reference = reference } else .{ .owned = .{
                .node = reference,
            } },
        };
    }
    fn structured(self: *Values, value: g.Value) Error!?Parts {
        switch (value.body) {
            .reference, .owned => {
                const ref = if (value.body == .reference)
                    value.body.reference
                else
                    value.body.owned.node;
                const record = try self.store.get(ref);
                if (record != .aggregate) return error.TypeMismatch;
                return .{ .tag = record.aggregate.tag, .fields = record.aggregate.fields };
            },
            else => {},
        }
        return null;
    }

    /// These accessors consume already admitted or constructed values. Input and
    /// State admission still validate the entire encoding, including unused data.
    fn readTag(self: *Values, value: g.Value) Error!p.Id {
        if (try self.structured(value)) |parts| return parts.tag;
        const shape = self.schemas[@intCast(value.schema)];
        if (shape != .sum) return error.TypeMismatch;
        var reader: data.wire.Reader = .{ .input = try self.bytes(&value) };
        const selected = try reader.natural();
        if (selected >= shape.sum.len) return error.InvalidValue;
        return selected;
    }

    fn projectField(self: *Values, value: g.Value, index: p.Id) Error!g.Value {
        if (try self.structured(value)) |parts| return parts.fields[@intCast(index)];
        const shape = self.schemas[@intCast(value.schema)];
        if (shape != .product or index >= shape.product.len) return error.TypeMismatch;
        const cacheable = self.aggregate_storage == .structured and value.body == .blob;
        const key: ?DataProjection = if (cacheable)
            .{ .blob = value.body.blob.id, .schema = value.schema, .field = index }
        else
            null;
        if (key) |selected| if (self.store.data_projections.get(selected)) |cached| {
            if (self.store.statistics) |statistics| statistics.field_projection_hits +|= 1;
            return cached.value;
        };
        if (self.store.statistics) |statistics| statistics.field_projection_scans +|= 1;
        var reader: data.wire.Reader = .{ .input = try self.bytes(&value) };
        const facts = try self.schemaFacts();
        for (shape.product[0..@intCast(index)]) |schema|
            _ = try data.admission.readValue(self.allocator, self.schemas, facts, schema, &reader);
        const schema = shape.product[@intCast(index)];
        // A product's final field occupies the remainder of its admitted
        // encoding. Revalidating that subtree on every projection turns a
        // recursive tail traversal into repeated whole-tail scans.
        const encoded = if (index + 1 == shape.product.len)
            reader.input[reader.position..]
        else
            try data.admission.readValue(self.allocator, self.schemas, facts, schema, &reader);
        // Materialize only the selected value into its own Store lifetime.
        const result = try self.store.literal(self.schemas, .{
            .schema = schema,
            .bytes = encoded,
        });
        if (key) |selected| try self.store.rememberProjection(selected, result);
        return result;
    }

    fn variantPayload(self: *Values, value: g.Value, expected: p.Id) EvaluationError!g.Value {
        if (try self.structured(value)) |parts| {
            if (parts.tag != expected) return error.WrongVariant;
            return parts.fields[0];
        }
        const selected = try self.readTag(value);
        if (selected != expected) return error.WrongVariant;
        var reader: data.wire.Reader = .{ .input = try self.bytes(&value) };
        _ = try reader.natural();
        return self.store.literal(self.schemas, .{
            .schema = self.schemas[@intCast(value.schema)].sum[@intCast(selected)],
            .bytes = reader.input[reader.position..],
        });
    }

    pub fn split(self: *Values, value: g.Value) Error!Parts {
        if (try self.structured(value)) |parts| return parts;
        var reader: data.wire.Reader = .{ .input = try self.bytes(&value) };
        const shape = self.schemas[@intCast(value.schema)];
        var tag: p.Id = 0;
        const count = switch (shape) {
            .product => |fields| fields.len,
            .sum => blk: {
                tag = try reader.natural();
                break :blk 1;
            },
            else => return error.TypeMismatch,
        };
        const fields = try self.allocator.alloc(g.Value, count);
        const facts = try self.schemaFacts();
        for (fields, 0..) |*field, index| {
            const schema = switch (shape) {
                .product => |types| types[index],
                .sum => |types| types[@intCast(tag)],
                else => unreachable,
            };
            const encoded = if (index + 1 == fields.len) blk: {
                // The last product field (or sole sum payload) ends exactly
                // with this already admitted value. Earlier fields still
                // require their schema-directed boundaries.
                const remainder = reader.input[reader.position..];
                reader.position = reader.input.len;
                break :blk remainder;
            } else try data.admission.readValue(
                self.allocator,
                self.schemas,
                facts,
                schema,
                &reader,
            );
            field.* = try self.store.literal(self.schemas, .{ .schema = schema, .bytes = encoded });
        }
        try reader.finish();
        return .{ .tag = tag, .fields = fields };
    }

    fn collection(self: *Values, value: g.Value) Error!Collection {
        const shape = self.schemas[@intCast(value.schema)];
        const element = switch (shape) {
            .seq => |id| id,
            .vector => |vector| vector.element,
            .array => |array| array.element,
            else => return error.TypeMismatch,
        };
        switch (value.body) {
            .reference, .owned => {
                const ref = if (value.body == .reference)
                    value.body.reference
                else
                    value.body.owned.node;
                if (self.store.encoded_sequences.get(@intCast(ref.id))) |sequence| {
                    const backing_bytes = self.store.blobs.items[
                        @intCast(sequence.backing.id)
                    ].bytes;
                    return .{ .element = element, .count = sequence.count, .storage = .{
                        .encoded = backing_bytes[sequence.start..][0..sequence.length],
                    }, .encoded_origin = sequence.backing, .byte_offset = sequence.start };
                }
                const fields = (try self.store.get(ref)).aggregate.fields;
                return .{
                    .element = element,
                    .count = fields.len,
                    .storage = .{ .fields = fields },
                    .origin = ref,
                };
            },
            else => {},
        }
        var reader: data.wire.Reader = .{ .input = try self.bytes(&value) };
        const count = if (shape == .array) shape.array.length else try reader.natural();
        return .{
            .element = element,
            .count = count,
            .storage = .{ .encoded = reader.input[reader.position..] },
            .encoded_origin = if (value.body == .blob) value.body.blob else null,
            .byte_offset = reader.position,
            .whole_encoded = value.body == .blob,
        };
    }

    fn writeCollection(
        self: *Values,
        writer: *data.wire.Writer,
        schema: p.Id,
        count: u64,
        segments: []const Collection,
    ) Error!void {
        if (self.schemas[@intCast(schema)] != .array) try writer.natural(count);
        for (segments) |segment| try segment.write(self, writer);
    }

    fn rebuildCollection(
        self: *Values,
        schema: p.Id,
        segments: []const Collection,
    ) EvaluationError!g.Value {
        const shape = self.schemas[@intCast(schema)];
        var count: u64 = 0;
        for (segments) |segment| {
            if (shape == .vector and segment.count > shape.vector.maximum - count)
                return error.CollectionCapacity;
            count = std.math.add(u64, count, segment.count) catch return error.InvalidLength;
        }
        if ((try self.schemaFacts()).exportable[@intCast(schema)]) {
            if (segments.len == 1 and (try self.schemaFacts()).minimum[
                @intCast(segments[0].element)
            ] != 0)
                if (segments[0].encoded_origin) |backing| {
                    const encoded_bytes = segments[0].storage.encoded;
                    const base = self.store.blobs.items[@intCast(backing.id)].bytes;
                    if (count != 0 and encoded_bytes.len > base.len / 4) {
                        const ref = try self.store.encodedSequence(schema, .{
                            .backing = backing,
                            .start = segments[0].byte_offset,
                            .length = encoded_bytes.len,
                            .count = count,
                        });
                        return .{ .schema = schema, .body = .{ .reference = ref } };
                    }
                };
            var measure: data.wire.Writer = .{};
            try self.writeCollection(&measure, schema, count, segments);
            const buffer = try self.store.allocator.alloc(u8, measure.position);
            errdefer self.store.allocator.free(buffer);
            var writer: data.wire.Writer = .{ .output = buffer };
            try self.writeCollection(&writer, schema, count, segments);
            return self.store.literalOwned(self.schemas, schema, buffer);
        }
        const physical_count = std.math.cast(usize, count) orelse return error.OutOfMemory;
        if (segments.len == 1) if (segments[0].origin) |origin| {
            if (self.traits == null) self.traits = try data.traits.derive(
                self.allocator,
                self.schemas,
            );
            const reference = try self.store.aggregateSlice(
                schema,
                origin,
                segments[0].offset,
                physical_count,
            );
            return .{ .schema = schema, .body = if (self.traits.?.copy[@intCast(schema)])
                .{ .reference = reference }
            else
                .{ .owned = .{ .node = reference } } };
        };
        const fields = try self.allocator.alloc(g.Value, physical_count);
        var offset: usize = 0;
        for (segments) |segment| {
            const source = switch (segment.storage) {
                .fields => |source| source,
                .encoded => return error.InvalidValue,
            };
            @memcpy(fields[offset..][0..source.len], source);
            offset += source.len;
        }
        return self.aggregate(schema, .{ .fields = fields });
    }

    pub fn evaluate(
        self: *Values,
        instruction: data.activation.Instruction,
        result: p.Id,
        slots: anytype,
    ) EvaluationError!g.Value {
        if (instruction.opcode == .select) {
            const condition = (try read(slots, instruction.operands[0])).body.scalar[0] == 1;
            return (try read(slots, instruction.operands[if (condition) @as(usize, 1) else 2]));
        }
        switch (instruction.opcode) {
            .product, .variant, .sequence => {
                const fields = try self.allocator.alloc(g.Value, instruction.operands.len);
                for (fields, instruction.operands) |*field, slot| field.* = (try read(slots, slot));
                return self.aggregate(result, .{ .tag = instruction.immediate, .fields = fields });
            },
            else => {},
        }
        const source = (try read(slots, instruction.operands[0]));
        switch (instruction.opcode) {
            .field => return self.projectField(source, instruction.immediate),
            .variant_tag => return natural(result, try self.readTag(source)),
            .variant_payload => return self.variantPayload(source, instruction.immediate),
            else => {},
        }
        return self.evaluateCollection(instruction, result, slots);
    }

    fn evaluateCollection(
        self: *Values,
        instruction: data.activation.Instruction,
        result: p.Id,
        slots: anytype,
    ) EvaluationError!g.Value {
        const source = (try read(slots, instruction.operands[0]));
        const items = try self.collection(source);
        switch (instruction.opcode) {
            .sequence_length => return natural(result, items.count),
            .sequence_get => {
                const index_value = (try read(slots, instruction.operands[1]));
                const index = std.mem.readInt(u64, index_value.body.scalar[0..8], .little);
                const shape = self.schemas[@intCast(result)].sum;
                const item = try items.find(self, index);
                const found = item != null;
                const payload = item orelse natural(shape[0], 0);
                return self.aggregate(result, .{
                    .tag = @intFromBool(found),
                    .fields = &.{payload},
                });
            },
            .sequence_append, .sequence_concat => {
                const second = (try read(slots, instruction.operands[1]));
                const right: Collection = if (instruction.opcode == .sequence_concat)
                    try self.collection(second)
                else
                    .{
                        .element = items.element,
                        .count = 1,
                        .storage = .{ .fields = &.{second} },
                    };
                return self.rebuildCollection(result, &.{ items, right });
            },
            .sequence_set, .sequence_take => {
                const operand = (try read(slots, instruction.operands[1])).body.scalar;
                const index = std.mem.readInt(u64, &operand, .little);
                if (instruction.opcode == .sequence_take) {
                    const prefix = try items.slice(self, 0, @min(index, items.count));
                    return self.rebuildCollection(result, &.{prefix});
                }
                if (index >= items.count) return error.ElementIndex;
                const replacement: Collection = .{
                    .element = items.element,
                    .count = 1,
                    .storage = .{ .fields = &.{(try read(slots, instruction.operands[2]))} },
                };
                return self.rebuildCollection(result, &.{
                    try items.slice(self, 0, index),
                    replacement,
                    try items.slice(self, index + 1, items.count - index - 1),
                });
            },
            .sequence_pop, .sequence_pop_last => {
                return self.popCollection(instruction, result, source.schema, items);
            },
            else => return error.UnsupportedTransition,
        }
    }

    fn popCollection(
        self: *Values,
        instruction: data.activation.Instruction,
        result: p.Id,
        source: p.Id,
        items: Collection,
    ) EvaluationError!g.Value {
        const present = items.count != 0;
        switch (instruction.opcode) {
            .sequence_pop => {
                const shape = self.schemas[@intCast(result)].sum;
                const payload: g.Value = if (!present) natural(shape[0], 0) else blk: {
                    const remaining = try items.slice(self, 1, items.count - 1);
                    const tail = try self.rebuildCollection(source, &.{remaining});
                    const first = try items.get(self, 0);
                    break :blk try self.aggregate(shape[1], .{ .fields = &.{ first, tail } });
                };
                return self.aggregate(result, .{
                    .tag = @intFromBool(present),
                    .fields = &.{payload},
                });
            },
            .sequence_pop_last => {
                const shape = self.schemas[@intCast(result)].product;
                const optional = self.schemas[@intCast(shape[1])].sum;
                const count = items.count;
                const remaining = try items.slice(self, 0, if (count == 0) 0 else count - 1);
                const remainder = try self.rebuildCollection(source, &.{remaining});
                const item = if (present)
                    try items.get(self, count - 1)
                else
                    natural(optional[0], 0);
                const last = try self.aggregate(shape[1], .{
                    .tag = @intFromBool(present),
                    .fields = &.{item},
                });
                return self.aggregate(result, .{ .fields = &.{ remainder, last } });
            },
            else => return error.UnsupportedTransition,
        }
    }
};
