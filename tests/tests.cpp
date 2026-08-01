#include "abla/ast.hpp"
#include "abla/backend_c.hpp"
#include "abla/diagnostic.hpp"
#include "abla/ir.hpp"
#include "abla/lexer.hpp"
#include "abla/module.hpp"
#include "abla/parser.hpp"
#include "abla/sema.hpp"
#include "abla/source.hpp"
#include "abla/subparser.hpp"
#include "abla/token.hpp"
#include "abla/types.hpp"
#include "abla/vm.hpp"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, std::string_view message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

struct FrontendResult {
    abla::SourceFile source;
    abla::Diagnostics diagnostics;
    std::vector<abla::Token> tokens;
    std::unique_ptr<abla::ast::Program> program;

    FrontendResult(std::string name, std::string text)
        : source(std::move(name), std::move(text)) {
        tokens = abla::Lexer(source, diagnostics).tokenize();
        program = abla::Parser(source, tokens, diagnostics).parse();
    }
};

void test_source_locations() {
    const abla::SourceFile source("memory.ab", "one\nsecond\r\nthree");
    const auto location = source.location(4);
    check(location.line == 2, "source line is one-based");
    check(location.column == 1, "source column is one-based");
    check(source.line(2) == "second", "CRLF is stripped from displayed line");
}

void test_lexer_nested_comments_and_semicolons() {
    abla::SourceFile source(
        "lexer.ab",
        "val a=0x2a\n/* outer\n/* inner */\n*/ val b = 1;");
    abla::Diagnostics diagnostics;
    const auto tokens = abla::Lexer(source, diagnostics).tokenize();
    check(!diagnostics.has_errors(), "nested block comments lex cleanly");
    check(
        tokens[3].kind == abla::TokenKind::HexInteger,
        "hex literal has a distinct token");
    bool saw_newline = false;
    bool saw_semicolon = false;
    for (const auto token : tokens) {
        saw_newline = saw_newline || token.kind == abla::TokenKind::Newline;
        saw_semicolon = saw_semicolon || token.kind == abla::TokenKind::Semicolon;
    }
    check(saw_newline, "newlines remain visible to parser");
    check(saw_semicolon, "explicit semicolons remain accepted");
}

void test_string_interpolation() {
    abla::SourceFile source(
        "strings.ab",
        R"(val message = "hello $name: ${value + 1}")");
    abla::Diagnostics diagnostics;
    const auto tokens = abla::Lexer(source, diagnostics).tokenize();
    check(!diagnostics.has_errors(), "string interpolation lexes cleanly");
    bool identifier_part = false;
    bool expression_part = false;
    bool interpolation_end = false;
    for (const auto token : tokens) {
        identifier_part = identifier_part ||
            token.kind == abla::TokenKind::InterpolationIdentifier;
        expression_part = expression_part ||
            token.kind == abla::TokenKind::InterpolationStart;
        interpolation_end = interpolation_end ||
            token.kind == abla::TokenKind::InterpolationEnd;
    }
    check(identifier_part, "short string interpolation tokenized");
    check(expression_part && interpolation_end, "expression interpolation is balanced");
}

