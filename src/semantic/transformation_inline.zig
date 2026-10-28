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
const References = struct { terms: []const Id, values: []const Id, bound: []const Id };
const Selection = struct {
    original_variables: []const Id,
    original_terms: []const Term,
    terms: []const bool,
    values: []const bool,
    variables: []const Id,
    output_variables: []const Id,
};
const Copy = struct {
    original: []const Value,
    selected: []const bool,
    variables: []const Id,
    cursor: Id,
    mapping: []const Id,
    output: []const Value,
};
const TermCopy = struct {
    original: []const Term,
    selected: []const bool,
    variables: []const Id,
    values: []const Id,
    cursor: Id,
    mapping: []const Id,
    output: []const Term,
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
    references: Id,
    case_references: Id,
    select_terms: Id,
    variable: Id,
    variables: Id,
    copy_term: Id,
    copy_terms: Id,
    copy_cases: Id,
    prefix: Id,
    arguments: Id,
    bindings: Id,
    terms: Id,
    term: Id,
    cases: Id,
    functions: Id,
};

pub fn define(b: *source.Builder) !source.Module {
    const e = try Author.init(b);
    const d = try definitions(e);
    try defineFill(e, d.fill_flags, bool);
    try defineFill(e, d.fill_ids, Id);
    try defineMark(e, d);
    try defineSelect(e, d);
    try defineMapIds(e, d);
    try defineReferences(e, d);
    try defineCaseReferences(e, d);
    try defineSelectTerms(e, d);
    try defineVariable(e, d);
    try defineCopy(e, d);
    try defineVariables(e, d);
    try defineCopyTerm(e, d);
    try defineCopyTerms(e, d);
    try defineCopyCases(e, d);
    try definePrefix(e, d);
    try defineArguments(e, d);
    try defineBindings(e, d);
    try defineCases(e, d);
    try defineTerm(e, d);
    try defineTerms(e, d);
    try defineFunctions(e, d);
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
        .references = try declare(e, &.{try shape(e, Term)}, References),
        .case_references = try declare(
            e,
            &.{ cases, e.integer, try shape(e, References) },
            References,
        ),
        .select_terms = try declare(e, &.{ try shape(e, Selection), e.integer }, Selection),
        .variable = try declare(e, &.{ try shape(e, Selection), e.integer }, Selection),
        .variables = try declare(e, &.{ try shape(e, Selection), ids, e.integer }, Selection),
        .copy_term = try declare(e, &.{ try shape(e, Term), ids, ids, ids }, Term),
        .copy_terms = try declare(e, &.{try shape(e, TermCopy)}, TermCopy),
        .copy_cases = try declare(e, &.{ cases, ids, ids, e.integer, cases }, []const Case),
        .prefix = try declare(e, &.{ terms, e.integer, e.integer, terms }, []const Term),
        .arguments = try declare(e, &.{ ids, e.integer, terms }, []const Term),
        .bindings = try declare(
            e,
            &.{ ids, ids, e.integer, e.integer, e.integer, terms },
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
    const zero = if (T == bool)
        try e.b.constant(bool, false)
    else
        try e.b.constant(Id, std.math.maxInt(Id));
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

fn idSequence(e: Author, values: []const Id) !Id {
    return e.b.primitive(try shape(e, []const Id), .sequence, values, 0);
}

fn references(e: Author, terms: Id, values: Id, bound: Id) !Id {
    return e.tuple(try shape(e, References), &.{ terms, values, bound });
}

fn defineReferences(e: Author, d: Definition) !void {
    const original = try e.param(d.references, 0);
    const empty = try idSequence(e, &.{});
    var body = try e.fail();
    inline for (.{ "value", "fail", "yield_then" }) |name| {
        const child = try idSequence(e, &.{try payload(e, Term, original, name)});
        const result = if (comptime std.mem.eql(u8, name, "yield_then"))
            try references(e, child, empty, empty)
        else
            try references(e, empty, child, empty);
        body = try e.when(try tagged(e, Term, original, name), try e.b.pure(result), body);
    }
    inline for (.{ "bind", "conditional", "call", "unpack_product" }) |name| {
        const T = @FieldType(Term, name);
        const item = try payload(e, Term, original, name);
        const refs = if (comptime std.mem.eql(u8, name, "bind"))
            try references(e, try idSequence(e, &.{
                try field(e, T, item, "value"), try field(e, T, item, "next"),
            }), empty, try idSequence(e, &.{try field(e, T, item, "variable")}))
        else if (comptime std.mem.eql(u8, name, "conditional"))
            try references(e, try idSequence(e, &.{
                try field(e, T, item, "when_true"), try field(e, T, item, "when_false"),
            }), try idSequence(e, &.{try field(e, T, item, "condition")}), empty)
        else if (comptime std.mem.eql(u8, name, "call"))
            try references(e, empty, try field(e, T, item, "arguments"), empty)
        else
            try references(
                e,
                try idSequence(e, &.{try field(e, T, item, "body")}),
                try idSequence(e, &.{try field(e, T, item, "value")}),
                try field(e, T, item, "variables"),
            );
        body = try e.when(try tagged(e, Term, original, name), try e.b.pure(refs), body);
    }
    const matched = try payload(e, Term, original, "match_sum");
    const T = @FieldType(Term, "match_sum");
    const matched_refs = try e.call(d.case_references, &.{
        try field(e, T, matched, "cases"),
        e.zero,
        try references(e, empty, try idSequence(e, &.{try field(e, T, matched, "value")}), empty),
    });
    body = try e.when(try tagged(e, Term, original, "match_sum"), matched_refs, body);
    try e.b.define(d.references, body);
}

fn defineCaseReferences(e: Author, d: Definition) !void {
    const cases = try e.param(d.case_references, 0);
    const cursor = try e.param(d.case_references, 1);
    const result = try e.param(d.case_references, 2);
    const item = try e.required(cases, cursor);
    const next = try references(
        e,
        try append(e, try field(e, References, result, "terms"), try field(e, Case, item, "body")),
        try field(e, References, result, "values"),
        try append(
            e,
            try field(e, References, result, "bound"),
            try field(e, Case, item, "variable"),
        ),
    );
    try e.b.define(d.case_references, try e.when(
        try e.binary(.less, cursor, try length(e, cases)),
        try e.call(d.case_references, &.{
            cases, try e.binary(.integer_add, cursor, e.one), next,
        }),
        try e.b.pure(result),
    ));
}

fn defineVariable(e: Author, d: Definition) !void {
    const state = try e.param(d.variable, 0);
    const variable = try e.param(d.variable, 1);
    const mapping = try field(e, Selection, state, "variables");
    const output = try field(e, Selection, state, "output_variables");
    var changed = try replace(
        e,
        Selection,
        state,
        "variables",
        try set(e, mapping, variable, try length(e, output)),
    );
    changed = try replace(
        e,
        Selection,
        changed,
        "output_variables",
        try append(
            e,
            output,
            try e.required(try field(e, Selection, state, "original_variables"), variable),
        ),
    );
    try e.b.define(d.variable, try e.when(
        try e.binary(
            .equal,
            try e.required(mapping, variable),
            try e.b.constant(Id, std.math.maxInt(Id)),
        ),
        try e.b.pure(changed),
        try e.b.pure(state),
    ));
}

fn defineSelectTerms(e: Author, d: Definition) !void {
    const state = try e.param(d.select_terms, 0);
    const remaining = try e.param(d.select_terms, 1);
    const cursor = try e.binary(.integer_sub, remaining, e.one);
    const refs = try e.b.variable(try shape(e, References));
    const term_flags = try e.b.variable(try shape(e, []const bool));
    const value_flags = try e.b.variable(try shape(e, []const bool));
    const bound = try e.b.variable(try shape(e, Selection));
    const advance = try e.call(d.select_terms, &.{ state, cursor });
    var selected = try replace(e, Selection, state, "terms", try e.b.reference(term_flags));
    selected = try replace(e, Selection, selected, "values", try e.b.reference(value_flags));
    var visit = try e.b.bind(bound, try e.call(d.variables, &.{
        selected, try field(e, References, try e.b.reference(refs), "bound"), e.zero,
    }), try e.call(d.select_terms, &.{ try e.b.reference(bound), cursor }));
    visit = try e.b.bind(value_flags, try e.call(d.mark, &.{
        try field(e, Selection, state, "values"),
        try field(e, References, try e.b.reference(refs), "values"),
        e.zero,
    }), visit);
    visit = try e.b.bind(term_flags, try e.call(d.mark, &.{
        try field(e, Selection, state, "terms"),
        try field(e, References, try e.b.reference(refs), "terms"),
        e.zero,
    }), visit);
    visit = try e.b.bind(refs, try e.call(d.references, &.{
        try e.required(try field(e, Selection, state, "original_terms"), cursor),
    }), visit);
    try e.b.define(d.select_terms, try e.when(
        try e.binary(.less, e.zero, remaining),
        try e.when(try e.required(try field(e, Selection, state, "terms"), cursor), visit, advance),
        try e.b.pure(state),
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
    const fresh = try e.required(
        try field(e, Copy, state, "variables"),
        try payload(e, Expression, expression, "variable"),
    );
    const changed = try replace(
        e,
        Value,
        value,
        "expression",
        try variant(e, Expression, "variable", fresh),
    );
    return copyNext(e, d, state, changed);
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
    const state = try e.param(d.variables, 0);
    const variables = try e.param(d.variables, 1);
    const cursor = try e.param(d.variables, 2);
    const changed = try e.b.variable(try shape(e, Selection));
    const next = try e.b.bind(changed, try e.call(d.variable, &.{
        state, try e.required(variables, cursor),
    }), try e.call(d.variables, &.{
        try e.b.reference(changed), variables, try e.binary(.integer_add, cursor, e.one),
    }));
    try e.b.define(d.variables, try e.when(
        try e.binary(.less, cursor, try length(e, variables)),
        next,
        try e.b.pure(state),
    ));
}

fn remapFields(
    e: Author,
    comptime T: type,
    original: Id,
    comptime names: anytype,
    mapping: Id,
) !Id {
    var result = original;
    inline for (names) |name| result = try replace(
        e,
        T,
        result,
        name,
        try e.required(mapping, try field(e, T, original, name)),
    );
    return result;
}

const CopyMaps = struct { variables: Id, values: Id, terms: Id };

fn defineCopyTerm(e: Author, d: Definition) !void {
    const original = try e.param(d.copy_term, 0);
    const maps: CopyMaps = .{
        .variables = try e.param(d.copy_term, 1),
        .values = try e.param(d.copy_term, 2),
        .terms = try e.param(d.copy_term, 3),
    };
    var body = try e.fail();
    inline for (.{ "value", "fail", "yield_then" }) |name| {
        const mapping = if (comptime std.mem.eql(u8, name, "yield_then"))
            maps.terms
        else
            maps.values;
        const changed = try variant(
            e,
            Term,
            name,
            try e.required(mapping, try payload(e, Term, original, name)),
        );
        body = try e.when(try tagged(e, Term, original, name), try e.b.pure(changed), body);
    }
    inline for (.{ "bind", "conditional" }) |name| {
        const T = @FieldType(Term, name);
        const item = try payload(e, Term, original, name);
        const children = if (comptime std.mem.eql(u8, name, "bind"))
            .{ "value", "next" }
        else
            .{ "when_true", "when_false" };
        var changed = try remapFields(e, T, item, children, maps.terms);
        changed = if (comptime std.mem.eql(u8, name, "bind"))
            try remapFields(e, T, changed, .{"variable"}, maps.variables)
        else
            try remapFields(e, T, changed, .{"condition"}, maps.values);
        body = try e.when(
            try tagged(e, Term, original, name),
            try e.b.pure(try variant(e, Term, name, changed)),
            body,
        );
    }
    inline for (.{ "call", "unpack_product", "match_sum" }) |name| {
        const copied = try copyTermList(e, d, original, maps, name);
        body = try e.when(try tagged(e, Term, original, name), copied, body);
    }
    try e.b.define(d.copy_term, body);
}

fn copyTermList(
    e: Author,
    d: Definition,
    original: Id,
    maps: CopyMaps,
    comptime name: []const u8,
) !Id {
    const T = @FieldType(Term, name);
    const item = try payload(e, Term, original, name);
    const matched = comptime std.mem.eql(u8, name, "match_sum");
    const called = comptime std.mem.eql(u8, name, "call");
    const member = if (matched) "cases" else if (called) "arguments" else "variables";
    const List = if (matched) []const Case else []const Id;
    const mapped = try e.b.variable(try shape(e, List));
    var changed = try replace(e, T, item, member, try e.b.reference(mapped));
    if (!called) changed = try remapFields(e, T, changed, .{"value"}, maps.values);
    if (!matched and !called)
        changed = try remapFields(e, T, changed, .{"body"}, maps.terms);
    const mapping = if (matched)
        try e.call(d.copy_cases, &.{
            try field(e, T, item, member), maps.variables,            maps.terms,
            e.zero,                        try e.literal(List, &.{}),
        })
    else
        try e.call(d.map_ids, &.{
            try field(e, T, item, member), if (called) maps.values else maps.variables,
            e.zero,                        try e.literal(List, &.{}),
        });
    return e.b.bind(mapped, mapping, try e.b.pure(try variant(e, Term, name, changed)));
}

fn defineCopyCases(e: Author, d: Definition) !void {
    const original = try e.param(d.copy_cases, 0);
    const variables = try e.param(d.copy_cases, 1);
    const terms = try e.param(d.copy_cases, 2);
    const cursor = try e.param(d.copy_cases, 3);
    const result = try e.param(d.copy_cases, 4);
    const item = try e.required(original, cursor);
    var changed = try remapFields(e, Case, item, .{"variable"}, variables);
    changed = try remapFields(e, Case, changed, .{"body"}, terms);
    const next = try e.call(d.copy_cases, &.{
        original,                       variables, terms, try e.binary(.integer_add, cursor, e.one),
        try append(e, result, changed),
    });
    try e.b.define(d.copy_cases, try e.when(
        try e.binary(.less, cursor, try length(e, original)),
        next,
        try e.b.pure(result),
    ));
}

fn termCopyNext(e: Author, d: Definition, state: Id, replacement: ?Id) !Id {
    const cursor = try field(e, TermCopy, state, "cursor");
    var next = try replace(e, TermCopy, state, "cursor", try e.binary(.integer_add, cursor, e.one));
    if (replacement) |term| {
        const output = try field(e, TermCopy, state, "output");
        next = try replace(
            e,
            TermCopy,
            next,
            "mapping",
            try set(e, try field(e, TermCopy, state, "mapping"), cursor, try length(e, output)),
        );
        next = try replace(e, TermCopy, next, "output", try append(e, output, term));
    }
    return e.call(d.copy_terms, &.{next});
}

fn defineCopyTerms(e: Author, d: Definition) !void {
    const state = try e.param(d.copy_terms, 0);
    const cursor = try field(e, TermCopy, state, "cursor");
    const original = try field(e, TermCopy, state, "original");
    const copied = try e.b.variable(try shape(e, Term));
    const visit = try e.b.bind(copied, try e.call(d.copy_term, &.{
        try e.required(original, cursor),
        try field(e, TermCopy, state, "variables"),
        try field(e, TermCopy, state, "values"),
        try field(e, TermCopy, state, "mapping"),
    }), try termCopyNext(e, d, state, try e.b.reference(copied)));
    try e.b.define(d.copy_terms, try e.when(
        try e.binary(.less, cursor, try length(e, original)),
        try e.when(
            try e.required(try field(e, TermCopy, state, "selected"), cursor),
            visit,
            try termCopyNext(e, d, state, null),
        ),
        try e.b.pure(state),
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
    const parameters = try e.param(d.bindings, 0);
    const variables = try e.param(d.bindings, 1);
    const arguments_start = try e.param(d.bindings, 2);
    const remaining = try e.param(d.bindings, 3);
    const next = try e.param(d.bindings, 4);
    const result = try e.param(d.bindings, 5);
    const cursor = try e.binary(.integer_sub, remaining, e.one);
    const binding = try e.tuple(try shape(e, @FieldType(Term, "bind")), &.{
        try e.required(variables, try e.required(parameters, cursor)),
        try e.binary(.integer_add, arguments_start, cursor),
        next,
    });
    const advance = try e.call(d.bindings, &.{
        parameters,
        variables,
        arguments_start,
        cursor,
        try length(e, result),
        try append(e, result, try variant(e, Term, "bind", binding)),
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
    term_flags: Id,
    variable_mapping: Id,
    mapping: Id,
    term_mapping: Id,
    parameters_bound: Id,
    selected: Id,
    copied: Id,
    copied_terms: Id,
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
        .root = body,
        .values = try field(e, source.Module, module, "values"),
        .variables = try field(e, source.Module, module, "variables"),
        .terms = terms,
        .flags = try e.b.variable(try shape(e, []const bool)),
        .term_flags = try e.b.variable(try shape(e, []const bool)),
        .variable_mapping = try e.b.variable(try shape(e, []const Id)),
        .mapping = try e.b.variable(try shape(e, []const Id)),
        .term_mapping = try e.b.variable(try shape(e, []const Id)),
        .parameters_bound = try e.b.variable(try shape(e, Selection)),
        .selected = try e.b.variable(try shape(e, Selection)),
        .copied = try e.b.variable(try shape(e, Copy)),
        .copied_terms = try e.b.variable(try shape(e, TermCopy)),
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
        try field(e, Selection, try e.b.reference(state.selected), "output_variables"),
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
    const copied = try e.b.reference(state.copied_terms);
    const copied_output = try field(e, TermCopy, copied, "output");
    const root = try e.required(try field(e, TermCopy, copied, "mapping"), state.root);
    const bound_count = try length(e, try e.b.reference(state.bindings));
    const delta = try e.binary(
        .integer_sub,
        try e.binary(.integer_sub, bound_count, state.call_id),
        e.one,
    );
    const next = try e.b.primitive(e.integer, .select, &.{
        try e.binary(.equal, count, e.zero),            root,
        try e.binary(.integer_sub, bound_count, e.one),
    }, 0);
    var body = try e.b.bind(state.functions, try e.call(d.functions, &.{
        try field(e, source.Module, state.module, "functions"),
        state.call_id,
        next,
        delta,
        e.zero,
        try e.literal([]const Function, &.{}),
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
        state.parameters,
        try field(e, Selection, try e.b.reference(state.selected), "variables"),
        try length(e, copied_output),
        count,
        root,
        try e.b.reference(state.arguments),
    }), body);
    body = try e.b.bind(state.arguments, try e.call(d.arguments, &.{
        try field(e, @FieldType(Term, "call"), state.call, "arguments"), e.zero, copied_output,
    }), body);
    return body;
}

fn inlineCopies(e: Author, d: Definition, state: Inline, finish: Id) !Id {
    const selection = try e.b.reference(state.selected);
    const term_copy = try e.tuple(try shape(e, TermCopy), &.{
        state.terms,
        try field(e, Selection, selection, "terms"),
        try field(e, Selection, selection, "variables"),
        try field(e, Copy, try e.b.reference(state.copied), "mapping"),
        e.zero,
        try e.b.reference(state.term_mapping),
        try e.b.reference(state.prefix),
    });
    var body = try e.b.bind(state.copied_terms, try e.call(d.copy_terms, &.{term_copy}), finish);
    body = try e.b.bind(state.prefix, try e.call(d.prefix, &.{
        state.terms, state.call_id, e.zero, try e.literal([]const Term, &.{}),
    }), body);
    const selected = try e.b.variable(try shape(e, []const bool));
    const copied = try e.tuple(try shape(e, Copy), &.{
        state.values,                                    try e.b.reference(selected),
        try field(e, Selection, selection, "variables"), e.zero,
        try e.b.reference(state.mapping),                state.values,
    });
    body = try e.b.bind(state.copied, try e.call(d.copy, &.{copied}), body);
    body = try e.b.bind(selected, try e.call(d.select, &.{
        state.values,                try field(e, Selection, selection, "values"),
        try length(e, state.values),
    }), body);
    body = try e.b.bind(state.term_mapping, try e.call(d.fill_ids, &.{
        try length(e, state.terms), try e.literal([]const Id, &.{}),
    }), body);
    body = try e.b.bind(state.mapping, try e.call(d.fill_ids, &.{
        try length(e, state.values), try e.literal([]const Id, &.{}),
    }), body);
    return body;
}

fn defineInline(e: Author, d: Definition) !void {
    const state = try inlineBindings(e, d);
    var body = try inlineTerms(e, d, state, try inlineResult(e, state));
    body = try inlineCopies(e, d, state, body);
    body = try e.b.bind(state.selected, try e.call(d.select_terms, &.{
        try e.b.reference(state.parameters_bound), try length(e, state.terms),
    }), body);
    const initial = try e.tuple(try shape(e, Selection), &.{
        state.variables,
        state.terms,
        try set(e, try e.b.reference(state.term_flags), state.root, try e.b.constant(bool, true)),
        try e.b.reference(state.flags),
        try e.b.reference(state.variable_mapping),
        state.variables,
    });
    body = try e.b.bind(state.parameters_bound, try e.call(d.variables, &.{
        initial, state.parameters, e.zero,
    }), body);
    body = try e.b.bind(state.variable_mapping, try e.call(d.fill_ids, &.{
        try length(e, state.variables), try e.literal([]const Id, &.{}),
    }), body);
    body = try e.b.bind(state.term_flags, try e.call(d.fill_flags, &.{
        try length(e, state.terms), try e.literal([]const bool, &.{}),
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
    const shared_steps = try e.b.primitive(
        try shape(e, []const source.relation.RecordStep),
        .sequence,
        &.{try step(e, try e.b.reference(intermediate), first)},
        0,
    );
    const shared_proposal = try e.tuple(try shape(e, compiler.RecordProposal), &.{
        try e.b.reference(intermediate),                                        shared_steps,
        try e.literal(@FieldType(compiler.RecordProposal, "interfaces"), null),
    });
    body = try e.when(try e.binary(.equal, first, second), try e.b.pure(shared_proposal), body);
    body = try e.b.bind(intermediate, try e.call(d.inline_call, &.{ module, first }), body);
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
