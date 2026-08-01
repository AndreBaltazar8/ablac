#pragma once

#include "abla/diagnostic.hpp"
#include "abla/source.hpp"
#include "abla/token.hpp"

#include <cstddef>
#include <vector>

namespace abla {

class Lexer {
public:
    Lexer(const SourceFile& source, Diagnostics& diagnostics)
        : source_(source), diagnostics_(diagnostics) {}

    [[nodiscard]] std::vector<Token> tokenize();

private:
    void lex_normal(bool interpolation);
    void lex_string();
    void lex_identifier();
    void lex_number();
    void lex_block_comment();
    void emit(TokenKind kind, std::size_t begin);
    void emit_newline(std::size_t begin, std::size_t end);
    [[nodiscard]] bool at_end() const noexcept;
    [[nodiscard]] char peek(std::size_t lookahead = 0) const noexcept;
    [[nodiscard]] bool consume(char expected) noexcept;

    const SourceFile& source_;
    Diagnostics& diagnostics_;
    std::vector<Token> tokens_;
    std::size_t offset_{};
};

} // namespace abla