void test_parser_compatible_surface() {
    FrontendResult result(
        "compat.ab",
        R"(
extern:"c" fun printf(format: string): int
fun max(a: int, b: int): int = if (a > b) a else b
fun consume(own handle: Handle): int = handle.id
fun mutate(var handle: Handle): int = handle.id
fun invoke(callback: (var: Handle) -> int, var handle: Handle): int = callback(handle)
class Counter(var value: int) {
    fun increment(by: int = 1): int {
        value = value + by
        value
    }
}
resource class Handle(val id: int)
compile fun generate<T>(input: T?) {
    #printf("type")
}
fun main {
    val xs: array<int> = [1, 2, 3]
    var i = 0
    while (i < 3) {
        i = i + 1
    }
    when (xs[0]) {
        1, 2 -> max(xs[0], 2)
        else -> 0
    }
}
)");
    if (result.diagnostics.has_errors()) {
        result.diagnostics.render(std::cerr, result.source);
    }
    check(!result.diagnostics.has_errors(), "prototype-compatible surface parses");
    check(result.program->declarations.size() == 9, "all top-level declarations retained");
    check(
        result.program->declarations[5]->kind == abla::ast::Statement::Kind::Class,
        "class declaration represented explicitly");
    const auto* handle = dynamic_cast<const abla::ast::ClassDeclaration*>(
        result.program->declarations[6].get());
    check(handle != nullptr, "resource declaration remains a class");
    check(
        handle != nullptr &&
            std::find(
                handle->modifiers.values.begin(),
                handle->modifiers.values.end(),
                abla::ast::Modifier::Resource
            ) != handle->modifiers.values.end(),
        "resource modifier is preserved");
    const auto* consume = dynamic_cast<const abla::ast::FunctionDeclaration*>(
        result.program->declarations[2].get());
    check(
        consume != nullptr && !consume->parameters.empty() &&
            std::find(
                consume->parameters[0].modifiers.values.begin(),
                consume->parameters[0].modifiers.values.end(),
                abla::ast::Modifier::Own
            ) != consume->parameters[0].modifiers.values.end(),
        "owned parameter modifier is preserved");
    const auto* mutate = dynamic_cast<const abla::ast::FunctionDeclaration*>(
        result.program->declarations[3].get());
    check(
        mutate != nullptr && !mutate->parameters.empty() &&
            std::find(
                mutate->parameters[0].modifiers.values.begin(),
                mutate->parameters[0].modifiers.values.end(),
                abla::ast::Modifier::MutableBorrow
            ) != mutate->parameters[0].modifiers.values.end(),
        "mutable-borrow parameter modifier is preserved");
    const auto* invoke = dynamic_cast<const abla::ast::FunctionDeclaration*>(
        result.program->declarations[4].get());
    check(
        invoke != nullptr && !invoke->parameters.empty() &&
            invoke->parameters[0].type.parameter_modes.size() == 1 &&
            invoke->parameters[0].type.parameter_modes[0] ==
                abla::ast::ParameterMode::MutableBorrow,
        "mutable-borrow callable mode is preserved");
}

void test_optional_semicolons() {
    FrontendResult newline_form(
        "newlines.ab",
        "fun main {\nval a = 1\nval b = 2\na + b\n}\n");
    FrontendResult semicolon_form(
        "semicolons.ab",
        "fun main { val a = 1; val b = 2; a + b; }");
    check(!newline_form.diagnostics.has_errors(), "newline-separated statements parse");
    check(!semicolon_form.diagnostics.has_errors(), "semicolon-separated statements parse");
}

void test_diagnostics() {
    FrontendResult result("bad.ab", "fun broken(a int) { \"unterminated\n }");
    check(result.diagnostics.has_errors(), "invalid source produces diagnostics");
    check(result.diagnostics.error_count() >= 2, "lexer and parser errors accumulate");

    FrontendResult joined("joined.ab", "fun main { val a = 1 val b = 2 }");
    check(
        joined.diagnostics.has_errors(),
        "same-line statements require an explicit semicolon");

    abla::SourceFile number_source("numbers.ab", "val bad = 1__2");
    abla::Diagnostics number_diagnostics;
    static_cast<void>(abla::Lexer(number_source, number_diagnostics).tokenize());
    check(
        number_diagnostics.has_errors(),
        "numeric separators are accepted only between digits");

    FrontendResult invalid_token("invalid.ab", "fun main { % }");
    check(
        invalid_token.diagnostics.has_errors(),
        "invalid raw bytes remain diagnostics outside a subparser payload");
}

void test_module_graph_and_resolution() {
    abla::ModuleGraph graph;
    auto& entry = graph.load_entry("tests/cases/modules/main.ab");
    check(!graph.has_errors(), "constant imports load without diagnostics");
    check(graph.modules().size() == 2, "canonical module cache deduplicates imports");
    check(entry.imports.size() == 2, "both source import edges are retained");
    check(
        entry.imports[0].target == entry.imports[1].target,
        "duplicate imports point to one module instance");

    auto model = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, model).check();
    static_cast<void>(typed);
    if (graph.has_errors()) {
        graph.render_diagnostics(std::cerr);
    }
    check(!graph.has_errors(), "imported declarations resolve in entry module");
}

