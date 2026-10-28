const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const compiler = @import("compiler.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Value = source.ast.Value;
const Term = source.ast.Term;
const Function = source.ast.Function;
const Expression = @FieldType(Value, "expression");
const Primitive = @FieldType(Expression, "primitive");
const Case = std.meta.Elem(@FieldType(@FieldType(Term, "match_sum"), "cases"));
pub const Input = struct { module: source.Module, site: source.consumer.Site };
const Copy = struct {
    original: []const Value,
    selected: []const bool,
    parameters: []const Id,
    variable_base: Id,
    cursor: Id,
    mapping: []const Id,
    output: []const Value,
};
const Definition = struct {
    entry: Id,
    inline_call: Id,
    fill_flags: Id,
    fill_ids: Id,
    mark: Id,
    select: Id,
    copy: Id,
    map_ids: Id,
    parameter: Id,
    variables: Id,
    prefix: Id,
    arguments: Id,
    bindings: Id,
    terms: Id,
    term: Id,
    cases: Id,
    functions: Id,
    uses_result: Id,
};

pub fn define(b: *source.Builder) !source.Module {
    const e = try Author.init(b);
    const d = try definitions(e);
    try defineFill(e, d.fill_flags, bool);
    try defineFill(e, d.fill_ids, Id);
    try defineMark(e, d);
    try defineSelect(e, d);
    try defineMapIds(e, d);
    try defineParameter(e, d);
    try defineCopy(e, d);
    try defineVariables(e, d);
    try definePrefix(e, d);
    try defineArguments(e, d);
    try defineBindings(e, d);
    try defineCases(e, d);
    try defineTerm(e, d);
    try defineTerms(e, d);
    try defineFunctions(e, d);
    try defineUsesResult(e, d);
    try defineInline(e, d);
    try defineEntry(e, d);
    return b.module(d.entry, e.unit);
}

fn definitions(e: Author) !Definition {
    const ids = try shape(e, []const Id);
    const flags = try shape(e, []const bool);
    const values = try shape(e, []const Value);
    const terms = try shape(e, []const Term);
    const cases = try shape(e, []const Case);
    const functions = try shape(e, []const Function);
    const module = try shape(e, source.Module);
    return .{
        .entry = try declare(e, &.{try shape(e, Input)}, compiler.RecordProposal),
        .inline_call = try declare(e, &.{ module, e.integer }, source.Module),
        .fill_flags = try declare(e, &.{ e.integer, flags }, []const bool),
        .fill_ids = try declare(e, &.{ e.integer, ids }, []const Id),
        .mark = try declare(e, &.{ flags, ids, e.integer }, []const bool),
        .select = try declare(e, &.{ values, flags, e.integer }, []const bool),
        .copy = try declare(e, &.{try shape(e, Copy)}, Copy),
        .map_ids = try declare(e, &.{ ids, ids, e.integer, ids }, []const Id),
        .parameter = try declare(e, &.{ ids, e.integer, e.integer }, Id),
        .variables = try declare(e, &.{ ids, ids, e.integer, ids }, []const Id),
        .prefix = try declare(e, &.{ terms, e.integer, e.integer, terms }, []const Term),
        .arguments = try declare(e, &.{ ids, e.integer, terms }, []const Term),
        .bindings = try declare(
            e,
            &.{ e.integer, e.integer, e.integer, e.integer, terms },
            []const Term,
        ),
        .terms = try declare(
            e,
            &.{ terms, e.integer, e.integer, e.integer, e.integer, terms },
            []const Term,
        ),
        .term = try declare(e, &.{ try shape(e, Term), e.integer, e.integer, e.integer }, Term),
        .cases = try declare(
            e,
            &.{ cases, e.integer, e.integer, e.integer, e.integer, cases },
            []const Case,
        ),
        .functions = try declare(
            e,
            &.{ functions, e.integer, e.integer, e.integer, e.integer, functions },
            []const Function,
        ),
        .uses_result = try declare(e, &.{ values, ids, e.integer, e.integer, e.integer }, bool),
    };
}

fn shape(e: Author, comptime T: type) !Id {
    return projection.schema(T, e.b);
}

fn declare(e: Author, parameters: []const Id, comptime T: type) !Id {
    return e.b.declare(parameters, try shape(e, T), &.{}, &.{});
}

fn field(e: Author, comptime T: type, value: Id, comptime name: []const u8) !Id {
    return e.field(value, std.meta.fieldIndex(T, name).?);
}

fn replace(e: Author, comptime T: type, value: Id, comptime name: []const u8, next: Id) !Id {
    return e.replace(value, std.meta.fieldIndex(T, name).?, next);
}

fn length(e: Author, sequence: Id) !Id {
    return e.b.primitive(e.integer, .sequence_length, &.{sequence}, 0);
}

fn append(e: Author, sequence: Id, value: Id) !Id {
    return e.b.primitive(
        e.b.values.items[@intCast(sequence)].schema,
        .sequence_append,
        &.{ sequence, value },
        0,
    );
}

fn set(e: Author, sequence: Id, index: Id, value: Id) !Id {
    return e.checked(
        e.b.values.items[@intCast(sequence)].schema,
        .sequence_set,
        &.{ sequence, index, value },
        &.{.invalid_index},
    );
}

fn variant(e: Author, comptime T: type, comptime name: []const u8, item: Id) !Id {
    return e.variant(try shape(e, T), std.meta.fieldIndex(T, name).?, item);
}

fn payload(e: Author, comptime T: type, value: Id, comptime name: []const u8) !Id {
    return e.payload(value, std.meta.fieldIndex(T, name).?);
}

fn tagged(e: Author, comptime T: type, value: Id, comptime name: []const u8) !Id {
    const tag = try e.b.primitive(e.integer, .variant_tag, &.{value}, 0);
    return e.binary(.equal, tag, try e.b.constant(u64, std.meta.fieldIndex(T, name).?));
}

fn defineFill(e: Author, function: Id, comptime T: type) !void {
    const count = try e.param(function, 0);
    const result = try e.param(function, 1);
    const zero = if (T == bool) try e.b.constant(bool, false) else e.zero;
    const next = try e.call(function, &.{ count, try append(e, result, zero) });
    try e.b.define(function, try e.when(
        try e.binary(.less, try length(e, result), count),
        next,
        try e.b.pure(result),
    ));
}

fn defineMark(e: Author, d: Definition) !void {
    const selected = try e.param(d.mark, 0);
    const operands = try e.param(d.mark, 1);
    const cursor = try e.param(d.mark, 2);
    const next = try e.call(d.mark, &.{
        try set(e, selected, try e.required(operands, cursor), try e.b.constant(bool, true)),
        operands,
        try e.binary(.integer_add, cursor, e.one),
    });
    try e.b.define(d.mark, try e.when(
        try e.binary(.less, cursor, try length(e, operands)),
        next,
        try e.b.pure(selected),
    ));
}

fn defineSelect(e: Author, d: Definition) !void {
    const values = try e.param(d.select, 0);
    const selected = try e.param(d.select, 1);
    const remaining = try e.param(d.select, 2);
    const cursor = try e.binary(.integer_sub, remaining, e.one);
    const expression = try field(e, Value, try e.required(values, cursor), "expression");
    const primitive = try payload(e, Expression, expression, "primitive");
    const marked = try e.b.variable(try shape(e, []const bool));
    const advance = try e.call(d.select, &.{ values, selected, cursor });
    const expand = try e.b.bind(marked, try e.call(d.mark, &.{
        selected, try field(e, Primitive, primitive, "operands"), e.zero,
    }), try e.call(d.select, &.{ values, try e.b.reference(marked), cursor }));
    const visit = try e.when(try tagged(e, Expression, expression, "primitive"), expand, advance);
    const active = try e.when(try e.required(selected, cursor), visit, advance);
    try e.b.define(d.select, try e.when(
        try e.binary(.less, e.zero, remaining),
        active,
        try e.b.pure(selected),
    ));
}

fn defineMapIds(e: Author, d: Definition) !void {
    const ids = try e.param(d.map_ids, 0);
    const mapping = try e.param(d.map_ids, 1);
    const cursor = try e.param(d.map_ids, 2);
    const result = try e.param(d.map_ids, 3);
    const next = try e.call(d.map_ids, &.{
        ids,                                                                         mapping,
        try e.binary(
            .integer_add,
            cursor,
            e.one,
        ),
        try append(e, result, try e.required(mapping, try e.required(ids, cursor))),
    });
    try e.b.define(d.map_ids, try e.when(
        try e.binary(.less, cursor, try length(e, ids)),
        next,
        try e.b.pure(result),
    ));
}

fn defineParameter(e: Author, d: Definition) !void {
    const parameters = try e.param(d.parameter, 0);
    const target = try e.param(d.parameter, 1);
    const cursor = try e.param(d.parameter, 2);
    const next = try e.call(d.parameter, &.{
        parameters, target, try e.binary(.integer_add, cursor, e.one),
    });
    const visit = try e.when(
        try e.binary(.equal, try e.required(parameters, cursor), target),
        try e.b.pure(cursor),
        next,
    );
    try e.b.define(d.parameter, try e.when(
        try e.binary(.less, cursor, try length(e, parameters)),
        visit,
        try e.fail(),
    ));
}

fn copyNext(e: Author, d: Definition, state: Id, replacement: ?Id) !Id {
    const cursor = try field(e, Copy, state, "cursor");
    var next = try replace(e, Copy, state, "cursor", try e.binary(.integer_add, cursor, e.one));
    if (replacement) |value| {
        const output = try field(e, Copy, state, "output");
        const mapping = try field(e, Copy, state, "mapping");
        next = try replace(
            e,
            Copy,
            next,
            "mapping",
            try set(e, mapping, cursor, try length(e, output)),
        );
        next = try replace(e, Copy, next, "output", try append(e, output, value));
    }
    return e.call(d.copy, &.{next});
}

fn copiedVariable(e: Author, d: Definition, state: Id, value: Id, expression: Id) !Id {
    const ordinal = try e.b.variable(e.integer);
    const fresh = try e.binary(
        .integer_add,
        try field(e, Copy, state, "variable_base"),
        try e.b.reference(ordinal),
    );
    const changed = try replace(
        e,
        Value,
        value,
        "expression",
        try variant(e, Expression, "variable", fresh),
    );
    return e.b.bind(ordinal, try e.call(d.parameter, &.{
        try field(e, Copy, state, "parameters"),
        try payload(e, Expression, expression, "variable"),
        e.zero,
    }), try copyNext(e, d, state, changed));
}

fn copiedPrimitive(e: Author, d: Definition, state: Id, value: Id, expression: Id) !Id {
    const primitive = try payload(e, Expression, expression, "primitive");
    const operands = try e.b.variable(try shape(e, []const Id));
    const changed = try replace(
        e,
        Value,
        value,
        "expression",
        try variant(
            e,
            Expression,
            "primitive",
            try replace(e, Primitive, primitive, "operands", try e.b.reference(operands)),
        ),
    );
    return e.b.bind(operands, try e.call(d.map_ids, &.{
        try field(e, Primitive, primitive, "operands"), try field(e, Copy, state, "mapping"),
        e.zero,                                         try e.literal([]const Id, &.{}),
    }), try copyNext(e, d, state, changed));
}

fn defineCopy(e: Author, d: Definition) !void {
    const state = try e.param(d.copy, 0);
    const cursor = try field(e, Copy, state, "cursor");
    const original = try field(e, Copy, state, "original");
    const value = try e.required(original, cursor);
    const expression = try field(e, Value, value, "expression");
    var visit = try e.fail();
    visit = try e.when(
        try tagged(e, Expression, expression, "literal"),
        try copyNext(e, d, state, value),
        visit,
    );
    visit = try e.when(
        try tagged(e, Expression, expression, "variable"),
        try copiedVariable(e, d, state, value, expression),
        visit,
    );
    visit = try e.when(
        try tagged(e, Expression, expression, "primitive"),
        try copiedPrimitive(e, d, state, value, expression),
        visit,
    );
    const active = try e.when(
        try e.required(try field(e, Copy, state, "selected"), cursor),
        visit,
        try copyNext(e, d, state, null),
    );
    try e.b.define(d.copy, try e.when(
        try e.binary(.less, cursor, try length(e, original)),
        active,
        try e.b.pure(state),
    ));
}

fn defineVariables(e: Author, d: Definition) !void {
    const variables = try e.param(d.variables, 0);
    const parameters = try e.param(d.variables, 1);
    const cursor = try e.param(d.variables, 2);
    const result = try e.param(d.variables, 3);
    const next = try e.call(d.variables, &.{
        variables,
        parameters,
        try e.binary(
            .integer_add,
            cursor,
            e.one,
        ),
        try append(e, result, try e.required(variables, try e.required(parameters, cursor))),
    });
    try e.b.define(d.variables, try e.when(
        try e.binary(.less, cursor, try length(e, parameters)),
        next,
        try e.b.pure(result),
    ));
}

fn definePrefix(e: Author, d: Definition) !void {
    const terms = try e.param(d.prefix, 0);
    const stop = try e.param(d.prefix, 1);
    const cursor = try e.param(d.prefix, 2);
    const result = try e.param(d.prefix, 3);
    const next = try e.call(d.prefix, &.{
        terms,                                                stop,
        try e.binary(
            .integer_add,
            cursor,
            e.one,
        ),
        try append(e, result, try e.required(terms, cursor)),
    });
    try e.b.define(d.prefix, try e.when(
        try e.binary(.less, cursor, stop),
        next,
        try e.b.pure(result),
    ));
}

fn defineArguments(e: Author, d: Definition) !void {
    const arguments = try e.param(d.arguments, 0);
    const cursor = try e.param(d.arguments, 1);
    const result = try e.param(d.arguments, 2);
    const next = try e.call(d.arguments, &.{
        arguments,
        try e.binary(
            .integer_add,
            cursor,
            e.one,
        ),
        try append(e, result, try variant(e, Term, "value", try e.required(arguments, cursor))),
    });
    try e.b.define(d.arguments, try e.when(
        try e.binary(.less, cursor, try length(e, arguments)),
        next,
        try e.b.pure(result),
    ));
}

fn defineBindings(e: Author, d: Definition) !void {
    const base = try e.param(d.bindings, 0);
    const call = try e.param(d.bindings, 1);
    const count = try e.param(d.bindings, 2);
    const remaining = try e.param(d.bindings, 3);
    const result = try e.param(d.bindings, 4);
    const cursor = try e.binary(.integer_sub, remaining, e.one);
    const next = try e.b.primitive(e.integer, .select, &.{
        try e.binary(.equal, count, remaining),                   call,
        try e.binary(.integer_sub, try length(e, result), e.one),
    }, 0);
    const binding = try e.tuple(try shape(e, @FieldType(Term, "bind")), &.{
        try e.binary(.integer_add, base, cursor),
        try e.binary(.integer_add, try e.binary(.integer_add, call, e.one), cursor),
        next,
    });
    const advance = try e.call(d.bindings, &.{
        base, call, count, cursor, try append(e, result, try variant(e, Term, "bind", binding)),
    });
    try e.b.define(d.bindings, try e.when(
        try e.binary(.less, e.zero, remaining),
        advance,
        try e.b.pure(result),
    ));
}

fn shifted(e: Author, id: Id, call: Id, next: Id, delta: Id) !Id {
    const after = try e.b.primitive(e.integer, .select, &.{
        try e.binary(.equal, id, call), next, try e.binary(.integer_add, id, delta),
    }, 0);
    return e.b.primitive(e.integer, .select, &.{ try e.binary(.less, id, call), id, after }, 0);
}

fn defineCases(e: Author, d: Definition) !void {
    const original = try e.param(d.cases, 0);
    const call = try e.param(d.cases, 1);
    const next = try e.param(d.cases, 2);
    const delta = try e.param(d.cases, 3);
    const cursor = try e.param(d.cases, 4);
    const result = try e.param(d.cases, 5);
    const value = try e.required(original, cursor);
    const changed = try replace(
        e,
        Case,
        value,
        "body",
        try shifted(e, try field(e, Case, value, "body"), call, next, delta),
    );
    const advance = try e.call(d.cases, &.{
        original,                       call, next, delta,
        try e.binary(
            .integer_add,
            cursor,
            e.one,
        ),
        try append(e, result, changed),
    });
    try e.b.define(d.cases, try e.when(
        try e.binary(.less, cursor, try length(e, original)),
        advance,
        try e.b.pure(result),
    ));
}

fn defineTerm(e: Author, d: Definition) !void {
    const original = try e.param(d.term, 0);
    const call = try e.param(d.term, 1);
    const next = try e.param(d.term, 2);
    const delta = try e.param(d.term, 3);
    var body = try e.b.pure(original);
    inline for (.{
        .{ "bind", .{ "value", "next" } },
        .{ "conditional", .{ "when_true", "when_false" } },
        .{ "unpack_product", .{"body"} },
    }) |case| {
        const T = @FieldType(Term, case[0]);
        const value = try payload(e, Term, original, case[0]);
        var changed = value;
        inline for (case[1]) |name| changed = try replace(
            e,
            T,
            changed,
            name,
            try shifted(e, try field(e, T, value, name), call, next, delta),
        );
        body = try e.when(
            try tagged(e, Term, original, case[0]),
            try e.b.pure(try variant(e, Term, case[0], changed)),
            body,
        );
    }
    const yielded = try shifted(e, try payload(e, Term, original, "yield_then"), call, next, delta);
    body = try e.when(
        try tagged(e, Term, original, "yield_then"),
        try e.b.pure(try variant(e, Term, "yield_then", yielded)),
        body,
    );
    const matched = try payload(e, Term, original, "match_sum");
    const cases = try e.b.variable(try shape(e, []const Case));
    const changed = try variant(
        e,
        Term,
        "match_sum",
        try replace(e, @FieldType(Term, "match_sum"), matched, "cases", try e.b.reference(cases)),
    );
    const mapped = try e.b.bind(cases, try e.call(d.cases, &.{
        try field(
            e,
            @FieldType(Term, "match_sum"),
            matched,
            "cases",
        ),
        call,
        next,
        delta,
        e.zero,
        try e.literal(
            []const Case,
            &.{},
        ),
    }), try e.b.pure(changed));
    body = try e.when(try tagged(e, Term, original, "match_sum"), mapped, body);
    try e.b.define(d.term, body);
}

fn defineTerms(e: Author, d: Definition) !void {
    const original = try e.param(d.terms, 0);
    const call = try e.param(d.terms, 1);
    const next = try e.param(d.terms, 2);
    const delta = try e.param(d.terms, 3);
    const cursor = try e.param(d.terms, 4);
    const result = try e.param(d.terms, 5);
    const mapped = try e.b.variable(try shape(e, Term));
    const advance = try e.b.bind(mapped, try e.call(d.term, &.{
        try e.required(original, cursor), call, next, delta,
    }), try e.call(d.terms, &.{
        original,                                         call, next, delta,
        try e.binary(
            .integer_add,
            cursor,
            e.one,
        ),
        try append(e, result, try e.b.reference(mapped)),
    }));
    try e.b.define(d.terms, try e.when(
        try e.binary(.less, cursor, try length(e, original)),
        advance,
        try e.b.pure(result),
    ));
}

fn defineFunctions(e: Author, d: Definition) !void {
    const original = try e.param(d.functions, 0);
    const call = try e.param(d.functions, 1);
    const next = try e.param(d.functions, 2);
    const delta = try e.param(d.functions, 3);
    const cursor = try e.param(d.functions, 4);
    const result = try e.param(d.functions, 5);
    const function = try e.required(original, cursor);
    const body = try field(e, Function, function, "body");
    const relocated = try e.variant(
        try shape(e, ?Id),
        1,
        try shifted(e, try e.payload(body, 1), call, next, delta),
    );
    const changed = try replace(e, Function, function, "body", relocated);
    const advance = try e.call(
        d.functions,
        &.{ original, call, next, delta, try e.binary(
            .integer_add,
            cursor,
            e.one,
        ), try append(e, result, changed) },
    );
    const unchanged = try e.call(
        d.functions,
        &.{ original, call, next, delta, try e.binary(
            .integer_add,
            cursor,
            e.one,
        ), try append(e, result, function) },
    );
    const tag = try e.b.primitive(e.integer, .variant_tag, &.{body}, 0);
    const visit = try e.when(try e.binary(.equal, tag, e.one), advance, unchanged);
    try e.b.define(d.functions, try e.when(
        try e.binary(.less, cursor, try length(e, original)),
        visit,
        try e.b.pure(result),
    ));
}

const Inline = struct {
    module: Id,
    call_id: Id,
    call: Id,
    parameters: Id,
    root: Id,
    values: Id,
    variables: Id,
    terms: Id,
    flags: Id,
    mapping: Id,
    copied: Id,
    new_variables: Id,
    prefix: Id,
    arguments: Id,
    bindings: Id,
    suffix: Id,
    functions: Id,
};

fn inlineBindings(e: Author, d: Definition) !Inline {
    const module = try e.param(d.inline_call, 0);
    const call_id = try e.param(d.inline_call, 1);
    const terms = try field(e, source.Module, module, "terms");
    const call = try payload(e, Term, try e.required(terms, call_id), "call");
    const function = try e.required(
        try field(e, source.Module, module, "functions"),
        try field(e, @FieldType(Term, "call"), call, "function"),
    );
    const body = try e.payload(try field(e, Function, function, "body"), 1);
    return .{
        .module = module,
        .call_id = call_id,
        .call = call,
        .parameters = try field(e, Function, function, "parameters"),
        .root = try payload(e, Term, try e.required(terms, body), "value"),
        .values = try field(e, source.Module, module, "values"),
        .variables = try field(e, source.Module, module, "variables"),
        .terms = terms,
        .flags = try e.b.variable(try shape(e, []const bool)),
        .mapping = try e.b.variable(try shape(e, []const Id)),
        .copied = try e.b.variable(try shape(e, Copy)),
        .new_variables = try e.b.variable(try shape(e, []const Id)),
        .prefix = try e.b.variable(try shape(e, []const Term)),
        .arguments = try e.b.variable(try shape(e, []const Term)),
        .bindings = try e.b.variable(try shape(e, []const Term)),
        .suffix = try e.b.variable(try shape(e, []const Term)),
        .functions = try e.b.variable(try shape(e, []const Function)),
    };
}

fn inlineResult(e: Author, state: Inline) !Id {
    var module = state.module;
    module = try replace(
        e,
        source.Module,
        module,
        "variables",
        try e.b.reference(state.new_variables),
    );
    module = try replace(
        e,
        source.Module,
        module,
        "values",
        try field(e, Copy, try e.b.reference(state.copied), "output"),
    );
    module = try replace(e, source.Module, module, "terms", try e.b.reference(state.suffix));
    module = try replace(e, source.Module, module, "functions", try e.b.reference(state.functions));
    return e.b.pure(module);
}

fn inlineTerms(e: Author, d: Definition, state: Inline, finish: Id) !Id {
    const count = try length(e, state.parameters);
    const delta = try e.binary(.integer_mul, count, try e.b.constant(u64, 2));
    const next = try e.binary(.integer_add, state.call_id, delta);
    var body = try e.b.bind(state.functions, try e.call(d.functions, &.{
        try field(
            e,
            source.Module,
            state.module,
            "functions",
        ),
        state.call_id,
        next,
        delta,
        e.zero,
        try e.literal(
            []const Function,
            &.{},
        ),
    }), finish);
    body = try e.b.bind(state.suffix, try e.call(d.terms, &.{
        state.terms,
        state.call_id,
        next,
        delta,
        try e.binary(.integer_add, state.call_id, e.one),
        try e.b.reference(state.bindings),
    }), body);
    body = try e.b.bind(state.bindings, try e.call(d.bindings, &.{
        try length(e, state.variables),     state.call_id, count, count,
        try e.b.reference(state.arguments),
    }), body);
    const mapped_root = try e.required(
        try field(e, Copy, try e.b.reference(state.copied), "mapping"),
        state.root,
    );
    body = try e.b.bind(state.arguments, try e.call(d.arguments, &.{
        try field(
            e,
            @FieldType(Term, "call"),
            state.call,
            "arguments",
        ),
        e.zero,
        try append(e, try e.b.reference(state.prefix), try variant(e, Term, "value", mapped_root)),
    }), body);
    return e.b.bind(state.prefix, try e.call(d.prefix, &.{
        state.terms, state.call_id, e.zero, try e.literal([]const Term, &.{}),
    }), body);
}

fn defineInline(e: Author, d: Definition) !void {
    const state = try inlineBindings(e, d);
    var body = try inlineTerms(e, d, state, try inlineResult(e, state));
    body = try e.b.bind(state.new_variables, try e.call(d.variables, &.{
        state.variables, state.parameters, e.zero, state.variables,
    }), body);
    const selected = try e.b.variable(try shape(e, []const bool));
    const copied = try e.tuple(try shape(e, Copy), &.{
        state.values, try e.b.reference(selected),      state.parameters,
        try length(
            e,
            state.variables,
        ),
        e.zero,       try e.b.reference(state.mapping), state.values,
    });
    body = try e.b.bind(state.copied, try e.call(d.copy, &.{copied}), body);
    body = try e.b.bind(selected, try e.call(d.select, &.{
        state.values,
        try set(
            e,
            try e.b.reference(state.flags),
            state.root,
            try e.b.constant(bool, true),
        ),
        try length(e, state.values),
    }), body);
    body = try e.b.bind(state.mapping, try e.call(d.fill_ids, &.{
        try length(e, state.values), try e.literal([]const Id, &.{}),
    }), body);
    body = try e.b.bind(state.flags, try e.call(d.fill_flags, &.{
        try length(e, state.values), try e.literal([]const bool, &.{}),
    }), body);
    try e.b.define(d.inline_call, body);
}

fn step(e: Author, module: Id, call: Id) !Id {
    return e.tuple(try shape(e, source.relation.RecordStep), &.{
        module, try variant(e, source.relation.RecordRule, "inline_call", call),
    });
}

fn defineUsesResult(e: Author, d: Definition) !void {
    const values = try e.param(d.uses_result, 0);
    const arguments = try e.param(d.uses_result, 1);
    const variable = try e.param(d.uses_result, 2);
    const cursor = try e.param(d.uses_result, 3);
    const count = try e.param(d.uses_result, 4);
    const value = try e.required(values, try e.required(arguments, cursor));
    const expression = try field(e, Value, value, "expression");
    const matches = try e.binary(
        .equal,
        try payload(e, Expression, expression, "variable"),
        variable,
    );
    const found = try e.b.primitive(e.integer, .select, &.{
        matches, try e.binary(.integer_add, count, e.one), count,
    }, 0);
    const next = try e.binary(.integer_add, cursor, e.one);
    const matched = try e.call(d.uses_result, &.{ values, arguments, variable, next, found });
    const literal = try e.call(d.uses_result, &.{ values, arguments, variable, next, count });
    const other = try e.when(
        try tagged(e, Expression, expression, "literal"),
        literal,
        try e.fail(),
    );
    const visit = try e.when(try tagged(e, Expression, expression, "variable"), matched, other);
    try e.b.define(d.uses_result, try e.when(
        try e.binary(.less, cursor, try length(e, arguments)),
        visit,
        try e.b.pure(try e.binary(.equal, count, e.one)),
    ));
}

fn requireConsumer(e: Author, d: Definition, module: Id, binding: Id, body: Id) !Id {
    const consumer = try field(e, @FieldType(Term, "bind"), binding, "next");
    const call = try payload(
        e,
        Term,
        try e.required(try field(e, source.Module, module, "terms"), consumer),
        "call",
    );
    const uses = try e.b.variable(e.boolean);
    return e.b.bind(uses, try e.call(d.uses_result, &.{
        try field(e, source.Module, module, "values"),
        try field(e, @FieldType(Term, "call"), call, "arguments"),
        try field(e, @FieldType(Term, "bind"), binding, "variable"),
        e.zero,
        e.zero,
    }), try e.when(try e.b.reference(uses), body, try e.fail()));
}

fn defineEntry(e: Author, d: Definition) !void {
    const input = try e.param(d.entry, 0);
    const module = try field(e, Input, input, "module");
    const site = try field(e, Input, input, "site");
    const terms = try field(e, source.Module, module, "terms");
    const binding = try payload(
        e,
        Term,
        try e.required(terms, try field(e, source.consumer.Site, site, "binding")),
        "bind",
    );
    const producer = try field(e, @FieldType(Term, "bind"), binding, "value");
    const consumer = try field(e, @FieldType(Term, "bind"), binding, "next");
    const ordered = try e.binary(.less, producer, consumer);
    const first = try e.b.primitive(e.integer, .select, &.{ ordered, consumer, producer }, 0);
    const second = try e.b.primitive(e.integer, .select, &.{ ordered, producer, consumer }, 0);
    const intermediate = try e.b.variable(try shape(e, source.Module));
    const result = try e.b.variable(try shape(e, source.Module));
    const steps = try e.b.primitive(try shape(e, []const source.relation.RecordStep), .sequence, &.{
        try step(e, try e.b.reference(intermediate), first),
        try step(e, try e.b.reference(result), second),
    }, 0);
    const proposal = try e.tuple(try shape(e, compiler.RecordProposal), &.{
        try e.b.reference(result),                                              steps,
        try e.literal(@FieldType(compiler.RecordProposal, "interfaces"), null),
    });
    var body = try e.b.bind(result, try e.call(d.inline_call, &.{
        try e.b.reference(intermediate), second,
    }), try e.b.pure(proposal));
    body = try e.b.bind(intermediate, try e.call(d.inline_call, &.{ module, first }), body);
    body = try requireConsumer(e, d, module, binding, body);
    const function = try e.required(
        try field(e, source.Module, module, "functions"),
        try field(e, source.consumer.Site, site, "function"),
    );
    const root = try e.payload(try field(e, Function, function, "body"), 1);
    const exact_site = try e.binary(
        .equal,
        root,
        try field(e, source.consumer.Site, site, "binding"),
    );
    try e.b.define(d.entry, try e.when(exact_site, body, try e.fail()));
}
