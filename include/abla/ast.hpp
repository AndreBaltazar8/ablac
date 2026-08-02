#pragma once

#include "abla/source.hpp"
#include "abla/token.hpp"

#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace abla::ast {

enum class ParameterMode {
    Borrow,
    Own,
    MutableBorrow,
};

struct Node {
    explicit Node(SourceSpan source_span) : span(source_span) {}
    virtual ~Node() = default;

    SourceSpan span;
};

struct TypeSyntax {
    SourceSpan span;
    std::string name;
    std::vector<TypeSyntax> arguments;
    std::vector<TypeSyntax> parameter_types;
    std::vector<ParameterMode> parameter_modes;
    std::unique_ptr<TypeSyntax> receiver;
    std::unique_ptr<TypeSyntax> return_type;
    std::optional<std::string> borrow_source;
    bool nullable{};
    std::size_t pointer_depth{};

    TypeSyntax() = default;
    TypeSyntax(TypeSyntax&&) noexcept = default;
    TypeSyntax& operator=(TypeSyntax&&) noexcept = default;
    TypeSyntax(const TypeSyntax&) = delete;
    TypeSyntax& operator=(const TypeSyntax&) = delete;

    [[nodiscard]] bool is_function() const noexcept {
        return return_type != nullptr;
    }
};

struct Expression;
struct Block;
using ExprPtr = std::unique_ptr<Expression>;

struct Argument {
    SourceSpan span;
    std::optional<std::string> name;
    ExprPtr value;
};

struct Expression : Node {
    enum class Kind {
        Identifier,
        Integer,
        Boolean,
        Null,
        String,
        StringText,
        Array,
        Unary,
        Binary,
        Assignment,
        Call,
        Member,
        Index,
        Compile,
        If,
        When,
        Lambda,
    };

    Expression(Kind expression_kind, SourceSpan source_span)
        : Node(source_span), kind(expression_kind) {}

    Kind kind;
};

struct ScalarExpression final : Expression {
    ScalarExpression(Kind expression_kind, SourceSpan source_span, std::string scalar_value)
        : Expression(expression_kind, source_span), value(std::move(scalar_value)) {}

    std::string value;
};

struct UnaryExpression final : Expression {
    UnaryExpression(
        Kind expression_kind,
        SourceSpan source_span,
        TokenKind operation_kind,
        ExprPtr operand_value)
        : Expression(expression_kind, source_span),
          operation(operation_kind),
          operand(std::move(operand_value)) {}

    TokenKind operation;
    ExprPtr operand;
};

struct BinaryExpression final : Expression {
    BinaryExpression(
        Kind expression_kind,
        SourceSpan source_span,
        TokenKind operation_kind,
        ExprPtr left_value,
        ExprPtr right_value)
        : Expression(expression_kind, source_span),
          operation(operation_kind),
          left(std::move(left_value)),
          right(std::move(right_value)) {}

    TokenKind operation;
    ExprPtr left;
    ExprPtr right;
};

struct ArrayExpression final : Expression {
    explicit ArrayExpression(SourceSpan source_span)
        : Expression(Kind::Array, source_span) {}

    std::vector<ExprPtr> elements;
};

struct StringExpression final : Expression {
    explicit StringExpression(SourceSpan source_span)
        : Expression(Kind::String, source_span) {}

    // StringText scalar nodes and interpolation expressions in source order.
    std::vector<ExprPtr> parts;
};

struct CallExpression final : Expression {
    CallExpression(SourceSpan source_span, ExprPtr callee_value)
        : Expression(Kind::Call, source_span), callee(std::move(callee_value)) {}

    ExprPtr callee;
    std::vector<TypeSyntax> type_arguments;
    std::vector<Argument> arguments;
};

struct MemberExpression final : Expression {
    MemberExpression(
        SourceSpan source_span,
        ExprPtr receiver_value,
        std::string member_name)
        : Expression(Kind::Member, source_span),
          receiver(std::move(receiver_value)),
          member(std::move(member_name)) {}

    ExprPtr receiver;
    std::string member;
};

struct IndexExpression final : Expression {
    IndexExpression(SourceSpan source_span, ExprPtr receiver_value, ExprPtr index_value)
        : Expression(Kind::Index, source_span),
          receiver(std::move(receiver_value)),
          index(std::move(index_value)) {}