void test_resolution_diagnostics() {
    abla::ModuleGraph invalid;
    static_cast<void>(invalid.load_entry("tests/cases/modules/resolution-error.ab"));
    check(!invalid.has_errors(), "resolution fixture parses before semantic analysis");
    auto model = abla::sema::Resolver(invalid).resolve();
    static_cast<void>(model);
    check(invalid.has_errors(), "unknown and duplicate local names are diagnosed");
    check(invalid.error_count() == 2, "resolution reports both independent errors");

    abla::ModuleGraph cycle;
    static_cast<void>(cycle.load_entry("tests/cases/modules/cycle-a.ab"));
    check(cycle.has_errors(), "module import cycles are diagnosed");
}

void test_type_diagnostics() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/types-error.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    check(!graph.has_errors(), "type-error fixture resolves before type checking");
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    static_cast<void>(typed);
    check(graph.has_errors(), "invalid assignments, calls, and conditions are rejected");
    check(graph.error_count() >= 4, "type checker accumulates independent diagnostics");
}

void test_valid_semantic_types() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/types-valid.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    if (graph.has_errors()) graph.render_diagnostics(std::cerr);
    check(!graph.has_errors(), "nullable, array, and function types check successfully");

    const abla::sema::Symbol* apply = nullptr;
    for (const auto& symbol : semantics.symbols()) {
        if (symbol->name == "apply" && symbol->declaration != nullptr) {
            apply = symbol.get();
            break;
        }
    }
    check(apply != nullptr, "typed fixture exposes apply symbol");
    if (apply != nullptr) {
        const auto& function = typed.types.get(typed.symbol_type(*apply));
        check(
            function.kind == abla::sema::TypeKind::Function,
            "function declaration has canonical function type");
        check(
            function.result == typed.types.int_type(),
            "function result resolves to canonical int/i64 type");
    }
}

void test_ir_lowering_and_verification() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/types-valid.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    check(!graph.has_errors(), "valid typed program lowers without diagnostics");
    const auto verified = abla::ir::Verifier(
        typed.types, graph.entry()->diagnostics).verify(program);
    if (graph.has_errors()) graph.render_diagnostics(std::cerr);
    check(verified && !graph.has_errors(), "lowered IR satisfies verifier invariants");
    check(program.functions.size() == 4, "declared functions and lambda are lowered");

    std::ostringstream output;
    abla::ir::print(output, program, typed.types);
    const auto printed = output.str();
    check(printed.find("call.indirect") != std::string::npos, "IR retains indirect calls");
    check(printed.find("block ^") != std::string::npos, "IR prints explicit control flow");
    check(printed.find("array.create") != std::string::npos, "IR lowers array creation");
}

void test_vm_execution() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/vm.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    check(
        abla::ir::Verifier(typed.types, graph.entry()->diagnostics).verify(program),
        "recursive/loop VM fixture produces verified IR");
    abla::vm::Machine machine(program, typed.types, graph.entry()->diagnostics);
    const auto main = machine.find_function("main");
    check(main.has_value(), "VM locates entry function deterministically");
    if (main) {
        const auto result = machine.run(*main);
        check(!graph.has_errors(), "VM executes recursion and loop without errors");
        check(result.as_integer() == 135, "VM returns expected recursive/loop result");
        check(machine.instructions_executed() > 20, "VM accounts executed instructions");
    }
}

void test_registered_native_execution() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/native.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    abla::vm::NativeRegistry natives;
    natives.add("test", "nativeAdd", [](const std::vector<abla::vm::Value>& arguments) {
        return abla::vm::Value::integer(
            arguments[0].as_integer() + arguments[1].as_integer());
    });
    abla::vm::Machine machine(
        program, typed.types, graph.entry()->diagnostics, &natives);
    const auto main = machine.find_function("main");
    check(main.has_value(), "native fixture has main function");
    if (main) {
        const auto result = machine.run(*main);
        if (graph.has_errors()) graph.render_diagnostics(std::cerr);
        check(!graph.has_errors(), "registered native function executes through VM");
        check(result.as_integer() == 42, "native function result crosses VM boundary");
    }
}

