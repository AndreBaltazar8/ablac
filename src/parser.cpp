#include "abla/parser.hpp"

#include "abla/subparser.hpp"

#include <algorithm>
#include <utility>

namespace abla {

namespace {

struct MissingSubparser {
    std::string name;
};

bool has_modifier(const ast::Modifiers& modifiers) {
    return !modifiers.values.empty() || !modifiers.annotations.empty();
}

unsigned hex_value(char character) {
    if (character >= '0' && character <= '9') {
        return static_cast<unsigned>(character - '0');
    }
    if (character >= 'a' && character <= 'f') {
        return static_cast<unsigned>(character - 'a' + 10);
    }
    return static_cast<unsigned>(character - 'A' + 10);
}

void append_utf8(std::string& output, unsigned codepoint) {
    if (codepoint <= 0x7f) {
        output.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7ff) {
        output.push_back(static_cast<char>(0xc0u | (codepoint >> 6u)));
        output.push_back(static_cast<char>(0x80u | (codepoint & 0x3fu)));
    } else {
        output.push_back(static_cast<char>(0xe0u | (codepoint >> 12u)));
        output.push_back(static_cast<char>(0x80u | ((codepoint >> 6u) & 0x3fu)));
        output.push_back(static_cast<char>(0x80u | (codepoint & 0x3fu)));
    }
}

std::string decode_string_text(std::string_view raw) {
    std::string result;
    result.reserve(raw.size());
    for (std::size_t index = 0; index < raw.size(); ++index) {
        if (raw[index] != '\\' || index + 1 >= raw.size()) {
            result.push_back(raw[index]);
            continue;
        }
        const auto escape = raw[++index];
        switch (escape) {
        case 't': result.push_back('\t'); break;
        case 'b': result.push_back('\b'); break;
        case 'r': result.push_back('\r'); break;
        case 'n': result.push_back('\n'); break;
        case '\'': result.push_back('\''); break;
        case '"': result.push_back('"'); break;
        case '\\': result.push_back('\\'); break;
        case '$': result.push_back('$'); break;
        case 'u': {
            unsigned codepoint = 0;
            for (std::size_t digit = 0; digit < 4 && index + 1 < raw.size(); ++digit) {
                codepoint = codepoint * 16u + hex_value(raw[++index]);
            }
            append_utf8(result, codepoint);
            break;
        }
        default:
            result.push_back(escape);
            break;
        }
    }
    return result;
}

} // namespace

std::unique_ptr<ast::Program> Parser::parse() {
    std::optional<std::string> missing;
    auto program = parse_prefix(missing);
    if (missing) {
        diagnostics_.error({}, "subparser '" + *missing + "' is not registered");
    }
    return program;
}

std::unique_ptr<ast::Program> Parser::parse_prefix(
    std::optional<std::string>& missing_subparser) {
    missing_subparser.reset();
    defer_unknown_subparsers_ = true;
    auto program = std::make_unique<ast::Program>(
        SourceSpan{0, source_.text().size()});
    skip_separators();
    while (!at_end()) {
        const auto before = position_;
        try {
            if (auto declaration = parse_statement(true)) {
                program->declarations.push_back(std::move(declaration));
            }
        } catch (const MissingSubparser& missing) {
            missing_subparser = missing.name;
            break;
        }
        if (position_ == before) {
            diagnostics_.error(current().span, "parser made no progress");
            ++position_;
        }
        require_statement_boundary();
        skip_separators();
    }
    defer_unknown_subparsers_ = false;
    return program;
}

ast::StmtPtr Parser::parse_statement(bool top_level) {
    const auto begin = current().span.begin;
    auto modifiers = parse_modifiers();
    if (at(TokenKind::KwFun)) {
        return parse_function(std::move(modifiers));
    }
    if (at(TokenKind::KwClass) || at(TokenKind::KwInterface)) {
        return parse_class(std::move(modifiers));
    }
    if (at(TokenKind::KwVal) || at(TokenKind::KwVar)) {
        return parse_property(std::move(modifiers));
    }
    if (has_modifier(modifiers)) {
        diagnostics_.error(
            current().span,
            "modifiers and annotations must precede a declaration");
    }
    if (at(TokenKind::KwWhile)) {
        return parse_while();
    }
    if (at(TokenKind::KwDo)) {
        return parse_do_while();
    }

    auto expression = parse_expression();
    if (!expression) {
        synchronize();
        return nullptr;
    }
    if (top_level && expression->kind != ast::Expression::Kind::Compile) {
        diagnostics_.error(
            expression->span,
            "only declarations and compile-time expressions are allowed at file scope");
    }
    return std::make_unique<ast::ExpressionStatement>(
        SourceSpan{begin, expression->span.end},
        std::move(expression));
}

ast::Modifiers Parser::parse_modifiers() {
    ast::Modifiers result;
    bool found = true;
    while (found) {
        found = false;
        while (at(TokenKind::At)) {
            result.annotations.push_back(parse_annotation());
            skip_newlines();
            found = true;
        }
        if (consume(TokenKind::KwCompile)) {
            result.values.push_back(ast::Modifier::Compile);
            found = true;
        } else if (consume(TokenKind::KwAbstract)) {
            result.values.push_back(ast::Modifier::Abstract);
            found = true;
        } else if (consume(TokenKind::KwOwn)) {
            result.values.push_back(ast::Modifier::Own);
            found = true;
        } else if (consume(TokenKind::KwNoEscape)) {
            result.values.push_back(ast::Modifier::NoEscape);
            found = true;
        } else if (consume(TokenKind::KwResource)) {
            result.values.push_back(ast::Modifier::Resource);
            found = true;
        } else if (consume(TokenKind::KwTrusted)) {
            result.values.push_back(ast::Modifier::Trusted);
            found = true;
        } else if (consume(TokenKind::KwExtern)) {
            result.values.push_back(ast::Modifier::Extern);
            found = true;
            if (consume(TokenKind::Colon)) {
                if (at(TokenKind::StringStart)) {
                    result.extern_library = parse_string();
                } else {
                    diagnostics_.error(
                        current().span,
                        "extern library must be a string literal");
                }
            }
        }
        if (found) {
            skip_newlines();
        }
    }
    return result;
}

ast::Annotation Parser::parse_annotation() {
    const auto start = expect(TokenKind::At, "to start annotation");
    const auto name = expect(TokenKind::Identifier, "as annotation name");
    ast::Annotation result{span_from(start.span.begin), text(name), {}};
    if (at(TokenKind::LeftParen)) {
        result.arguments = parse_arguments();
        result.span.end = previous().span.end;
    }
    return result;
}

std::unique_ptr<ast::FunctionDeclaration> Parser::parse_function(
    ast::Modifiers modifiers) {
    const auto start = expect(TokenKind::KwFun, "to declare function");
    auto function = std::make_unique<ast::FunctionDeclaration>(start.span);
    function->modifiers = std::move(modifiers);

    // A receiver may itself be generic, so parse a type tentatively. On the
    // common path this is only one identifier and produces no diagnostics.
    const auto receiver_start = position_;
    if (at(TokenKind::Identifier) || at(TokenKind::LeftParen)) {
        auto possible_receiver = parse_type();
        if (consume(TokenKind::Dot)) {
            function->receiver = std::move(possible_receiver);
            const auto name = expect(TokenKind::Identifier, "as extension function name");
            function->name = text(name);
        } else if (const auto separator = possible_receiver.name.rfind('.');
                   separator != std::string::npos) {
            // Named type parsing preserves qualification as one string. In a
            // function header the final component is instead the function
            // name: `fun package.Type.extension`.
            function->name = possible_receiver.name.substr(separator + 1);
            possible_receiver.name.erase(separator);
            function->receiver = std::move(possible_receiver);
        } else {
            position_ = receiver_start;
            const auto name = expect(TokenKind::Identifier, "as function name");
            function->name = text(name);
        }
    } else {
        const auto name = expect(TokenKind::Identifier, "as function name");
        function->name = text(name);
    }

    if (at(TokenKind::Less)) {
        function->type_parameters = parse_type_parameters();
    }
    if (at(TokenKind::LeftParen)) {
        consume(TokenKind::LeftParen);
        skip_newlines();
        while (!at(TokenKind::RightParen) && !at_end()) {
            function->parameters.push_back(parse_parameter(false));
            skip_newlines();
            if (!consume(TokenKind::Comma)) {
                break;
            }
            skip_newlines();
        }
        expect(TokenKind::RightParen, "after function parameters");
    }
    if (consume(TokenKind::Colon)) {
        function->return_type = parse_type();
    }
    if (consume(TokenKind::Equal)) {
        skip_newlines();
        function->expression_body = parse_expression();
    } else if (at(TokenKind::LeftBrace)) {
        function->body = parse_block();
    }
    function->span = span_from(start.span.begin);
    return function;
}

std::unique_ptr<ast::ClassDeclaration> Parser::parse_class(
    ast::Modifiers modifiers) {
    const auto start = current();
    const auto is_interface = consume(TokenKind::KwInterface);
    if (!is_interface) {
        expect(TokenKind::KwClass, "to declare class");
    }
    auto declaration = std::make_unique<ast::ClassDeclaration>(start.span);
    declaration->modifiers = std::move(modifiers);
    declaration->is_interface = is_interface;
    const auto name = expect(TokenKind::Identifier, "as class name");
    declaration->name = text(name);
    if (at(TokenKind::Less)) {
        declaration->type_parameters = parse_type_parameters();
    }

    if (consume(TokenKind::KwConstructor)) {
        // The keyword is intentionally optional, matching the prototype.
    }
    if (at(TokenKind::LeftParen)) {
        consume(TokenKind::LeftParen);
        skip_newlines();
        while (!at(TokenKind::RightParen) && !at_end()) {
            declaration->constructor_parameters.push_back(parse_parameter(true));
            skip_newlines();
            if (!consume(TokenKind::Comma)) {
                break;
            }
            skip_newlines();
        }
        expect(TokenKind::RightParen, "after constructor parameters");
    }
    if (at(TokenKind::LeftBrace)) {
        declaration->body = parse_block();
    }
    declaration->span = span_from(start.span.begin);
    return declaration;
}

std::unique_ptr<ast::PropertyDeclaration> Parser::parse_property(
    ast::Modifiers modifiers) {
    const auto start = current();
    const auto is_mutable = consume(TokenKind::KwVar);
    if (!is_mutable) {
        expect(TokenKind::KwVal, "to declare property");
    }
    auto property = std::make_unique<ast::PropertyDeclaration>(start.span);
    property->modifiers = std::move(modifiers);
    property->mutable_value = is_mutable;
    const auto name = expect(TokenKind::Identifier, "as property name");
    property->name = text(name);
    if (consume(TokenKind::Colon)) {
        property->type = parse_type();
    }
    if (consume(TokenKind::Equal)) {
        skip_newlines();
        property->initializer = parse_expression();
    }
    property->span = span_from(start.span.begin);
    return property;
}

std::unique_ptr<ast::WhileStatement> Parser::parse_while() {
    const auto start = expect(TokenKind::KwWhile, "to begin loop");
    auto loop = std::make_unique<ast::WhileStatement>(start.span, false);
    expect(TokenKind::LeftParen, "after 'while'");
    skip_newlines();
    loop->condition = parse_expression();
    skip_newlines();
    expect(TokenKind::RightParen, "after loop condition");
    skip_newlines();
    loop->body = parse_control_body();
    loop->span = span_from(start.span.begin);
    return loop;
}

std::unique_ptr<ast::WhileStatement> Parser::parse_do_while() {
    const auto start = expect(TokenKind::KwDo, "to begin do-while loop");
    auto loop = std::make_unique<ast::WhileStatement>(start.span, true);
    skip_newlines();
    loop->body = parse_control_body();
    skip_newlines();
    expect(TokenKind::KwWhile, "after do-while body");
    expect(TokenKind::LeftParen, "after 'while'");
    loop->condition = parse_expression();
    expect(TokenKind::RightParen, "after loop condition");
    loop->span = span_from(start.span.begin);
    return loop;
}

std::unique_ptr<ast::Block> Parser::parse_block() {
    const auto start = expect(TokenKind::LeftBrace, "to begin block");
    auto block = std::make_unique<ast::Block>(start.span);
    skip_separators();
    while (!at(TokenKind::RightBrace) && !at_end()) {
        const auto before = position_;
        if (auto statement = parse_statement()) {
            block->statements.push_back(std::move(statement));
        }
        if (before == position_) {
            ++position_;
        }
        require_statement_boundary();
        skip_separators();
    }
    const auto end = expect(TokenKind::RightBrace, "to end block");
    block->span = {start.span.begin, end.span.end};
    return block;
}

std::unique_ptr<ast::Block> Parser::parse_control_body() {
    if (at(TokenKind::LeftBrace)) {
        return parse_block();
    }
    const auto begin = current().span.begin;
    auto block = std::make_unique<ast::Block>(current().span);
    if (auto statement = parse_statement()) {
        block->span = {begin, statement->span.end};
        block->statements.push_back(std::move(statement));
    }
    return block;
}

ast::Parameter Parser::parse_parameter(bool constructor) {
    const auto begin = current().span.begin;
    auto modifiers = parse_modifiers();
    std::optional<bool> property_mutability;
    if (constructor && (at(TokenKind::KwVal) || at(TokenKind::KwVar))) {
        property_mutability = at(TokenKind::KwVar);
        ++position_;
    }
    if (!constructor && consume(TokenKind::KwVar)) {
        modifiers.values.push_back(ast::Modifier::MutableBorrow);
    }
    const auto name = expect(TokenKind::Identifier, "as parameter name");
    expect(TokenKind::Colon, "after parameter name");
    auto type = parse_type();
    ast::ExprPtr default_value;
    if (consume(TokenKind::Equal)) {
        default_value = parse_expression();
    }
    return ast::Parameter{
        span_from(begin),
        text(name),
        std::move(type),
        std::move(default_value),
        property_mutability,
        std::move(modifiers)};
}

std::vector<ast::TypeParameter> Parser::parse_type_parameters() {
    std::vector<ast::TypeParameter> result;
    expect(TokenKind::Less, "to begin type parameters");
    skip_newlines();
    while (!at(TokenKind::Greater) && !at_end()) {
        const auto begin = current().span.begin;
        const auto name = expect(TokenKind::Identifier, "as type parameter name");
        std::optional<ast::TypeSyntax> constraint;
        if (consume(TokenKind::Colon)) {
            constraint = parse_type();
        }
        result.push_back(ast::TypeParameter{
            span_from(begin),
            text(name),
            std::move(constraint)});
        skip_newlines();
        if (!consume(TokenKind::Comma)) {
            break;
        }
        skip_newlines();
    }
    expect(TokenKind::Greater, "after type parameters");
    return result;
}

ast::TypeSyntax Parser::parse_type() {
    const auto begin = current().span.begin;
    auto result = parse_named_or_function_type();
    if (consume(TokenKind::Question)) {
        result.nullable = true;
    }
    while (consume(TokenKind::Star)) {
        ++result.pointer_depth;
    }
    result.span = span_from(begin);
    return result;
}

ast::TypeSyntax Parser::parse_named_or_function_type() {
    const auto begin = current().span.begin;
    if (consume(TokenKind::LeftParen)) {
        std::vector<ast::TypeSyntax> parameters;
        std::vector<ast::ParameterMode> parameter_modes;
        skip_newlines();
        while (!at(TokenKind::RightParen) && !at_end()) {
            auto mode = ast::ParameterMode::Borrow;
            if (consume(TokenKind::KwOwn)) {
                expect(TokenKind::Colon, "after 'own' in function type");
                mode = ast::ParameterMode::Own;
            } else if (consume(TokenKind::KwVar)) {
                expect(TokenKind::Colon, "after 'var' in function type");
                mode = ast::ParameterMode::MutableBorrow;
            } else if (at(TokenKind::Identifier) &&
                position_ + 1 < tokens_.size() &&
                tokens_[position_ + 1].kind == TokenKind::Colon) {
                position_ += 2;
            }
            parameters.push_back(parse_type());
            parameter_modes.push_back(mode);
            skip_newlines();
            if (!consume(TokenKind::Comma)) {
                break;
            }
            skip_newlines();
        }
        expect(TokenKind::RightParen, "after function type parameters");
        if (consume(TokenKind::Arrow)) {
            ast::TypeSyntax function;
            function.span = span_from(begin);
            function.name = "<function>";
            function.parameter_types = std::move(parameters);
            function.parameter_modes = std::move(parameter_modes);
            function.return_type = std::make_unique<ast::TypeSyntax>(parse_type());
            function.span.end = function.return_type->span.end;
            return function;
        }
        if (parameters.size() == 1) {
            auto parenthesized = std::move(parameters.front());
            parenthesized.span = span_from(begin);
            return parenthesized;
        }
        diagnostics_.error(
            span_from(begin),
            "parenthesized type must contain exactly one type or form a function type");
        ast::TypeSyntax invalid;
        invalid.span = span_from(begin);
        invalid.name = "<invalid>";
        return invalid;
    }

    const auto name = expect(TokenKind::Identifier, "as type name");
    ast::TypeSyntax result;
    result.span = name.span;
    result.name = text(name);
    if (consume(TokenKind::Less)) {
        skip_newlines();
        while (!at(TokenKind::Greater) && !at_end()) {
            result.arguments.push_back(parse_type());
            skip_newlines();
            if (!consume(TokenKind::Comma)) {
                break;
            }
            skip_newlines();
        }
        expect(TokenKind::Greater, "after type arguments");
    }

    while (at(TokenKind::Dot)) {
        const auto dot_position = position_;
        consume(TokenKind::Dot);
        if (at(TokenKind::LeftParen)) {
            auto receiver = std::make_unique<ast::TypeSyntax>(std::move(result));
            consume(TokenKind::LeftParen);
            std::vector<ast::TypeSyntax> parameters;
            skip_newlines();
            while (!at(TokenKind::RightParen) && !at_end()) {
                parameters.push_back(parse_type());
                if (!consume(TokenKind::Comma)) {
                    break;
                }
                skip_newlines();
            }
            expect(TokenKind::RightParen, "after function type parameters");
            expect(TokenKind::Arrow, "in receiver function type");
            ast::TypeSyntax function;
            function.name = "<function>";
            function.span = span_from(begin);
            function.receiver = std::move(receiver);
            function.parameter_types = std::move(parameters);
            function.return_type = std::make_unique<ast::TypeSyntax>(parse_type());
            function.span.end = function.return_type->span.end;
            return function;
        }
        if (!at(TokenKind::Identifier)) {
            position_ = dot_position;
            break;
        }
        result.name += '.';
        result.name += text(current());
        ++position_;
    }
    result.span = span_from(begin);
    return result;
}

ast::ExprPtr Parser::parse_expression() {
    return parse_assignment();
}

ast::ExprPtr Parser::parse_assignment() {
    auto left = parse_logical_or();
    if (!left || !consume(TokenKind::Equal)) {
        return left;
    }
    const auto operation = previous();
    skip_newlines();
    auto right = parse_assignment();
    const auto end = right ? right->span.end : operation.span.end;
    return std::make_unique<ast::BinaryExpression>(
        ast::Expression::Kind::Assignment,
        SourceSpan{left->span.begin, end},
        TokenKind::Equal,
        std::move(left),
        std::move(right));
}

ast::ExprPtr Parser::parse_logical_or() {
    return parse_binary(&Parser::parse_logical_and, {TokenKind::PipePipe});
}

ast::ExprPtr Parser::parse_logical_and() {
    return parse_binary(&Parser::parse_equality, {TokenKind::AmpAmp});
}

ast::ExprPtr Parser::parse_equality() {
    return parse_binary(
        &Parser::parse_comparison,
        {TokenKind::EqualEqual, TokenKind::BangEqual});
}

ast::ExprPtr Parser::parse_comparison() {
    return parse_binary(
        &Parser::parse_term,
        {TokenKind::Less, TokenKind::LessEqual, TokenKind::Greater, TokenKind::GreaterEqual});
}

ast::ExprPtr Parser::parse_term() {
    return parse_binary(&Parser::parse_factor, {TokenKind::Plus, TokenKind::Minus});
}

ast::ExprPtr Parser::parse_factor() {
    return parse_binary(&Parser::parse_unary, {TokenKind::Star, TokenKind::Slash});
}

ast::ExprPtr Parser::parse_binary(
    ast::ExprPtr (Parser::*operand)(),
    std::initializer_list<TokenKind> operators) {
    auto expression = (this->*operand)();
    while (expression && is_any(operators)) {
        const auto operation = current();
        ++position_;
        skip_newlines();
        auto right = (this->*operand)();
        if (!right) {
            diagnostics_.error(operation.span, "expected expression after operator");
            return expression;
        }
        expression = std::make_unique<ast::BinaryExpression>(
            ast::Expression::Kind::Binary,
            SourceSpan{expression->span.begin, right->span.end},
            operation.kind,
            std::move(expression),
            std::move(right));
    }
    return expression;
}

ast::ExprPtr Parser::parse_unary() {
    if (is_any({TokenKind::Minus, TokenKind::Plus, TokenKind::Bang, TokenKind::Hash})) {
        const auto operation = current();
        ++position_;
        auto operand = parse_unary();
        const auto end = operand ? operand->span.end : operation.span.end;
        return std::make_unique<ast::UnaryExpression>(
            operation.kind == TokenKind::Hash
                ? ast::Expression::Kind::Compile
                : ast::Expression::Kind::Unary,
            SourceSpan{operation.span.begin, end},
            operation.kind,
            std::move(operand));
    }
    return parse_postfix();
}

ast::ExprPtr Parser::parse_postfix() {
    auto expression = parse_primary();
    while (expression) {
        std::vector<ast::TypeSyntax> type_arguments;
        if (at(TokenKind::Less)) {
            auto possible = try_parse_call_type_arguments();
            if (possible) {
                type_arguments = std::move(*possible);
            }
        }

        if (at(TokenKind::LeftParen)) {
            auto call = std::make_unique<ast::CallExpression>(
                expression->span,
                std::move(expression));
            call->type_arguments = std::move(type_arguments);
            call->arguments = parse_arguments();
            call->span.end = previous().span.end;
            expression = std::move(call);
            continue;
        }
        if (!type_arguments.empty()) {
            diagnostics_.error(
                current().span,
                "type arguments in an expression must be followed by a call");
        }
        if (consume(TokenKind::Dot)) {
            const auto member = expect(TokenKind::Identifier, "after '.'");
            expression = std::make_unique<ast::MemberExpression>(
                SourceSpan{expression->span.begin, member.span.end},
                std::move(expression),
                text(member));
            continue;
        }
        if (consume(TokenKind::LeftBracket)) {
            auto index = parse_expression();
            const auto close = expect(TokenKind::RightBracket, "after index");
            expression = std::make_unique<ast::IndexExpression>(
                SourceSpan{expression->span.begin, close.span.end},
                std::move(expression),
                std::move(index));
            continue;
        }
        if (at(TokenKind::LeftBrace)) {
            auto lambda = parse_lambda();
            auto call = expression->kind == ast::Expression::Kind::Call
                ? std::unique_ptr<ast::CallExpression>(
                    static_cast<ast::CallExpression*>(expression.release()))
                : std::make_unique<ast::CallExpression>(
                    expression->span,
                    std::move(expression));
            const auto span = lambda->span;
            call->arguments.push_back(ast::Argument{span, std::nullopt, std::move(lambda)});
            call->span.end = span.end;
            expression = std::move(call);
            continue;
        }
        break;
    }
    return expression;
}

ast::ExprPtr Parser::parse_primary() {
    const auto token = current();
    if (at(TokenKind::Dollar)) {
        return parse_subparser();
    }
    if (consume(TokenKind::Identifier)) {
        return std::make_unique<ast::ScalarExpression>(
            ast::Expression::Kind::Identifier,
            token.span,
            text(token));
    }
    if (consume(TokenKind::Integer) || consume(TokenKind::HexInteger)) {
        return std::make_unique<ast::ScalarExpression>(
            ast::Expression::Kind::Integer,
            token.span,
            text(token));
    }
    if (consume(TokenKind::KwTrue) || consume(TokenKind::KwFalse)) {
        return std::make_unique<ast::ScalarExpression>(
            ast::Expression::Kind::Boolean,
            token.span,
            text(token));
    }
    if (consume(TokenKind::KwNull)) {
        return std::make_unique<ast::ScalarExpression>(
            ast::Expression::Kind::Null,
            token.span,
            "null");
    }
    if (at(TokenKind::StringStart)) {
        return parse_string();
    }
    if (consume(TokenKind::LeftParen)) {
        skip_newlines();
        auto expression = parse_expression();
        skip_newlines();
        const auto close = expect(TokenKind::RightParen, "after expression");
        if (expression) {
            expression->span = {token.span.begin, close.span.end};
        }
        return expression;
    }
    if (at(TokenKind::LeftBracket)) {
        const auto start = current();
        ++position_;
        auto array = std::make_unique<ast::ArrayExpression>(start.span);
        skip_newlines();
        while (!at(TokenKind::RightBracket) && !at_end()) {
            array->elements.push_back(parse_expression());
            skip_newlines();
            if (!consume(TokenKind::Comma)) {
                break;
            }
            skip_newlines();
        }
        const auto close = expect(TokenKind::RightBracket, "after array literal");
        array->span.end = close.span.end;
        return array;
    }
    if (at(TokenKind::LeftBrace)) {
        return parse_lambda();
    }
    if (at(TokenKind::KwIf)) {
        return parse_if();
    }
    if (at(TokenKind::KwWhen)) {
        return parse_when();
    }

    diagnostics_.error(
        token.span,
        "expected expression, found " + std::string(token_kind_name(token.kind)));
    if (!at_end()) {
        ++position_;
    }
    return nullptr;
}

ast::ExprPtr Parser::parse_subparser() {
    const auto start = expect(TokenKind::Dollar, "to invoke a subparser");
    const auto name_token = expect(TokenKind::Identifier, "as subparser name");
    const auto name = text(name_token);
    if (subparsers_ == nullptr) {
        if (defer_unknown_subparsers_) throw MissingSubparser{name};
        diagnostics_.error(
            {start.span.begin, name_token.span.end},
            "subparser '" + name + "' is not registered");
        return nullptr;
    }
    const auto* handler = subparsers_->find(name);
    if (handler == nullptr) {
        if (defer_unknown_subparsers_) throw MissingSubparser{name};
        diagnostics_.error(
            {start.span.begin, name_token.span.end},
            "unknown subparser '" + name + "'");
        return nullptr;
    }
    constexpr std::size_t max_subparser_depth = 64;
    if (subparser_stack_.size() >= max_subparser_depth) {
        diagnostics_.error(
            {start.span.begin, name_token.span.end},
            "subparser nesting limit exceeded");
        return nullptr;
    }
    subparser_stack_.push_back(name);
    struct StackGuard {
        std::vector<std::string>& stack;
        ~StackGuard() { stack.pop_back(); }
    } guard{subparser_stack_};
    SubparserContext context(
        *this,
        {start.span.begin, name_token.span.end},
        name,
        current().span.begin);
    auto expression = (*handler)(context);
    context.finish();
    if (!expression) {
        diagnostics_.error(
            {start.span.begin, name_token.span.end},
            "subparser '" + name + "' did not return an expression");
        return nullptr;
    }
    expression->span.begin = start.span.begin;
    expression->span.end = std::max(expression->span.end, previous().span.end);
    return expression;
}

ast::ExprPtr Parser::parse_string() {
    const auto start = expect(TokenKind::StringStart, "to begin string");
    auto string = std::make_unique<ast::StringExpression>(start.span);
    while (!at(TokenKind::StringEnd) && !at_end()) {
        const auto token = current();
        if (consume(TokenKind::StringText)) {
            string->parts.push_back(std::make_unique<ast::ScalarExpression>(
                ast::Expression::Kind::StringText,
                token.span,
                decode_string_text(text(token))));
        } else if (consume(TokenKind::InterpolationIdentifier)) {
            auto name = text(token);
            string->parts.push_back(std::make_unique<ast::ScalarExpression>(
                ast::Expression::Kind::Identifier,
                token.span,
                name.substr(1)));
        } else if (consume(TokenKind::InterpolationStart)) {
            skip_newlines();
            auto expression = parse_expression();
            skip_newlines();
            expect(TokenKind::InterpolationEnd, "after interpolated expression");
            if (expression) {
                string->parts.push_back(std::move(expression));
            }
        } else {
            diagnostics_.error(token.span, "unexpected token in string literal");
            ++position_;
        }
    }
    const auto close = expect(TokenKind::StringEnd, "to end string");
    string->span.end = close.span.end;
    return string;
}

ast::ExprPtr Parser::parse_if() {
    const auto start = expect(TokenKind::KwIf, "to begin if expression");
    auto expression = std::make_unique<ast::IfExpression>(start.span);
    expect(TokenKind::LeftParen, "after 'if'");
    skip_newlines();
    expression->condition = parse_expression();
    skip_newlines();
    expect(TokenKind::RightParen, "after if condition");
    skip_newlines();
    expression->then_body = parse_control_body();

    const auto before_newlines = position_;
    skip_newlines();
    if (consume(TokenKind::KwElse)) {
        skip_newlines();
        expression->else_body = parse_control_body();
    } else {
        position_ = before_newlines;
    }
    expression->span = span_from(start.span.begin);
    return expression;
}

ast::ExprPtr Parser::parse_when() {
    const auto start = expect(TokenKind::KwWhen, "to begin when expression");
    auto expression = std::make_unique<ast::WhenExpression>(start.span);
    if (consume(TokenKind::LeftParen)) {
        expression->subject = parse_expression();
        expect(TokenKind::RightParen, "after when subject");
    }
    expect(TokenKind::LeftBrace, "to begin when cases");
    skip_separators();
    while (!at(TokenKind::RightBrace) && !at_end()) {
        const auto case_begin = current().span.begin;
        ast::WhenExpression::Case when_case;
        when_case.span = current().span;
        when_case.is_else = consume(TokenKind::KwElse);
        if (!when_case.is_else) {
            do {
                when_case.matches.push_back(parse_expression());
            } while (consume(TokenKind::Comma));
        }
        expect(TokenKind::Arrow, "after when case");
        skip_newlines();
        when_case.body = parse_control_body();
        when_case.span = span_from(case_begin);
        expression->cases.push_back(std::move(when_case));
        skip_separators();
    }
    const auto close = expect(TokenKind::RightBrace, "after when cases");
    expression->span = {start.span.begin, close.span.end};
    return expression;
}

ast::ExprPtr Parser::parse_lambda() {
    const auto start = expect(TokenKind::LeftBrace, "to begin lambda");
    auto lambda = std::make_unique<ast::LambdaExpression>(start.span);
    lambda->body = std::make_unique<ast::Block>(start.span);
    skip_separators();

    const auto parameter_start = position_;
    std::vector<ast::LambdaExpression::Parameter> parameters;
    if (at(TokenKind::Identifier)) {
        bool valid = true;
        while (valid) {
            const auto name = current();
            ++position_;
            std::optional<ast::TypeSyntax> type;
            if (consume(TokenKind::Colon)) {
                type = parse_type();
            }
            parameters.push_back({
                span_from(name.span.begin),
                text(name),
                std::move(type)});
            if (!consume(TokenKind::Comma)) {
                break;
            }
            skip_newlines();
            valid = at(TokenKind::Identifier);
        }
        if (valid && consume(TokenKind::Arrow)) {
            lambda->parameters = std::move(parameters);
            skip_separators();
        } else {
            position_ = parameter_start;
        }
    }

    while (!at(TokenKind::RightBrace) && !at_end()) {
        if (auto statement = parse_statement()) {
            lambda->body->statements.push_back(std::move(statement));
        }
        require_statement_boundary();
        skip_separators();
    }
    const auto close = expect(TokenKind::RightBrace, "to end lambda");
    lambda->body->span = {start.span.begin, close.span.end};
    lambda->span = lambda->body->span;
    return lambda;
}

std::vector<ast::Argument> Parser::parse_arguments() {
    std::vector<ast::Argument> arguments;
    expect(TokenKind::LeftParen, "to begin arguments");
    skip_newlines();
    while (!at(TokenKind::RightParen) && !at_end()) {
        const auto begin = current().span.begin;
        std::optional<std::string> name;
        if (at(TokenKind::Identifier) &&
            position_ + 1 < tokens_.size() &&
            tokens_[position_ + 1].kind == TokenKind::Equal) {
            name = text(current());
            position_ += 2;
        }
        auto value = parse_expression();
        arguments.push_back(ast::Argument{
            span_from(begin),
            std::move(name),
            std::move(value)});
        skip_newlines();
        if (!consume(TokenKind::Comma)) {
            break;
        }
        skip_newlines();
    }
    expect(TokenKind::RightParen, "after arguments");
    return arguments;
}

std::optional<std::vector<ast::TypeSyntax>> Parser::try_parse_call_type_arguments() {
    // Avoid treating comparison operators as generic calls. We only commit
    // when the balanced closing '>' is immediately followed by '('.
    std::size_t scan = position_;
    std::size_t depth = 0;
    bool valid = false;
    for (; scan < tokens_.size(); ++scan) {
        if (tokens_[scan].kind == TokenKind::Newline) {
            return std::nullopt;
        }
        if (tokens_[scan].kind == TokenKind::Less) {
            ++depth;
        } else if (tokens_[scan].kind == TokenKind::Greater) {
            if (depth == 0) {
                return std::nullopt;
            }
            --depth;
            if (depth == 0) {
                valid = scan + 1 < tokens_.size() &&
                    tokens_[scan + 1].kind == TokenKind::LeftParen;
                break;
            }
        }
    }
    if (!valid) {
        return std::nullopt;
    }

    std::vector<ast::TypeSyntax> result;
    expect(TokenKind::Less, "to begin call type arguments");
    do {
        result.push_back(parse_type());
    } while (consume(TokenKind::Comma));
    expect(TokenKind::Greater, "after call type arguments");
    return result;
}

bool Parser::is_any(std::initializer_list<TokenKind> kinds) const {
    return std::find(kinds.begin(), kinds.end(), current().kind) != kinds.end();
}

bool Parser::at(TokenKind kind) const {
    return current().kind == kind;
}

bool Parser::at_end() const {
    return at(TokenKind::End);
}

bool Parser::consume(TokenKind kind) {
    if (!at(kind)) {
        return false;
    }
    ++position_;
    return true;
}

Token Parser::expect(TokenKind kind, const char* context) {
    if (at(kind)) {
        return tokens_[position_++];
    }
    diagnostics_.error(
        current().span,
        "expected " + std::string(token_kind_name(kind)) + ' ' + context +
            ", found " + std::string(token_kind_name(current().kind)));
    return Token{kind, {current().span.begin, current().span.begin}};
}

const Token& Parser::current() const {
    return tokens_[std::min(position_, tokens_.size() - 1)];
}

const Token& Parser::previous() const {
    return tokens_[position_ == 0 ? 0 : position_ - 1];
}

std::string Parser::text(const Token& token) const {
    return std::string(source_.slice(token.span));
}

void Parser::skip_separators() {
    while (at(TokenKind::Newline) || at(TokenKind::Semicolon)) {
        ++position_;
    }
}

void Parser::skip_newlines() {
    while (at(TokenKind::Newline)) {
        ++position_;
    }
}

void Parser::require_statement_boundary() {
    if (at(TokenKind::Newline) || at(TokenKind::Semicolon) ||
        at(TokenKind::RightBrace) || at(TokenKind::End)) {
        return;
    }
    diagnostics_.error(
        current().span,
        "expected a newline or ';' between statements");
    synchronize();
}

void Parser::synchronize() {
    while (!at_end() && !at(TokenKind::Newline) &&
           !at(TokenKind::Semicolon) && !at(TokenKind::RightBrace)) {
        ++position_;
    }
}

SourceSpan Parser::span_from(std::size_t begin) const {
    return SourceSpan{begin, previous().span.end};
}

} // namespace abla
