#include "abla/module.hpp"

#include "abla/lexer.hpp"
#include "abla/parser.hpp"
#include "abla/ir.hpp"
#include "abla/sema.hpp"
#include "abla/subparser.hpp"
#include "abla/types.hpp"
#include "abla/vm.hpp"

#include <algorithm>
#include <cstdlib>
#include <ostream>
#include <stdexcept>
#include <system_error>

namespace abla {

namespace {

const ast::CallExpression* import_call(const ast::Expression& expression) {
    if (expression.kind != ast::Expression::Kind::Compile) {
        return nullptr;
    }
    const auto& compile = static_cast<const ast::UnaryExpression&>(expression);
    if (!compile.operand || compile.operand->kind != ast::Expression::Kind::Call) {
        return nullptr;
    }
    const auto& call = static_cast<const ast::CallExpression&>(*compile.operand);
    if (!call.callee || call.callee->kind != ast::Expression::Kind::Identifier) {
        return nullptr;
    }
    const auto& callee = static_cast<const ast::ScalarExpression&>(*call.callee);
    return callee.value == "import" ? &call : nullptr;
}

std::string decode_import_path(
    const ast::StringExpression& string,
    Diagnostics& diagnostics) {
    if (string.parts.size() != 1 ||
        string.parts.front()->kind != ast::Expression::Kind::StringText) {
        diagnostics.error(
            string.span,
            "import path must be a string literal without interpolation");
        return {};
    }

    return static_cast<const ast::ScalarExpression&>(*string.parts.front()).value;
}

} // namespace

ModuleGraph::ModuleGraph(SubparserRegistry* subparsers)
    : owned_subparsers_(bootstrap_subparsers()),
      subparsers_(subparsers == nullptr ? &owned_subparsers_ : subparsers),
      owns_subparsers_(subparsers == nullptr) {
    if (const auto* configured = std::getenv("ABLA_STDLIB")) {
        add_search_path(configured);
    }
    add_search_path("stdlib");
}

void ModuleGraph::add_search_path(std::filesystem::path path) {
    const auto canonical = canonical_path(path);
    if (std::find(search_paths_.begin(), search_paths_.end(), canonical) ==
        search_paths_.end()) {
        search_paths_.push_back(canonical);
    }
}

Module& ModuleGraph::load_entry(const std::filesystem::path& path) {
    modules_.clear();
    by_path_.clear();
    states_.clear();
    if (owns_subparsers_) owned_subparsers_ = bootstrap_subparsers();
    entry_ = load(path, nullptr, {});
    if (entry_ == nullptr) {
        throw std::runtime_error("failed to load entry module '" + path.string() + "'");
    }
    return *entry_;
}

Module* ModuleGraph::load(
    const std::filesystem::path& path,
    Module* importer,
    SourceSpan import_span) {
    const auto canonical = canonical_path(path);
    const auto key = canonical.string();
    if (const auto existing = by_path_.find(key); existing != by_path_.end()) {
        if (states_.at(key) == LoadState::Loading && importer != nullptr) {
            importer->diagnostics.error(
                import_span,
                "import cycle reaches '" + key + "'");
        }
        return existing->second;
    }

    SourceFile source("", "");
    try {
        source = SourceFile::read(canonical);
    } catch (const std::exception& error) {
        if (importer != nullptr) {
            importer->diagnostics.error(import_span, error.what());
            return nullptr;
        }
        throw;
    }

    auto owned = std::make_unique<Module>(std::move(source));
    auto* module = owned.get();
    modules_.push_back(std::move(owned));
    by_path_.emplace(key, module);
    states_.emplace(key, LoadState::Loading);

    module->tokens = Lexer(module->source, module->diagnostics).tokenize();
    constexpr std::size_t max_staging_rounds = 32;
    bool finished = false;
    for (std::size_t round = 0; round < max_staging_rounds; ++round) {
        std::optional<std::string> missing;
        module->program = Parser(
            module->source,
            module->tokens,
            module->diagnostics,
            subparsers_).parse_prefix(missing);
        module->imports.clear();
        if (module->program && !module->diagnostics.has_errors()) {
            discover_imports(*module);
        }
        if (module->diagnostics.has_errors()) break;
        if (!missing) {
            finished = true;
            break;
        }
        if (!compile_subparser_prelude(*module, *missing)) {
            module->diagnostics.error(
                {},
                "subparser '" + *missing +
                    "' was not registered before its first use");
            break;
        }
    }
    if (!finished && !module->diagnostics.has_errors()) {
        module->diagnostics.error({}, "subparser staging limit exceeded");
    }
    states_[key] = LoadState::Loaded;
    return module;
}

bool ModuleGraph::compile_subparser_prelude(
    Module& module,
    std::string_view missing) {
    if (has_errors()) return false;
    auto semantics = sema::Resolver(*this).resolve();
    if (has_errors()) return false;
    auto typed = sema::TypeChecker(*this, semantics).check();
    if (has_errors()) return false;
    auto program = ir::Lowerer(*this, semantics, typed).lower();
    if (has_errors()) return false;

    std::vector<std::pair<std::string, ir::FunctionId>> pending;
    vm::CompilerServices services;
    services.register_subparser = [&](std::string name, ir::FunctionId function) {
        if (name.empty() || function >= program.functions.size() ||
            subparsers_->find(name) != nullptr ||
            std::any_of(pending.begin(), pending.end(), [&](const auto& registration) {
                return registration.first == name;
            })) {
            return false;
        }
        const auto& handler = program.functions[function];
        if (!handler.compile_only || handler.parameters.size() != 1) return false;
        pending.emplace_back(std::move(name), function);
        return true;
    };
    vm::Machine machine(
        program,
        typed.types,
        module.diagnostics,
        nullptr,
        {},
        &services);
    if (!vm::materialize_compile_actions(program, machine, module.diagnostics) ||
        module.diagnostics.has_errors()) {
        return false;
    }
    if (!ir::Verifier(typed.types, module.diagnostics).verify(program) ||
        module.diagnostics.has_errors()) {
        return false;
    }
    if (std::none_of(pending.begin(), pending.end(), [&](const auto& registration) {
            return registration.first == missing;
        })) {
        return false;
    }

    auto shared_program = std::make_shared<const ir::Program>(std::move(program));
    auto shared_types = std::make_shared<const sema::TypeStore>(std::move(typed.types));
    for (auto& [name, function] : pending) {
        if (!add_compiled_subparser(
                *subparsers_,
                std::move(name),
                shared_program,
                shared_types,
                function)) {
            return false;
        }
    }
    return subparsers_->find(missing) != nullptr;
}

void ModuleGraph::discover_imports(Module& module) {
    for (const auto& declaration : module.program->declarations) {
        if (declaration->kind != ast::Statement::Kind::Expression) {
            continue;
        }
        const auto& statement =
            static_cast<const ast::ExpressionStatement&>(*declaration);
        if (statement.expression) {
            discover_import(module, *statement.expression);
        }
    }
}

void ModuleGraph::discover_import(Module& module, const ast::Expression& expression) {
    const auto* call = import_call(expression);
    if (call == nullptr) {
        return;
    }
    if (call->arguments.size() != 1 || !call->arguments.front().value ||
        call->arguments.front().value->kind != ast::Expression::Kind::String) {
        module.diagnostics.error(
            call->span,
            "import expects exactly one constant string argument");
        return;
    }
    const auto& string = static_cast<const ast::StringExpression&>(
        *call->arguments.front().value);
    auto requested = decode_import_path(string, module.diagnostics);
    if (requested.empty()) {
        return;
    }
    const auto resolved = resolve_import(module, requested);
    auto* target = load(resolved, &module, expression.span);
    module.imports.push_back(ImportEdge{expression.span, std::move(requested), target});
}

std::filesystem::path ModuleGraph::resolve_import(
    const Module& importer,
    const std::filesystem::path& requested) const {
    std::vector<std::filesystem::path> candidates;
    candidates.push_back(
        std::filesystem::path(importer.source.path()).parent_path() / requested);
    for (const auto& search_path : search_paths_) {
        candidates.push_back(search_path / requested);
        if (!requested.has_extension()) {
            candidates.push_back(search_path / requested / "entry.ab");
        }
    }
    std::error_code error;
    for (const auto& candidate : candidates) {
        if (std::filesystem::is_regular_file(candidate, error) && !error) {
            return candidate;
        }
        error.clear();
    }
    return candidates.front();
}

std::filesystem::path ModuleGraph::canonical_path(const std::filesystem::path& path) {
    std::error_code error;
    auto absolute = std::filesystem::absolute(path, error);
    if (error) {
        absolute = path;
    }
    auto canonical = std::filesystem::weakly_canonical(absolute, error);
    return error ? absolute.lexically_normal() : canonical;
}

bool ModuleGraph::has_errors() const noexcept {
    return std::any_of(modules_.begin(), modules_.end(), [](const auto& module) {
        return module->diagnostics.has_errors();
    });
}

std::size_t ModuleGraph::error_count() const noexcept {
    std::size_t count = 0;
    for (const auto& module : modules_) {
        count += module->diagnostics.error_count();
    }
    return count;
}

void ModuleGraph::render_diagnostics(std::ostream& output) const {
    for (const auto& module : modules_) {
        module->diagnostics.render(output, module->source);
    }
}

} // namespace abla