void test_compile_time_materialization() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/compile-time.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    check(program.compile_actions.size() == 2, "two # expressions become compile actions");
    abla::vm::Machine machine(program, typed.types, graph.entry()->diagnostics);
    check(
        abla::vm::materialize_compile_actions(
            program, machine, graph.entry()->diagnostics),
        "compile actions execute in shared IR VM");
    check(program.compile_actions.empty(), "compile actions are consumed before runtime");
    check(
        abla::ir::Verifier(typed.types, graph.entry()->diagnostics).verify(program),
        "materialized runtime IR remains verified");
    const auto main = machine.find_function("main");
    check(main.has_value(), "compile-time fixture has main function");
    if (main) {
        const auto result = machine.run(*main);
        if (graph.has_errors()) graph.render_diagnostics(std::cerr);
        check(!graph.has_errors(), "materialized program executes without phase errors");
        check(result.as_integer() == 40, "# values are embedded before runtime execution");
    }
}

void test_compound_compile_time_materialization() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/compile-compound.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    abla::vm::Machine machine(program, typed.types, graph.entry()->diagnostics);
    check(
        abla::vm::materialize_compile_actions(
            program, machine, graph.entry()->diagnostics),
        "compound compile actions freeze into runtime-independent constants");
    check(program.compile_actions.empty(), "compound compile actions are consumed");
    check(program.constants.size() == 7, "array and object snapshots have deterministic nodes");
    check(
        abla::ir::Verifier(typed.types, graph.entry()->diagnostics).verify(program),
        "frozen compound constant graph verifies");
    const auto main = machine.find_function("main");
    check(main.has_value(), "compound compile-time fixture has main function");
    if (main) {
        const auto result = machine.run(*main);
        if (graph.has_errors()) graph.render_diagnostics(std::cerr);
        check(!graph.has_errors(), "VM reconstructs frozen arrays and objects");
        check(result.as_integer() == 35, "compound # values preserve fields and elements");
    }
}

void test_shared_and_cyclic_compile_time_values() {
    abla::ModuleGraph shared_graph;
    static_cast<void>(shared_graph.load_entry("tests/cases/modules/compile-shared.ab"));
    auto shared_semantics = abla::sema::Resolver(shared_graph).resolve();
    auto shared_types = abla::sema::TypeChecker(shared_graph, shared_semantics).check();
    auto shared_program =
        abla::ir::Lowerer(shared_graph, shared_semantics, shared_types).lower();
    abla::vm::Machine shared_machine(
        shared_program, shared_types.types, shared_graph.entry()->diagnostics);
    check(
        abla::vm::materialize_compile_actions(
            shared_program, shared_machine, shared_graph.entry()->diagnostics),
        "shared compile-time subobjects freeze successfully");
    const auto shared_main = shared_machine.find_function("main");
    check(shared_main.has_value(), "shared compound fixture has main function");
    if (shared_main) {
        const auto result = shared_machine.run(*shared_main);
        if (shared_graph.has_errors()) shared_graph.render_diagnostics(std::cerr);
        check(!shared_graph.has_errors(), "shared frozen graph reconstructs in VM");
        check(result.as_integer() == 42, "frozen graph preserves internal aliasing");
    }

    abla::ModuleGraph cycle_graph;
    static_cast<void>(cycle_graph.load_entry("tests/cases/modules/compile-cycle.ab"));
    auto cycle_semantics = abla::sema::Resolver(cycle_graph).resolve();
    auto cycle_types = abla::sema::TypeChecker(cycle_graph, cycle_semantics).check();
    auto cycle_program =
        abla::ir::Lowerer(cycle_graph, cycle_semantics, cycle_types).lower();
    abla::vm::Machine cycle_machine(
        cycle_program, cycle_types.types, cycle_graph.entry()->diagnostics);
    check(
        !abla::vm::materialize_compile_actions(
            cycle_program, cycle_machine, cycle_graph.entry()->diagnostics),
        "cyclic compile-time values are rejected while freezing");
    const auto& entries = cycle_graph.entry()->diagnostics.entries();
    check(
        std::any_of(entries.begin(), entries.end(), [](const auto& diagnostic) {
            return diagnostic.message.find("cyclic compile-time value") != std::string::npos;
        }),
        "cyclic compile-time value reports a focused diagnostic");
}