    ExprPtr receiver;
    ExprPtr index;
};

struct IfExpression final : Expression {
    explicit IfExpression(SourceSpan source_span)
        : Expression(Kind::If, source_span) {}

    ExprPtr condition;
    std::unique_ptr<Block> then_body;
    std::unique_ptr<Block> else_body;
};

struct WhenExpression final : Expression {
    explicit WhenExpression(SourceSpan source_span)
        : Expression(Kind::When, source_span) {}

    struct Case {
        SourceSpan span;
        bool is_else{};
        std::vector<ExprPtr> matches;
        std::unique_ptr<Block> body;
    };

    ExprPtr subject;
    std::vector<Case> cases;
};

struct LambdaExpression final : Expression {
    explicit LambdaExpression(SourceSpan source_span)
        : Expression(Kind::Lambda, source_span) {}

    struct Parameter {
        SourceSpan span;
        std::string name;
        std::optional<TypeSyntax> type;
    };

    std::vector<Parameter> parameters;
    std::unique_ptr<Block> body;
};

struct Statement;
using StmtPtr = std::unique_ptr<Statement>;

struct Block final : Node {
    explicit Block(SourceSpan source_span) : Node(source_span) {}
    std::vector<StmtPtr> statements;
};

struct Statement : Node {
    enum class Kind {
        Expression,
        Property,
        Function,
        Class,
        While,
        DoWhile,
    };

    Statement(Kind statement_kind, SourceSpan source_span)
        : Node(source_span), kind(statement_kind) {}

    Kind kind;
};

struct ExpressionStatement final : Statement {
    ExpressionStatement(SourceSpan source_span, ExprPtr expression_value)
        : Statement(Kind::Expression, source_span),
          expression(std::move(expression_value)) {}

    ExprPtr expression;
};

enum class Modifier {
    Compile,
    Abstract,
    Extern,
    Own,
    MutableBorrow,
    NoEscape,
    Resource,
    Trusted,
};

struct Annotation {
    SourceSpan span;
    std::string name;
    std::vector<Argument> arguments;
};

struct Modifiers {
    std::vector<Modifier> values;
    std::vector<Annotation> annotations;
    ExprPtr extern_library;
};

struct PropertyDeclaration final : Statement {
    explicit PropertyDeclaration(SourceSpan source_span)
        : Statement(Kind::Property, source_span) {}

    Modifiers modifiers;
    bool mutable_value{};
    std::string name;
    std::optional<TypeSyntax> type;
    ExprPtr initializer;
};

struct TypeParameter {
    SourceSpan span;
    std::string name;
    std::optional<TypeSyntax> constraint;
};

struct Parameter {
    SourceSpan span;
    std::string name;
    TypeSyntax type;
    ExprPtr default_value;
    std::optional<bool> property_mutability;
    Modifiers modifiers;
};

struct FunctionDeclaration final : Statement {
    explicit FunctionDeclaration(SourceSpan source_span)
        : Statement(Kind::Function, source_span) {}

    Modifiers modifiers;
    std::string name;
    std::optional<TypeSyntax> receiver;
    std::vector<TypeParameter> type_parameters;
    std::vector<Parameter> parameters;
    std::optional<TypeSyntax> return_type;
    std::unique_ptr<Block> body;
    ExprPtr expression_body;
};

struct ClassDeclaration final : Statement {
    explicit ClassDeclaration(SourceSpan source_span)
        : Statement(Kind::Class, source_span) {}

    Modifiers modifiers;
    bool is_interface{};
    std::string name;
    std::vector<TypeParameter> type_parameters;
    std::vector<Parameter> constructor_parameters;
    std::unique_ptr<Block> body;
};

struct WhileStatement final : Statement {
    WhileStatement(SourceSpan source_span, bool is_do_while)
        : Statement(is_do_while ? Kind::DoWhile : Kind::While, source_span) {}

    ExprPtr condition;
    std::unique_ptr<Block> body;
};

struct Program final : Node {
    explicit Program(SourceSpan source_span) : Node(source_span) {}
    std::vector<StmtPtr> declarations;
};

} // namespace abla::ast
