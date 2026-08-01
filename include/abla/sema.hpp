#pragma once

#include "abla/ast.hpp"
#include "abla/module.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace abla::sema {

using SymbolId = std::uint32_t;

enum class SymbolKind {
    BuiltinType,
    Type,
    TypeParameter,
    Function,
    Property,
    Parameter,
    Local,
};

struct Scope;

struct Symbol {
    SymbolId id{};
    SymbolKind kind{};
    std::string name;
    const ast::Node* declaration{};
    Module* module{};
    Scope* scope{};
    bool mutable_value{};
};

struct Scope {
    Scope* parent{};
    Module* module{};
    const ast::Node* owner{};
    bool is_module{};
    std::unordered_map<std::string, std::vector<Symbol*>> names;

    [[nodiscard]] const std::vector<Symbol*>* local(std::string_view name) const;
};

class SemanticModel {
public:
    SemanticModel() = default;
    SemanticModel(SemanticModel&&) noexcept = default;
    SemanticModel& operator=(SemanticModel&&) noexcept = default;
    SemanticModel(const SemanticModel&) = delete;
    SemanticModel& operator=(const SemanticModel&) = delete;

    [[nodiscard]] const std::vector<Symbol*>& candidates(
        const ast::Expression& expression) const;
    [[nodiscard]] const Symbol* type_symbol(const ast::TypeSyntax& type) const;
    [[nodiscard]] const Scope* module_scope(const Module& module) const;
    [[nodiscard]] const Scope* scope_for(const ast::Node& node) const;
    [[nodiscard]] const Symbol* symbol_for(const ast::Statement& declaration) const;
    [[nodiscard]] const std::vector<std::unique_ptr<Symbol>>& symbols() const noexcept {
        return symbols_;
    }

private:
    friend class Resolver;
    friend class TypeChecker;

    std::vector<std::unique_ptr<Scope>> scopes_;
    std::vector<std::unique_ptr<Symbol>> symbols_;
    std::unordered_map<const Module*, Scope*> module_scopes_;
    std::unordered_map<const ast::Node*, Scope*> node_scopes_;
    std::unordered_map<const ast::Expression*, std::vector<Symbol*>> bindings_;
    std::unordered_map<const ast::TypeSyntax*, Symbol*> type_bindings_;
    std::unordered_map<const ast::Statement*, Symbol*> declaration_symbols_;
};

class Resolver {
public:
    explicit Resolver(ModuleGraph& graph) : graph_(graph) {}

    [[nodiscard]] SemanticModel resolve();

private:
    Scope& make_scope(
        Scope* parent,
        Module* module,
        const ast::Node* owner,
        bool is_module = false);
    Symbol* declare(
        Scope& scope,
        SymbolKind kind,
        std::string name,
        const ast::Node* declaration,
        bool mutable_value = false);
    void install_prelude();
    void prepare_declaration(Scope& scope, ast::Statement& statement);
    void prepare_class_members(ast::ClassDeclaration& declaration, Scope& class_scope);
    void resolve_statement(Scope& scope, ast::Statement& statement);
    void resolve_block(Scope& parent, ast::Block& block);
    void resolve_function(Scope& parent, ast::FunctionDeclaration& declaration);
    void resolve_class(Scope& parent, ast::ClassDeclaration& declaration);
    void resolve_property(Scope& scope, ast::PropertyDeclaration& declaration);
    void resolve_expression(Scope& scope, ast::Expression& expression);
    void resolve_type(Scope& scope, ast::TypeSyntax& type);
    void resolve_modifiers(Scope& scope, ast::Modifiers& modifiers);
    void resolve_annotations(Scope& scope, std::vector<ast::Annotation>& annotations);
    std::vector<Symbol*> lookup(Scope& scope, std::string_view name);
    void lookup_imports(
        Module& module,
        std::string_view name,
        std::unordered_set<const Module*>& visited,
        std::vector<Symbol*>& result);
    [[nodiscard]] bool is_predeclared(const ast::Statement& statement) const;
    [[nodiscard]] static bool has_modifier(
        const ast::Modifiers& modifiers,
        ast::Modifier modifier);
    Diagnostics& diagnostics();

    ModuleGraph& graph_;
    SemanticModel model_;
    Scope* prelude_{};
    Module* current_module_{};
    std::unordered_map<const ast::Statement*, Symbol*> declaration_symbols_;
};

} // namespace abla::sema
