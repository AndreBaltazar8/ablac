#pragma once

#include "abla/ast.hpp"
#include "abla/token.hpp"

#include <functional>
#include <cstddef>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>

namespace abla {

class Parser;
namespace ir {
struct Program;
using FunctionId = std::uint32_t;
}
namespace sema {
class TypeStore;
}

class SubparserContext {
public:
    [[nodiscard]] bool at(TokenKind kind) const;
    bool consume(TokenKind kind);
    Token expect(TokenKind kind, const char* context);
    [[nodiscard]] Token current() const;
    [[nodiscard]] Token peek(std::size_t lookahead) const;
    [[nodiscard]] std::string text(const Token& token) const;
    [[nodiscard]] std::string slice(SourceSpan span) const;
    [[nodiscard]] ast::ExprPtr parse_abla_expression();
    [[nodiscard]] bool raw_at(std::string_view text) const;
    bool raw_consume(std::string_view text);
    void raw_expect(std::string_view text);
    [[nodiscard]] std::string raw_take_until(std::string_view delimiters);
    [[nodiscard]] std::string raw_take_name();
    void raw_skip_whitespace();
    [[nodiscard]] bool raw_end() const noexcept;
    [[nodiscard]] std::size_t raw_offset() const noexcept { return raw_offset_; }
    void error(SourceSpan span, std::string message);
    [[nodiscard]] SourceSpan invocation_span() const noexcept {
        return invocation_span_;
    }
    [[nodiscard]] std::string_view name() const noexcept { return name_; }

private:
    friend class Parser;
    SubparserContext(
        Parser& parser,
        SourceSpan invocation_span,
        std::string name,
        std::size_t raw_offset)
        : parser_(parser),
          invocation_span_(invocation_span),
          name_(std::move(name)),
          raw_offset_(raw_offset) {}
    void synchronize_token_cursor();
    void finish();

    Parser& parser_;
    SourceSpan invocation_span_;
    std::string name_;
    std::size_t raw_offset_{};
    bool used_raw_cursor_{};
};

class SubparserRegistry {
public:
    using Handler = std::function<ast::ExprPtr(SubparserContext&)>;

    [[nodiscard]] bool add(std::string name, Handler handler);
    [[nodiscard]] const Handler* find(std::string_view name) const;

private:
    std::unordered_map<std::string, Handler> handlers_;
};

[[nodiscard]] const SubparserRegistry& bootstrap_subparsers();
[[nodiscard]] bool add_compiled_subparser(
    SubparserRegistry& registry,
    std::string name,
    std::shared_ptr<const ir::Program> program,
    std::shared_ptr<const sema::TypeStore> types,
    ir::FunctionId function);

} // namespace abla
