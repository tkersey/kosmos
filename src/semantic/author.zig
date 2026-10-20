//! Small conveniences for constructing ordinary Horos source expressions.
//! These functions run at authoring time; they do not execute guest operations.
const data = @import("horos_data");
const source = @import("horos").source;
const Id = data.program.Id;
const Error = source.Error;

pub const Author = struct {
    b: *source.Builder,
    unit: Id,
    integer: Id,
    boolean: Id,
    zero: Id,
    one: Id,
    unit_value: Id,
    failure_literal: Id,

    pub fn init(b: *source.Builder) Error!Author {
        const unit_value = try b.constant(void, {});
        return .{
            .b = b,
            .unit = try b.scalar(void),
            .integer = try b.scalar(u64),
            .boolean = try b.scalar(bool),
            .zero = try b.constant(u64, 0),
            .one = try b.constant(u64, 1),
            .unit_value = unit_value,
            .failure_literal = try b.failureLiteral(unit_value),
        };
    }
    pub fn param(self: Author, function: Id, index: usize) Error!Id {
        return self.b.reference(self.b.parameter(function, index));
    }
    pub fn literal(self: Author, comptime T: type, value: T) Error!Id {
        const projection = @import("projection.zig");
        return self.b.literal(.{
            .schema = try projection.schema(T, self.b),
            .bytes = try projection.encode(T, self.b.allocator(), value),
        });
    }
    pub fn field(self: Author, value: Id, index: usize) Error!Id {
        const shape = self.b.schemas.items[@intCast(self.b.values.items[@intCast(value)].schema)];
        return self.b.primitive(shape.product[index], .field, &.{value}, index);
    }
    pub fn replace(self: Author, value: Id, index: usize, replacement: Id) Error!Id {
        const schema = self.b.values.items[@intCast(value)].schema;
        const fields = self.b.schemas.items[@intCast(schema)].product;
        const values = try self.b.allocator().alloc(Id, fields.len);
        for (values, 0..) |*item, i|
            item.* = if (i == index) replacement else try self.field(value, i);
        return self.tuple(schema, values);
    }
    /// Required accesses are for source-established preconditions. Their failure
    /// is an outer implementation fault, never a fabricated guest exception.
    pub fn payload(self: Author, value: Id, tag: usize) Error!Id {
        const schema = self.b.values.items[@intCast(value)].schema;
        return self.b.value(
            .{
                .schema = self.b.schemas.items[
                    @intCast(schema)
                ].sum[tag],
                .expression = .{
                    .primitive = .{
                        .opcode = .variant_payload,
                        .operands = &.{value},
                        .immediate = tag,
                        .failures = &.{.{
                            .kind = .invalid_variant,
                            .value = self.failure_literal,
                        }},
                    },
                },
            },
        );
    }
    pub fn required(self: Author, sequence: Id, index: Id) Error!Id {
        const schema = self.b.values.items[@intCast(sequence)].schema;
        const element = switch (self.b.schemas.items[@intCast(schema)]) {
            .seq => |item| item,
            .array => |array| array.element,
            .vector => |vector| vector.element,
            else => return error.InvalidSource,
        };
        const optional = try self.b.schema(.{ .sum = &.{ self.unit, element } });
        return self.payload(try self.b.primitive(
            optional,
            .sequence_get,
            &.{ sequence, index },
            0,
        ), 1);
    }
    pub fn tuple(self: Author, schema: Id, values: []const Id) Error!Id {
        return self.b.primitive(schema, .product, values, 0);
    }
    pub fn variant(self: Author, schema: Id, tag: Id, value: Id) Error!Id {
        return self.b.primitive(schema, .variant, &.{value}, tag);
    }
    pub fn binary(self: Author, op: data.program.Opcode, left: Id, right: Id) Error!Id {
        const schema = switch (op) {
            .less, .equal => self.boolean,
            else => self.integer,
        };
        const faults: []const data.program.Fault = switch (op) {
            .integer_add, .integer_sub, .integer_mul => &.{.arithmetic_overflow},
            .integer_div, .integer_rem => &.{ .arithmetic_overflow, .division_by_zero },
            else => &.{},
        };
        var failures: [2]data.program.InstructionFailure = undefined;
        for (faults, 0..) |fault, i| failures[i] = .{
            .kind = fault,
            .value = self.failure_literal,
        };
        return self.b.value(.{ .schema = schema, .expression = .{ .primitive = .{
            .opcode = op,
            .operands = &.{ left, right },
            .failures = failures[0..faults.len],
        } } });
    }
    pub fn checked(
        self: Author,
        schema: Id,
        op: data.program.Opcode,
        operands: []const Id,
        faults: []const data.program.Fault,
    ) Error!Id {
        const failures = try self.b.allocator().alloc(data.program.InstructionFailure, faults.len);
        for (failures, faults) |*failure, fault| failure.* = .{
            .kind = fault,
            .value = self.failure_literal,
        };
        return self.b.value(.{ .schema = schema, .expression = .{ .primitive = .{
            .opcode = op,
            .operands = operands,
            .failures = failures,
        } } });
    }
    pub fn concat(self: Author, left: Id, right: Id) Error!Id {
        return self.checked(
            try self.b.schema(.bytes),
            .blob_concat,
            &.{ left, right },
            &.{.capacity_exceeded},
        );
    }
    pub fn slice(self: Author, bytes: Id, start: Id, end: Id) Error!Id {
        return self.checked(
            try self.b.schema(.bytes),
            .blob_slice,
            &.{ bytes, start, end },
            &.{.capacity_exceeded},
        );
    }
    pub fn convert(self: Author, value: Id, target: Id, fallible: bool) Error!Id {
        return self.checked(
            target,
            .integer_convert,
            &.{value},
            if (fallible) &.{.arithmetic_overflow} else &.{},
        );
    }
    pub fn call(self: Author, function: Id, arguments: []const Id) Error!Id {
        return self.b.term(.{ .call = .{ .function = function, .arguments = arguments } });
    }
    pub fn when(self: Author, condition: Id, yes: Id, no: Id) Error!Id {
        return self.b.term(.{ .conditional = .{
            .condition = condition,
            .when_true = yes,
            .when_false = no,
        } });
    }
    pub fn fail(self: Author) Error!Id {
        return self.b.term(.{ .fail = self.unit_value });
    }
};