void test_compiler_reflection() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/compiler-reflection.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    abla::vm::Machine machine(program, typed.types, graph.entry()->diagnostics);
    check(
        abla::vm::materialize_compile_actions(
            program, machine, graph.entry()->diagnostics),
        "compiler reflection executes inside the compile VM");
    check(
        abla::ir::Verifier(typed.types, graph.entry()->diagnostics).verify(program),
        "compiler reflection leaves verified runtime IR");
    const auto main = machine.find_function("main");
    check(main.has_value(), "compiler reflection fixture has main function");
    if (main) {
        const auto result = machine.run(*main);
        if (graph.has_errors()) graph.render_diagnostics(std::cerr);
        check(!graph.has_errors(), "stable function handles inspect without diagnostics");
        check(result.as_integer() == 42, "function reflection exposes deterministic metadata");
    }
}

void test_subparser_stack_and_phases() {
    abla::SubparserRegistry subparsers;
    const auto passthrough = [](abla::SubparserContext& context,
                                abla::TokenKind open,
                                abla::TokenKind close) {
        context.expect(open, "to begin subparser payload");
        auto expression = context.parse_abla_expression();
        const auto end = context.expect(close, "to end subparser payload");
        if (expression) expression->span.end = end.span.end;
        return expression;
    };
    check(
        subparsers.add("abla", [passthrough](abla::SubparserContext& context) {
            return passthrough(
                context, abla::TokenKind::LeftBrace, abla::TokenKind::RightBrace);
        }),
        "base-expression subparser registers once");
    check(
        subparsers.add("box", [passthrough](abla::SubparserContext& context) {
            return passthrough(
                context, abla::TokenKind::LeftBracket, abla::TokenKind::RightBracket);
        }),
        "outer subparser registers once");

    abla::ModuleGraph graph(&subparsers);
    static_cast<void>(graph.load_entry("tests/cases/modules/subparser-stack.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    abla::vm::Machine machine(program, typed.types, graph.entry()->diagnostics);
    check(
        abla::vm::materialize_compile_actions(
            program, machine, graph.entry()->diagnostics),
        "nested subparser output executes under #");
    check(
        abla::ir::Verifier(typed.types, graph.entry()->diagnostics).verify(program),
        "nested subparser output lowers to ordinary verified IR");
    const auto main = machine.find_function("main");
    check(main.has_value(), "subparser phase fixture has main function");
    if (main) {
        const auto result = machine.run(*main);
        if (graph.has_errors()) graph.render_diagnostics(std::cerr);
        check(!graph.has_errors(), "nested parser hand-off executes without diagnostics");
        check(result.as_integer() == 42, "subparser expressions run at compile and runtime");
    }
}

void test_subparser_registration_is_transactional() {
    abla::SubparserRegistry subparsers;
    abla::ModuleGraph duplicate_graph(&subparsers);
    static_cast<void>(duplicate_graph.load_entry(
        "tests/cases/modules/subparser-registration-duplicate.ab"));
    check(
        duplicate_graph.has_errors(),
        "duplicate staged subparser registration is rejected");
    check(
        subparsers.find("duplicate") == nullptr,
        "a failed staging transaction does not publish any handler");
    check(
        std::any_of(
            duplicate_graph.entry()->diagnostics.entries().begin(),
            duplicate_graph.entry()->diagnostics.entries().end(),
            [](const auto& diagnostic) {
                return diagnostic.message.find("registration was rejected") !=
                    std::string::npos;
            }),
        "duplicate registration reports a focused compile-time diagnostic");

    abla::ModuleGraph ordering_graph;
    static_cast<void>(ordering_graph.load_entry(
        "tests/cases/modules/subparser-use-before-registration.ab"));
    check(
        ordering_graph.has_errors(),
        "a subparser must be registered before its first lexical use");
    check(
        std::any_of(
            ordering_graph.entry()->diagnostics.entries().begin(),
            ordering_graph.entry()->diagnostics.entries().end(),
            [](const auto& diagnostic) {
                return diagnostic.message.find(
                    "was not registered before its first use") !=
                    std::string::npos;
            }),
        "use-before-registration reports the staging-order contract");
}

void test_c_backend_output() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/compile-time.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    abla::vm::Machine machine(program, typed.types, graph.entry()->diagnostics);
    static_cast<void>(abla::vm::materialize_compile_actions(
        program, machine, graph.entry()->diagnostics));
    std::ostringstream output;
    abla::backend::CEmitter(
        program, typed.types, graph.entry()->diagnostics).emit(output);
    const auto generated = output.str();
    check(!graph.has_errors(), "materialized IR emits C without diagnostics");
    check(
        generated.find("Generated deterministically by ablac0") != std::string::npos,
        "generated C identifies deterministic source");
    check(generated.find("INT64_C(36)") != std::string::npos, "C contains materialized # value");
    check(generated.find("abla_function_2") != std::string::npos, "C emits stable function IDs");
    check(generated.find("$compile") == std::string::npos, "compile-only names are absent from C");
}

void test_class_execution() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/classes.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    check(
        abla::ir::Verifier(typed.types, graph.entry()->diagnostics).verify(program),
        "class program produces verified IR");
    abla::vm::Machine machine(program, typed.types, graph.entry()->diagnostics);
    const auto main = machine.find_function("main");
    check(main.has_value(), "class program has main");
    if (main) {
        const auto result = machine.run(*main);
        if (graph.has_errors()) graph.render_diagnostics(std::cerr);
        check(!graph.has_errors(), "constructor fields and method execute in VM");
        check(result.as_integer() == 42, "mutable class field preserves method state");
    }
}

