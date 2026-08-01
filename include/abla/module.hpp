#pragma once

#include "abla/ast.hpp"
#include "abla/diagnostic.hpp"
#include "abla/source.hpp"
#include "abla/subparser.hpp"
#include "abla/token.hpp"

#include <filesystem>
#include <iosfwd>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace abla {

struct Module;

struct ImportEdge {
    SourceSpan span;
    std::string requested_path;
    Module* target{};
};

struct Module {
    explicit Module(SourceFile source_file)
        : source(std::move(source_file)) {}

    SourceFile source;
    Diagnostics diagnostics;
    std::vector<Token> tokens;
    std::unique_ptr<ast::Program> program;
    std::vector<ImportEdge> imports;
};

class ModuleGraph {
public:
    explicit ModuleGraph(SubparserRegistry* subparsers = nullptr);
    void add_search_path(std::filesystem::path path);
    Module& load_entry(const std::filesystem::path& path);

    [[nodiscard]] const std::vector<std::unique_ptr<Module>>& modules() const noexcept {
        return modules_;
    }
    [[nodiscard]] Module* entry() const noexcept { return entry_; }
    [[nodiscard]] bool has_errors() const noexcept;
    [[nodiscard]] std::size_t error_count() const noexcept;
    void render_diagnostics(std::ostream& output) const;

private:
    enum class LoadState { Loading, Loaded };

    Module* load(
        const std::filesystem::path& path,
        Module* importer,
        SourceSpan import_span);
    void discover_imports(Module& module);
    void discover_import(Module& module, const ast::Expression& expression);
    bool compile_subparser_prelude(Module& module, std::string_view missing);
    [[nodiscard]] static std::filesystem::path canonical_path(
        const std::filesystem::path& path);
    [[nodiscard]] std::filesystem::path resolve_import(
        const Module& importer,
        const std::filesystem::path& requested) const;

    std::vector<std::unique_ptr<Module>> modules_;
    std::unordered_map<std::string, Module*> by_path_;
    std::unordered_map<std::string, LoadState> states_;
    Module* entry_{};
    std::vector<std::filesystem::path> search_paths_;
    SubparserRegistry owned_subparsers_;
    SubparserRegistry* subparsers_{};
    bool owns_subparsers_{};
};

} // namespace abla
