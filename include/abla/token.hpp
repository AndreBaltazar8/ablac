#pragma once

#include "abla/source.hpp"

#include <string_view>

namespace abla {

enum class TokenKind {
    End,
    Invalid,
    Newline,
    Identifier,
    Integer,
    HexInteger,
    StringStart,
    StringText,
    StringEnd,
    InterpolationIdentifier,
    InterpolationStart,
    InterpolationEnd,

    KwAbstract,
    KwClass,
    KwCompile,
    KwConstructor,
    KwDo,
    KwElse,
    KwExtern,
    KwFalse,
    KwFun,
    KwIf,
    KwInterface,
    KwNoEscape,
    KwNull,
    KwOwn,
    KwResource,
    KwReturn,
    KwTrue,
    KwTrusted,
    KwVal,
    KwVar,
    KwWhen,
    KwWhile,

    Dot,
    Equal,
    Colon,
    Comma,
    Hash,
    Dollar,
    LeftBrace,
    RightBrace,
    LeftParen,
    RightParen,
    LeftBracket,
    RightBracket,
    Arrow,
    Semicolon,
    At,
    Question,
    Less,
    Greater,
    Plus,
    Minus,
    Star,
    Slash,
    EqualEqual,
    BangEqual,
    GreaterEqual,
    LessEqual,
    Bang,
    AmpAmp,
    PipePipe,
};

struct Token {
    TokenKind kind;
    SourceSpan span;
};

[[nodiscard]] std::string_view token_kind_name(TokenKind kind);

} // namespace abla
