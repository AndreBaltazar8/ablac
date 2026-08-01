#pragma once

#include "abla/module.hpp"
#include "abla/sema.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace abla::sema {

using TypeId = std::uint32_t;

enum class TypeKind {
    Error,
    Unknown,
    Void,
    Bool,
    Integer,
    Float,
    Char,
    String,
    CString,
    Any,
    Null,
    Nominal,
    TypeParameter,
    Array,
    Function,
    Nullable,
    Pointer,
};

struct Type {
    TypeKind kind{};
    std::string name;
    std::vector<TypeId> arguments;
    TypeId result{};
    SymbolId symbol{};
    std::uint16_t bits{};
    bool signed_integer{};

    bool operator==(const Type&) const = default;
};

class TypeStore {
public:
    TypeStore();

    [[nodiscard]] TypeId error() const noexcept { return 0; }
    [[nodiscard]] TypeId unknown() const noexcept { return 1; }
    [[nodiscard]] TypeId void_type() const noexcept { return 2; }
    [[nodiscard]] TypeId bool_type() const noexcept { return 3; }
    [[nodiscard]] TypeId null_type() const noexcept { return 4; }
    [[nodiscard]] TypeId any_type() const noexcept { return 5; }
    [[nodiscard]] TypeId string_type() const noexcept { return 6; }
    [[nodiscard]] TypeId cstring_type() const noexcept { return 7; }
    [[nodiscard]] TypeId char_type() const noexcept { return 8; }
    [[nodiscard]] TypeId int_type() const noexcept { return i64_; }

    [[nodiscard]] const Type& get(TypeId id) const;
    [[nodiscard]] TypeId integer(std::uint16_t bits, bool is_signed);
    [[nodiscard]] TypeId floating(std::uint16_t bits);
    [[nodiscard]] TypeId nominal(SymbolId symbol, std::string name, std::vector<TypeId> arguments = {});
    [[nodiscard]] TypeId type_parameter(SymbolId symbol, std::string name);
    [[nodiscard]] TypeId array(TypeId element);
    [[nodiscard]] TypeId function(std::vector<TypeId> parameters, TypeId result);
    [[nodiscard]] TypeId nullable(TypeId base);
    [[nodiscard]] TypeId pointer(TypeId pointee);
    [[nodiscard]] std::string to_string(TypeId id) const;
    [[nodiscard]] bool is_numeric(TypeId id) const;
    [[nodiscard]] bool is_integer(TypeId id) const;
    [[nodiscard]] bool can_assign(TypeId target, TypeId source) const;

private:
    [[nodiscard]] TypeId intern(Type type);

    std::vector<Type> types_;
    TypeId i64_{};
};

class TypedProgram {
public:
    [[nodiscard]] TypeId expression_type(const ast::Expression& expression) const;
    [[nodiscard]] TypeId symbol_type(const Symbol& symbol) const;
    [[nodiscard]] TypeId syntax_type(const ast::TypeSyntax& syntax) const;
    [[nodiscard]] const Symbol* selected_call(const ast::CallExpression& call) const;

    TypeStore types;

private:
    friend class TypeChecker;
    std::unordered_map<const ast::Expression*, TypeId> expression_types_;
    std::unordered_map<const Symbol*, TypeId> symbol_types_;
    std::unordered_map<const ast::TypeSyntax*, TypeId> syntax_types_;
    std::unordered_map<const ast::CallExpression*, const Symbol*> selected_calls_;
};

class TypeChecker {
public:
    TypeChecker(ModuleGraph& graph, SemanticModel& semantics)
        : graph_(graph), semantics_(semantics) {}

    [[nodiscard]] TypedProgram check();

private:
    enum class CheckState { Unchecked, Checking, Checked };

    void prepare_symbols();
    void prepare_statement(ast::Statement& statement);
    void prepare_function(ast::FunctionDeclaration& declaration, const Symbol& symbol);
    void prepare_class(ast::ClassDeclaration& declaration, const Symbol& symbol);
    void check_statement(ast::Statement& statement);
    void check_function(ast::FunctionDeclaration& declaration, const Symbol& symbol);
    void check_class(ast::ClassDeclaration& declaration);
    TypeId check_property(ast::PropertyDeclaration& declaration);
    TypeId check_block(ast::Block& block);
    TypeId check_expression(ast::Expression& expression);
    TypeId check_call(ast::CallExpression& call);
    TypeId check_member(ast::MemberExpression& member);
    TypeId type_from_syntax(ast::TypeSyntax& syntax);
    TypeId type_of_symbol(const Symbol& symbol);
    TypeId common_type(TypeId left, TypeId right, SourceSpan span);
    void require_assignable(TypeId target, TypeId source, SourceSpan span, std::string_view context);
    [[nodiscard]] const Symbol* declaration_symbol(const ast::Statement& statement) const;
    [[nodiscard]] Symbol* scope_symbol(const ast::Node& owner, std::string_view name) const;
    [[nodiscard]] Module* module_for(const ast::Node& node) const;
    Diagnostics& diagnostics();

    ModuleGraph& graph_;
    SemanticModel& semantics_;
    TypedProgram typed_;
    Module* current_module_{};
    std::unordered_map<const Symbol*, CheckState> states_;
};

} // namespace abla::sema