void test_explicit_host_runtime() {
    abla::ModuleGraph graph;
    static_cast<void>(graph.load_entry("tests/cases/modules/host-runtime.ab"));
    auto semantics = abla::sema::Resolver(graph).resolve();
    auto typed = abla::sema::TypeChecker(graph, semantics).check();
    auto program = abla::ir::Lowerer(graph, semantics, typed).lower();
    check(
        abla::ir::Verifier(typed.types, graph.entry()->diagnostics).verify(program),
        "explicit host I/O program produces verified IR");
    abla::vm::Machine machine(program, typed.types, graph.entry()->diagnostics);
    const auto main = machine.find_function("main");
    check(main.has_value(), "host I/O fixture has main function");
    if (main) {
        const auto result = machine.run(*main);
        if (graph.has_errors()) graph.render_diagnostics(std::cerr);
        check(!graph.has_errors(), "host I/O executes through the VM adapter");
        check(result.as_integer() == 42, "host I/O agrees with runtime adapter");
    }
}

} // namespace

int main() {
    test_source_locations();
    test_lexer_nested_comments_and_semicolons();
    test_string_interpolation();
    test_parser_compatible_surface();
    test_optional_semicolons();
    test_diagnostics();
    test_module_graph_and_resolution();
    test_resolution_diagnostics();
    test_type_diagnostics();
    test_valid_semantic_types();
    test_ir_lowering_and_verification();
    test_vm_execution();
    test_registered_native_execution();
    test_compile_time_materialization();
    test_compound_compile_time_materialization();
    test_shared_and_cyclic_compile_time_values();
    test_compiler_reflection();
    test_subparser_stack_and_phases();
    test_subparser_registration_is_transactional();
    test_c_backend_output();
    test_class_execution();
    test_explicit_host_runtime();

    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all tests passed\n";
    return EXIT_SUCCESS;
}
