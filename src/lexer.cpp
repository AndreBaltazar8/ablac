#include "abla/lexer.hpp"

#include <cctype>
#include <string_view>
#include <unordered_map>

namespace abla {

namespace {

bool is_identifier_start(char character) {
    const auto byte = static_cast<unsigned char>(character);
    return character == '_' || std::isalpha(byte) != 0;
}

bool is_identifier_continue(char character) {
    const auto byte = static_cast<unsigned char>(character);
    return character == '_' || std::isalnum(byte) != 0;
}

bool is_hex_digit(char character) {
    const auto byte = static_cast<unsigned char>(character);
    return std::isxdigit(byte) != 0;
}

const std::unordered_map<std::string_view, TokenKind> keywords{
    {"abstract", TokenKind::KwAbstract},
    {"class", TokenKind::KwClass},
    {"compile", TokenKind::KwCompile},
    {"constructor", TokenKind::KwConstructor},
    {"do", TokenKind::KwDo},
    {"else", TokenKind::KwElse},
    {"extern", TokenKind::KwExtern},
    {"false", TokenKind::KwFalse},
    {"fun", TokenKind::KwFun},
    {"if", TokenKind::KwIf},
    {"interface", TokenKind::KwInterface},
    {"noescape", TokenKind::KwNoEscape},
    {"null", TokenKind::KwNull},
    {"own", TokenKind::KwOwn},
    {"resource", TokenKind::KwResource},
    {"return", TokenKind::KwReturn},
    {"true", TokenKind::KwTrue},
    {"trusted", TokenKind::KwTrusted},
    {"val", TokenKind::KwVal},
    {"var", TokenKind::KwVar},
    {"when", TokenKind::KwWhen},
    {"while", TokenKind::KwWhile},
};

} // namespace

std::vector<Token> Lexer::tokenize() {
    tokens_.clear();
    offset_ = 0;
    lex_normal(false);
    tokens_.push_back(Token{TokenKind::End, {offset_, offset_}});
    return std::move(tokens_);
}

void Lexer::lex_normal(bool interpolation) {
    std::size_t brace_depth = 0;
    while (!at_end()) {
        const auto begin = offset_;
        const auto character = peek();

        if (character == ' ' || character == '\t' || character == '\f') {
            ++offset_;
            continue;
        }
        if (character == '\n' || character == '\r') {
            ++offset_;
            if (character == '\r' && peek() == '\n') {
                ++offset_;
            }
            emit_newline(begin, offset_);
            continue;
        }
        if (is_identifier_start(character)) {
            lex_identifier();
            continue;
        }
        if (std::isdigit(static_cast<unsigned char>(character)) != 0) {
            lex_number();
            continue;
        }
        if (character == '"' ) {
            lex_string();
            continue;
        }
        if (character == '/' && peek(1) == '/') {
            offset_ += 2;
            while (!at_end() && peek() != '\n' && peek() != '\r') {
                ++offset_;
            }
            continue;
        }
        if (character == '/' && peek(1) == '*') {
            lex_block_comment();
            continue;
        }

        ++offset_;
        switch (character) {
        case '.': emit(TokenKind::Dot, begin); break;
        case ':': emit(TokenKind::Colon, begin); break;
        case ',': emit(TokenKind::Comma, begin); break;
        case '#': emit(TokenKind::Hash, begin); break;
        case '$': emit(TokenKind::Dollar, begin); break;
        case '(': emit(TokenKind::LeftParen, begin); break;
        case ')': emit(TokenKind::RightParen, begin); break;
        case '[': emit(TokenKind::LeftBracket, begin); break;
        case ']': emit(TokenKind::RightBracket, begin); break;
        case ';': emit(TokenKind::Semicolon, begin); break;
        case '@': emit(TokenKind::At, begin); break;
        case '?': emit(TokenKind::Question, begin); break;
        case '+': emit(TokenKind::Plus, begin); break;
        case '*': emit(TokenKind::Star, begin); break;
        case '/': emit(TokenKind::Slash, begin); break;
        case '{':
            ++brace_depth;
            emit(TokenKind::LeftBrace, begin);
            break;
        case '}':
            if (interpolation && brace_depth == 0) {
                emit(TokenKind::InterpolationEnd, begin);
                return;
            }
            if (brace_depth > 0) {
                --brace_depth;
            }
            emit(TokenKind::RightBrace, begin);
            break;
        case '=':
            emit(consume('=') ? TokenKind::EqualEqual : TokenKind::Equal, begin);
            break;
        case '!':
            emit(consume('=') ? TokenKind::BangEqual : TokenKind::Bang, begin);
            break;
        case '>':
            emit(consume('=') ? TokenKind::GreaterEqual : TokenKind::Greater, begin);
            break;
        case '<':
            emit(consume('=') ? TokenKind::LessEqual : TokenKind::Less, begin);
            break;
        case '-':
            emit(consume('>') ? TokenKind::Arrow : TokenKind::Minus, begin);
            break;
        case '&':
            if (consume('&')) {
                emit(TokenKind::AmpAmp, begin);
            } else {
                emit(TokenKind::Invalid, begin);
            }
            break;
        case '|':
            if (consume('|')) {
                emit(TokenKind::PipePipe, begin);
            } else {
                emit(TokenKind::Invalid, begin);
            }
            break;
        default:
            emit(TokenKind::Invalid, begin);
            break;
        }
    }

    if (interpolation) {
        diagnostics_.error(
            {offset_, offset_},
            "unterminated string interpolation; expected '}'");
    }
}

void Lexer::lex_identifier() {
    const auto begin = offset_;
    ++offset_;
    while (is_identifier_continue(peek())) {
        ++offset_;
    }
    const auto text = source_.slice({begin, offset_});
    const auto found = keywords.find(text);
    emit(found == keywords.end() ? TokenKind::Identifier : found->second, begin);
}

void Lexer::lex_number() {
    const auto begin = offset_;
    auto kind = TokenKind::Integer;
    if (peek() == '0' && (peek(1) == 'x' || peek(1) == 'X')) {
        kind = TokenKind::HexInteger;
        offset_ += 2;
        const auto digit_begin = offset_;
        bool previous_separator = false;
        bool invalid_separator = false;
        while (is_hex_digit(peek()) || peek() == '_') {
            if (peek() == '_' && (offset_ == digit_begin || previous_separator)) {
                invalid_separator = true;
            }
            previous_separator = peek() == '_';
            ++offset_;
        }
        if (offset_ == digit_begin || previous_separator || invalid_separator) {
            diagnostics_.error(
                {begin, offset_},
                "hex integer separators must appear between digits");
        }
    } else {
        bool previous_separator = false;
        bool invalid_separator = false;
        while (std::isdigit(static_cast<unsigned char>(peek())) != 0 || peek() == '_') {
            if (peek() == '_' && previous_separator) {
                invalid_separator = true;
            }
            previous_separator = peek() == '_';
            ++offset_;
        }
        if (previous_separator || invalid_separator) {
            diagnostics_.error(
                {begin, offset_},
                "integer separators must appear between digits");
        }
    }
    emit(kind, begin);
}

void Lexer::lex_string() {
    const auto quote = offset_;
    ++offset_;
    emit(TokenKind::StringStart, quote);
    auto text_begin = offset_;

    const auto flush_text = [&]() {
        if (text_begin < offset_) {
            tokens_.push_back(Token{TokenKind::StringText, {text_begin, offset_}});
        }
    };

    while (!at_end()) {
        if (peek() == '"') {
            flush_text();
            const auto end_quote = offset_;
            ++offset_;
            emit(TokenKind::StringEnd, end_quote);
            return;
        }
        if (peek() == '\n' || peek() == '\r') {
            flush_text();
            diagnostics_.error(
                {quote, offset_},
                "newline in string literal; use an escaped newline");
            return;
        }
        if (peek() == '\\') {
            ++offset_;
            const auto escape = peek();
            if (escape == 'u') {
                ++offset_;
                const auto digits = offset_;
                for (int i = 0; i < 4 && is_hex_digit(peek()); ++i) {
                    ++offset_;
                }
                if (offset_ - digits != 4) {
                    diagnostics_.error(
                        {digits - 2, offset_},
                        "Unicode escape requires exactly four hex digits");
                }
            } else if (
                escape == 't' || escape == 'b' || escape == 'r' ||
                escape == 'n' || escape == '\'' || escape == '"' ||
                escape == '\\' || escape == '$') {
                ++offset_;
            } else {
                if (!at_end()) {
                    ++offset_;
                }
                diagnostics_.error(
                    {offset_ >= 2 ? offset_ - 2 : 0, offset_},
                    "unknown string escape");
            }
            continue;
        }
        if (peek() == '$' && is_identifier_start(peek(1))) {
            flush_text();
            const auto begin = offset_;
            offset_ += 2;
            while (is_identifier_continue(peek())) {
                ++offset_;
            }
            emit(TokenKind::InterpolationIdentifier, begin);
            text_begin = offset_;
            continue;
        }
        if (peek() == '$' && peek(1) == '{') {
            flush_text();
            const auto begin = offset_;
            offset_ += 2;
            emit(TokenKind::InterpolationStart, begin);
            lex_normal(true);
            text_begin = offset_;
            continue;
        }
        ++offset_;
    }

    flush_text();
    diagnostics_.error({quote, offset_}, "unterminated string literal");
}

void Lexer::lex_block_comment() {
    const auto begin = offset_;
    offset_ += 2;
    std::size_t depth = 1;
    while (!at_end() && depth != 0) {
        if (peek() == '/' && peek(1) == '*') {
            offset_ += 2;
            ++depth;
        } else if (peek() == '*' && peek(1) == '/') {
            offset_ += 2;
            --depth;
        } else if (peek() == '\n' || peek() == '\r') {
            const auto newline_begin = offset_;
            ++offset_;
            if (source_.text()[newline_begin] == '\r' && peek() == '\n') {
                ++offset_;
            }
            emit_newline(newline_begin, offset_);
        } else {
            ++offset_;
        }
    }
    if (depth != 0) {
        diagnostics_.error({begin, offset_}, "unterminated block comment");
    }
}

void Lexer::emit(TokenKind kind, std::size_t begin) {
    tokens_.push_back(Token{kind, {begin, offset_}});
}

void Lexer::emit_newline(std::size_t begin, std::size_t end) {
    if (!tokens_.empty() && tokens_.back().kind == TokenKind::Newline) {
        tokens_.back().span.end = end;
        return;
    }
    tokens_.push_back(Token{TokenKind::Newline, {begin, end}});
}

bool Lexer::at_end() const noexcept {
    return offset_ >= source_.text().size();
}

char Lexer::peek(std::size_t lookahead) const noexcept {
    const auto index = offset_ + lookahead;
    return index < source_.text().size() ? source_.text()[index] : '\0';
}

bool Lexer::consume(char expected) noexcept {
    if (peek() != expected) {
        return false;
    }
    ++offset_;
    return true;
}

} // namespace abla
