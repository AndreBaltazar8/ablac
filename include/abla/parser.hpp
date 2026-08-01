#pragma once

#include "abla/ast.hpp"
#include "abla/diagnostic.hpp"
#include "abla/source.hpp"
#include "abla/token.hpp"

#include <initializer_list>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace abla {

class SubparserContext;
class SubparserRegistry;

class Parser {
public:
    Parser(
        const SourceFile& source,
        const std::vector<Token>& tokens,
        Diagnostics& diagnostics,
        const SubparserRegistry* subparsers = nullptr)
        : source_(source),
          tokens_(tokens),
          diagnostics_(diagnostics),
          subparsers_(subparsers) {}

    [[nodiscard]] std::unique_ptr<ast::Program> parse();
    [[nodiscard]] std::unique_ptr<ast::Program> parse_prefix(
        std::optional<std::string>& missing_subparser);

private:
    ast::StmtPtr parse_statement(bool top_level = false);
    ast::Modifiers parse_modifiers();
    ast::Annotation parse_annotation();
    std::unique_ptr<ast::FunctionDeclaration> parse_function(ast::Modifiers modifiers);
    std::unique_ptr<ast::ClassDeclaration> parse_class(ast::Modifiers modifiers);
    std::unique_ptr<ast::PropertyDeclaration> parse_property(ast::Modifiers modifiers);
    std::unique_ptr<ast::WhileStatement> parse_while();
    std::unique_ptr<ast::WhileStatement> parse_do_while();
    std::unique_ptr<ast::Block> parse_block();
    std::unique_ptr<ast::Block> parse_control_body();
    ast::Parameter parse_parameter(bool constructor);
    std::vector<ast::TypeParameter> parse_type_parameters();
    ast::TypeSyntax parse_type();
    ast::TypeSyntax parse_named_or_function_type();

    ast::ExprPtr parse_expression();
    ast::ExprPtr parse_assignment();
    ast::ExprPtr parse_logical_or();
    ast::ExprPtr parse_logical_and();
    ast::ExprPtr parse_equality();
    ast::ExprPtr parse_comparison();
    ast::ExprPtr parse_term();
    ast::ExprPtr parse_factor();
    ast::ExprPtr parse_unary();
    ast::ExprPtr parse_postfix();
    ast::ExprPtr parse_primary();
    ast::ExprPtr parse_subparser();
    ast::ExprPtr parse_string();
    ast::ExprPtr parse_if();
    ast::ExprPtr parse_when();
    ast::ExprPtr parse_lambda();
    std::vector<ast::Argument> parse_arguments();
    std::optional<std::vector<ast::TypeSyntax>> try_parse_call_type_arguments();

    ast::ExprPtr parse_binary(
        ast::ExprPtr (Parser::*operand)(),
        std::initializer_list<TokenKind> operators);
    [[nodiscard]] bool is_any(std::initializer_list<TokenKind> kinds) const;
    [[nodiscard]] bool at(TokenKind kind) const;
    [[nodiscard]] bool at_end() const;
    bool consume(TokenKind kind);
    Token expect(TokenKind kind, const char* context);
    const Token& current() const;
    const Token& previous() const;
    std::string text(const Token& token) const;
    void skip_separators();
    void skip_newlines();
    void require_statement_boundary();
    void synchronize();
    [[nodiscard]] SourceSpan span_from(std::size_t begin) const;

    friend class SubparserContext;

    const SourceFile& source_;
    const std::vector<Token>& tokens_;
    Diagnostics& diagnostics_;
    const SubparserRegistry* subparsers_{};
    std::size_t position_{};
    std::vector<std::string> subparser_stack_;
    bool defer_unknown_subparsers_{};
};

} // namespace abla
