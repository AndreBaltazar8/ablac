#include "abla/subparser.hpp"

#include "abla/parser.hpp"
#include "abla/vm.hpp"

#include <algorithm>
#include <cctype>
#include <stdexcept>
#include <utility>
#include <vector>

namespace abla {

bool SubparserContext::at(TokenKind kind) const {
    return parser_.at(kind);
}

bool SubparserContext::consume(TokenKind kind) {
    return parser_.consume(kind);
}

Token SubparserContext::expect(TokenKind kind, const char* context) {
    return parser_.expect(kind, context);
}

Token SubparserContext::current() const {
    return parser_.current();
}

Token SubparserContext::peek(std::size_t lookahead) const {
    const auto position = std::min(
        parser_.position_ + lookahead,
        parser_.tokens_.size() - 1);
    return parser_.tokens_[position];
}

std::string SubparserContext::text(const Token& token) const {
    return parser_.text(token);
}

std::string SubparserContext::slice(SourceSpan span) const {
    return std::string(parser_.source_.slice(span));
}

ast::ExprPtr SubparserContext::parse_abla_expression() {
    synchronize_token_cursor();
    auto expression = parser_.parse_expression();
    raw_offset_ = parser_.current().span.begin;
    return expression;
}

bool SubparserContext::raw_at(std::string_view expected) const {
    const auto source = parser_.source_.text();
    return raw_offset_ <= source.size() &&
        expected.size() <= source.size() - raw_offset_ &&
        source.compare(raw_offset_, expected.size(), expected) == 0;
}

bool SubparserContext::raw_consume(std::string_view expected) {
    used_raw_cursor_ = true;
    if (!raw_at(expected)) return false;
    raw_offset_ += expected.size();
    return true;
}

void SubparserContext::raw_expect(std::string_view expected) {
    if (raw_consume(expected)) return;
    const auto end = std::min(
        parser_.source_.text().size(),
        raw_offset_ + std::max<std::size_t>(expected.size(), 1));
    error(
        {raw_offset_, end},
        "subparser '" + name_ + "' expected raw text '" +
            std::string(expected) + "'");
}

std::string SubparserContext::raw_take_until(std::string_view delimiters) {
    used_raw_cursor_ = true;
    const auto source = parser_.source_.text();
    const auto begin = raw_offset_;
    while (raw_offset_ < source.size() &&
           delimiters.find(source[raw_offset_]) == std::string_view::npos) {
        ++raw_offset_;
    }
    return std::string(source.substr(begin, raw_offset_ - begin));
}

std::string SubparserContext::raw_take_name() {
    used_raw_cursor_ = true;
    const auto source = parser_.source_.text();
    const auto begin = raw_offset_;
    while (raw_offset_ < source.size()) {
        const auto byte = static_cast<unsigned char>(source[raw_offset_]);
        const auto character = source[raw_offset_];
        if (std::isalnum(byte) == 0 && character != '_' && character != '-' &&
            character != ':') {
            break;
        }
        ++raw_offset_;
    }
    if (begin == raw_offset_) {
        error(
            {raw_offset_, std::min(raw_offset_ + 1, source.size())},
            "subparser '" + name_ + "' expected a raw name");
    }
    return std::string(source.substr(begin, raw_offset_ - begin));
}

void SubparserContext::raw_skip_whitespace() {
    used_raw_cursor_ = true;
    const auto source = parser_.source_.text();
    while (raw_offset_ < source.size() &&
           std::isspace(static_cast<unsigned char>(source[raw_offset_])) != 0) {
        ++raw_offset_;
    }
}

bool SubparserContext::raw_end() const noexcept {
    return raw_offset_ >= parser_.source_.text().size();
}

void SubparserContext::synchronize_token_cursor() {
    if (!used_raw_cursor_) return;
    while (parser_.position_ + 1 < parser_.tokens_.size() &&
           parser_.tokens_[parser_.position_].span.end <= raw_offset_) {
        ++parser_.position_;
    }
    const auto token = parser_.tokens_[parser_.position_];
    if (token.span.begin < raw_offset_ && raw_offset_ < token.span.end) {
        error(
            {raw_offset_, raw_offset_},
            "raw parser cursor is not at an Abla token boundary");
    }
}

void SubparserContext::finish() {
    synchronize_token_cursor();
}

void SubparserContext::error(SourceSpan span, std::string message) {
    parser_.diagnostics_.error(span, std::move(message));
}

bool SubparserRegistry::add(std::string name, Handler handler) {
    if (name.empty() || !handler) return false;
    return handlers_.emplace(std::move(name), std::move(handler)).second;
}

const SubparserRegistry::Handler* SubparserRegistry::find(
    std::string_view name) const {
    const auto found = handlers_.find(std::string(name));
    return found == handlers_.end() ? nullptr : &found->second;
}

namespace {

ast::ExprPtr identifier(std::string name, SourceSpan span) {
    return std::make_unique<ast::ScalarExpression>(
        ast::Expression::Kind::Identifier, span, std::move(name));
}

ast::ExprPtr string(std::string value, SourceSpan span) {
    auto result = std::make_unique<ast::StringExpression>(span);
    if (!value.empty()) {
        result->parts.push_back(std::make_unique<ast::ScalarExpression>(
            ast::Expression::Kind::StringText, span, std::move(value)));
    }
    return result;
}

} // namespace

const SubparserRegistry& bootstrap_subparsers() {
    static const SubparserRegistry registry;
    return registry;
}

bool add_compiled_subparser(
    SubparserRegistry& registry,
    std::string name,
    std::shared_ptr<const ir::Program> program,
    std::shared_ptr<const sema::TypeStore> types,
    ir::FunctionId function) {
    if (!program || !types || function >= program->functions.size()) return false;
    return registry.add(
        std::move(name),
        [program = std::move(program),
         types = std::move(types),
         function](SubparserContext& context) mutable -> ast::ExprPtr {
            std::vector<ast::ExprPtr> syntax;
            vm::NativeRegistry natives;
            const auto require_cursor = [](const std::vector<vm::Value>& arguments) {
                if (arguments.empty()) return false;
                const auto* host = std::get_if<vm::HostValue>(&arguments[0].storage());
                return host != nullptr &&
                    host->kind == vm::HostValue::Kind::ParserCursor &&
                    host->handle == 1;
            };
            const auto token_for = [](std::string_view spelling) -> std::optional<TokenKind> {
                if (spelling == "{") return TokenKind::LeftBrace;
                if (spelling == "}") return TokenKind::RightBrace;
                if (spelling == "[") return TokenKind::LeftBracket;
                if (spelling == "]") return TokenKind::RightBracket;
                if (spelling == "(") return TokenKind::LeftParen;
                if (spelling == ")") return TokenKind::RightParen;
                if (spelling == "<") return TokenKind::Less;
                if (spelling == ">") return TokenKind::Greater;
                if (spelling == ",") return TokenKind::Comma;
                if (spelling == ":") return TokenKind::Colon;
                if (spelling == "-") return TokenKind::Minus;
                if (spelling == "identifier") return TokenKind::Identifier;
                if (spelling == "integer") return TokenKind::Integer;
                if (spelling == "string") return TokenKind::StringStart;
                if (spelling == "true") return TokenKind::KwTrue;
                if (spelling == "false") return TokenKind::KwFalse;
                if (spelling == "null") return TokenKind::KwNull;
                if (spelling == "end") return TokenKind::End;
                return std::nullopt;
            };
            const auto store_syntax = [&syntax](ast::ExprPtr expression) {
                if (!expression) throw std::runtime_error("cannot store null syntax");
                syntax.push_back(std::move(expression));
                return vm::Value::host(
                    vm::HostValue::Kind::SyntaxExpression,
                    static_cast<std::uint64_t>(syntax.size()));
            };
            const auto take_syntax = [&syntax](const vm::Value& value) {
                const auto* host = std::get_if<vm::HostValue>(&value.storage());
                if (host == nullptr ||
                    host->kind != vm::HostValue::Kind::SyntaxExpression ||
                    host->handle == 0 || host->handle > syntax.size()) {
                    throw std::runtime_error("invalid syntax expression handle");
                }
                auto& expression = syntax[static_cast<std::size_t>(host->handle - 1)];
                if (!expression) throw std::runtime_error("syntax handle was already consumed");
                return std::move(expression);
            };
            natives.add(
                "parser",
                "parserExpect",
                [&context, require_cursor, token_for](
                    const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 2) {
                        throw std::runtime_error("parserExpect received invalid arguments");
                    }
                    const auto& spelling = arguments[1].as_string();
                    const auto token = token_for(spelling);
                    if (!token) throw std::runtime_error("unsupported parser token spelling");
                    context.expect(*token, "requested by compile-time subparser");
                    return vm::Value::void_value();
                });
            natives.add(
                "parser",
                "parserAt",
                [&context, require_cursor, token_for](
                    const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 2) {
                        throw std::runtime_error("parserAt received invalid arguments");
                    }
                    const auto token = token_for(arguments[1].as_string());
                    if (!token) throw std::runtime_error("unsupported parser token spelling");
                    return vm::Value::boolean(context.at(*token));
                });
            natives.add(
                "parser",
                "parserConsume",
                [&context, require_cursor, token_for](
                    const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 2) {
                        throw std::runtime_error("parserConsume received invalid arguments");
                    }
                    const auto token = token_for(arguments[1].as_string());
                    if (!token) throw std::runtime_error("unsupported parser token spelling");
                    return vm::Value::boolean(context.consume(*token));
                });
            natives.add(
                "parser",
                "parserCurrentText",
                [&context, require_cursor](const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 1) {
                        throw std::runtime_error(
                            "parserCurrentText received invalid arguments");
                    }
                    return vm::Value::string(context.text(context.current()));
                });
            natives.add(
                "parser",
                "parserRawAt",
                [&context, require_cursor](const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 2) {
                        throw std::runtime_error("parserRawAt received invalid arguments");
                    }
                    return vm::Value::boolean(context.raw_at(arguments[1].as_string()));
                });
            natives.add(
                "parser",
                "parserRawConsume",
                [&context, require_cursor](const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 2) {
                        throw std::runtime_error(
                            "parserRawConsume received invalid arguments");
                    }
                    return vm::Value::boolean(
                        context.raw_consume(arguments[1].as_string()));
                });
            natives.add(
                "parser",
                "parserRawExpect",
                [&context, require_cursor](const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 2) {
                        throw std::runtime_error(
                            "parserRawExpect received invalid arguments");
                    }
                    context.raw_expect(arguments[1].as_string());
                    return vm::Value::void_value();
                });
            natives.add(
                "parser",
                "parserRawTakeUntil",
                [&context, require_cursor](const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 2) {
                        throw std::runtime_error(
                            "parserRawTakeUntil received invalid arguments");
                    }
                    return vm::Value::string(
                        context.raw_take_until(arguments[1].as_string()));
                });
            natives.add(
                "parser",
                "parserRawTakeName",
                [&context, require_cursor](const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 1) {
                        throw std::runtime_error(
                            "parserRawTakeName received invalid arguments");
                    }
                    return vm::Value::string(context.raw_take_name());
                });
            natives.add(
                "parser",
                "parserRawSkipWhitespace",
                [&context, require_cursor](const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 1) {
                        throw std::runtime_error(
                            "parserRawSkipWhitespace received invalid arguments");
                    }
                    context.raw_skip_whitespace();
                    return vm::Value::void_value();
                });
            natives.add(
                "parser",
                "parserRawEnd",
                [&context, require_cursor](const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 1) {
                        throw std::runtime_error("parserRawEnd received invalid arguments");
                    }
                    return vm::Value::boolean(context.raw_end());
                });
            natives.add(
                "parser",
                "parserFail",
                [&context, require_cursor](const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 2) {
                        throw std::runtime_error("parserFail received invalid arguments");
                    }
                    const auto offset = context.raw_offset();
                    context.error({offset, offset}, arguments[1].as_string());
                    return vm::Value::void_value();
                });
            natives.add(
                "parser",
                "parserParseAblaExpression",
                [&context, require_cursor, store_syntax](
                    const std::vector<vm::Value>& arguments) {
                    if (!require_cursor(arguments) || arguments.size() != 1) {
                        throw std::runtime_error(
                            "parserParseAblaExpression received invalid arguments");
                    }
                    return store_syntax(context.parse_abla_expression());
                });
            natives.add(
                "parser",
                "syntaxInteger",
                [&context, store_syntax](const std::vector<vm::Value>& arguments) {
                    if (arguments.size() != 1) {
                        throw std::runtime_error("syntaxInteger received invalid arguments");
                    }
                    return store_syntax(std::make_unique<ast::ScalarExpression>(
                        ast::Expression::Kind::Integer,
                        context.invocation_span(),
                        std::to_string(arguments[0].as_integer())));
                });
            natives.add(
                "parser",
                "syntaxString",
                [&context, store_syntax](const std::vector<vm::Value>& arguments) {
                    if (arguments.size() != 1) {
                        throw std::runtime_error("syntaxString received invalid arguments");
                    }
                    return store_syntax(string(
                        arguments[0].as_string(), context.invocation_span()));
                });
            natives.add(
                "parser",
                "syntaxIdentifier",
                [&context, store_syntax](const std::vector<vm::Value>& arguments) {
                    if (arguments.size() != 1) {
                        throw std::runtime_error(
                            "syntaxIdentifier received invalid arguments");
                    }
                    return store_syntax(identifier(
                        arguments[0].as_string(), context.invocation_span()));
                });
            natives.add(
                "parser",
                "syntaxBinary",
                [&context, store_syntax, take_syntax](
                    const std::vector<vm::Value>& arguments) {
                    if (arguments.size() != 3) {
                        throw std::runtime_error("syntaxBinary received invalid arguments");
                    }
                    const auto& operation = arguments[0].as_string();
                    const auto token = [&]() -> std::optional<TokenKind> {
                        if (operation == "+") return TokenKind::Plus;
                        if (operation == "-") return TokenKind::Minus;
                        if (operation == "*") return TokenKind::Star;
                        if (operation == "/") return TokenKind::Slash;
                        if (operation == "==") return TokenKind::EqualEqual;
                        if (operation == "!=") return TokenKind::BangEqual;
                        if (operation == "<") return TokenKind::Less;
                        if (operation == "<=") return TokenKind::LessEqual;
                        if (operation == ">") return TokenKind::Greater;
                        if (operation == ">=") return TokenKind::GreaterEqual;
                        if (operation == "&&") return TokenKind::AmpAmp;
                        if (operation == "||") return TokenKind::PipePipe;
                        return std::nullopt;
                    }();
                    if (!token) throw std::runtime_error("unsupported syntax binary operator");
                    auto left = take_syntax(arguments[1]);
                    auto right = take_syntax(arguments[2]);
                    return store_syntax(std::make_unique<ast::BinaryExpression>(
                        ast::Expression::Kind::Binary,
                        context.invocation_span(),
                        *token,
                        std::move(left),
                        std::move(right)));
                });
            natives.add(
                "parser",
                "syntaxArray",
                [&context, store_syntax, take_syntax](
                    const std::vector<vm::Value>& arguments) {
                    if (arguments.size() != 1) {
                        throw std::runtime_error("syntaxArray received invalid arguments");
                    }
                    auto result = std::make_unique<ast::ArrayExpression>(
                        context.invocation_span());
                    for (const auto& element : arguments[0].as_array()->elements) {
                        result->elements.push_back(take_syntax(element));
                    }
                    return store_syntax(std::move(result));
                });
            natives.add(
                "parser",
                "syntaxCall",
                [&context, store_syntax, take_syntax](
                    const std::vector<vm::Value>& arguments) {
                    if (arguments.size() != 2) {
                        throw std::runtime_error("syntaxCall received invalid arguments");
                    }
                    auto result = std::make_unique<ast::CallExpression>(
                        context.invocation_span(),
                        identifier(arguments[0].as_string(), context.invocation_span()));
                    for (const auto& value : arguments[1].as_array()->elements) {
                        auto expression = take_syntax(value);
                        const auto span = expression->span;
                        result->arguments.push_back(
                            ast::Argument{span, std::nullopt, std::move(expression)});
                    }
                    return store_syntax(std::move(result));
                });

            Diagnostics diagnostics;
            vm::Machine machine(*program, *types, diagnostics, &natives);
            const auto result = machine.run(
                function,
                {vm::Value::host(vm::HostValue::Kind::ParserCursor, 1)});
            if (diagnostics.has_errors()) {
                for (const auto& diagnostic : diagnostics.entries()) {
                    context.error(
                        context.invocation_span(),
                        "compile-time subparser failed: " + diagnostic.message);
                }
                return nullptr;
            }
            const auto* host = std::get_if<vm::HostValue>(&result.storage());
            if (host == nullptr ||
                host->kind != vm::HostValue::Kind::SyntaxExpression ||
                host->handle == 0 || host->handle > syntax.size()) {
                context.error(
                    context.invocation_span(),
                    "compile-time subparser returned an invalid syntax handle");
                return nullptr;
            }
            return std::move(syntax[static_cast<std::size_t>(host->handle - 1)]);
        });
}

} // namespace abla
