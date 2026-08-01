#include "abla/backend_c.hpp"
#include "abla/diagnostic.hpp"
#include "abla/lexer.hpp"
#include "abla/ir.hpp"
#include "abla/module.hpp"
#include "abla/parser.hpp"
#include "abla/sema.hpp"
#include "abla/types.hpp"
#include "abla/vm.hpp"
#include "abla/source.hpp"
#include "abla/token.hpp"

#include <exception>
#include <iostream>
#include <string_view>

namespace {

void print_value(std::ostream& output, const abla::vm::Value& value) {
    if (value.is_void()) output << "void";
    else if (value.is_null()) output << "null";
    else if (const auto* integer = std::get_if<std::int64_t>(&value.storage())) {
        output << *integer;
    } else if (const auto* boolean = std::get_if<bool>(&value.storage())) {
        output << (*boolean ? "true" : "false");
    } else if (const auto* string = std::get_if<std::string>(&value.storage())) {
        output << *string;
    } else {
        output << "<value>";
    }
}

int usage(std::ostream& output) {
    output << "usage: ablac0 <check|emit-c|ir|parse|run|tokens> <file.ab>\n"
              "       ablac0 --version\n";
    return 2;
}

} // namespace

int main(int argc, char** argv) {
    if (argc == 2 && std::string_view(argv[1]) == "--version") {
        std::cout << "ablac0 0.1.0-dev\n";
        return 0;
    }
    if (argc != 3) {
        return usage(std::cerr);
    }

    const std::string_view command(argv[1]);
    if (command != "check" && command != "emit-c" &&
        command != "ir" && command != "run" &&
        command != "parse" && command != "tokens") {
        return usage(std::cerr);
    }

    try {
        if (command == "check" || command == "emit-c" ||
            command == "ir" || command == "run") {
            abla::ModuleGraph graph;
            static_cast<void>(graph.load_entry(argv[2]));
            std::size_t symbols = 0;
            if (!graph.has_errors()) {
                auto model = abla::sema::Resolver(graph).resolve();
                symbols = model.symbols().size();
                if (!graph.has_errors()) {
                    auto typed = abla::sema::TypeChecker(graph, model).check();
                    if ((command == "emit-c" || command == "ir" || command == "run") &&
                        !graph.has_errors()) {
                        auto program = abla::ir::Lowerer(graph, model, typed).lower();
                        if (!graph.has_errors()) {
                            abla::vm::Machine compile_machine(
                                program,
                                typed.types,
                                graph.entry()->diagnostics);
                            static_cast<void>(abla::vm::materialize_compile_actions(
                                program,
                                compile_machine,
                                graph.entry()->diagnostics));
                        }
                        if (!graph.has_errors()) {
                            static_cast<void>(abla::ir::Verifier(
                                typed.types,
                                graph.entry()->diagnostics).verify(program));
                        }
                        if (!graph.has_errors()) {
                            if (command == "ir") {
                                abla::ir::print(std::cout, program, typed.types);
                            } else if (command == "emit-c") {
                                abla::backend::CEmitter(
                                    program,
                                    typed.types,
                                    graph.entry()->diagnostics).emit(std::cout);
                            } else {
                                abla::vm::Machine machine(
                                    program,
                                    typed.types,
                                    graph.entry()->diagnostics);
                                const auto main_function = machine.find_function("main");
                                if (!main_function) {
                                    graph.entry()->diagnostics.error(
                                        {}, "program has no 'main' function");
                                } else {
                                    const auto value = machine.run(*main_function);
                                    if (!graph.has_errors()) {
                                        print_value(std::cout, value);
                                        std::cout << '\n';
                                    }
                                }
                            }
                        }
                    }
                }
            }
            graph.render_diagnostics(std::cerr);
            if (!graph.has_errors() && command == "check") {
                std::cout << graph.entry()->source.path() << ": ok ("
                          << graph.modules().size() << " module(s), "
                          << symbols << " symbol(s))\n";
            }
            return graph.has_errors() ? 1 : 0;
        }

        auto source = abla::SourceFile::read(argv[2]);
        abla::Diagnostics diagnostics;
        const auto tokens = abla::Lexer(source, diagnostics).tokenize();

        if (command == "tokens") {
            for (const auto& token : tokens) {
                const auto location = source.location(token.span.begin);
                std::cout << location.line << ':' << location.column << ' '
                          << abla::token_kind_name(token.kind);
                if (!token.span.empty()) {
                    std::cout << " `" << source.slice(token.span) << '`';
                }
                std::cout << '\n';
            }
        } else {
            auto program = abla::Parser(source, tokens, diagnostics).parse();
            if (!diagnostics.has_errors()) {
                std::cout << source.path() << ": ok ("
                          << program->declarations.size() << " file declarations)\n";
            }
        }

        diagnostics.render(std::cerr, source);
        return diagnostics.has_errors() ? 1 : 0;
    } catch (const std::exception& error) {
        std::cerr << "ablac0: error: " << error.what() << '\n';
        return 1;
    }
}
