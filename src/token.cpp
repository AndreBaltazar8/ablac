#include "abla/token.hpp"

namespace abla {

std::string_view token_kind_name(TokenKind kind) {
#define ABLA_TOKEN_CASE(name, spelling) case TokenKind::name: return spelling
    switch (kind) {
    ABLA_TOKEN_CASE(End, "end of file");
    ABLA_TOKEN_CASE(Invalid, "invalid token");
    ABLA_TOKEN_CASE(Newline, "newline");
    ABLA_TOKEN_CASE(Identifier, "identifier");
    ABLA_TOKEN_CASE(Integer, "integer");
    ABLA_TOKEN_CASE(HexInteger, "hex integer");
    ABLA_TOKEN_CASE(StringStart, "'\"'");
    ABLA_TOKEN_CASE(StringText, "string text");
    ABLA_TOKEN_CASE(StringEnd, "'\"'");
    ABLA_TOKEN_CASE(InterpolationIdentifier, "string interpolation");
    ABLA_TOKEN_CASE(InterpolationStart, "'${'");
    ABLA_TOKEN_CASE(InterpolationEnd, "'}'");
    ABLA_TOKEN_CASE(KwAbstract, "'abstract'");
    ABLA_TOKEN_CASE(KwClass, "'class'");
    ABLA_TOKEN_CASE(KwCompile, "'compile'");
    ABLA_TOKEN_CASE(KwConstructor, "'constructor'");
    ABLA_TOKEN_CASE(KwDo, "'do'");
    ABLA_TOKEN_CASE(KwElse, "'else'");
    ABLA_TOKEN_CASE(KwExtern, "'extern'");
    ABLA_TOKEN_CASE(KwFalse, "'false'");
    ABLA_TOKEN_CASE(KwFun, "'fun'");
    ABLA_TOKEN_CASE(KwIf, "'if'");
    ABLA_TOKEN_CASE(KwInterface, "'interface'");
    ABLA_TOKEN_CASE(KwNoEscape, "'noescape'");
    ABLA_TOKEN_CASE(KwNull, "'null'");
    ABLA_TOKEN_CASE(KwOwn, "'own'");
    ABLA_TOKEN_CASE(KwResource, "'resource'");
    ABLA_TOKEN_CASE(KwTrue, "'true'");
    ABLA_TOKEN_CASE(KwTrusted, "'trusted'");
    ABLA_TOKEN_CASE(KwVal, "'val'");
    ABLA_TOKEN_CASE(KwVar, "'var'");
    ABLA_TOKEN_CASE(KwWhen, "'when'");
    ABLA_TOKEN_CASE(KwWhile, "'while'");
    ABLA_TOKEN_CASE(Dot, "'.'");
    ABLA_TOKEN_CASE(Equal, "'='");
    ABLA_TOKEN_CASE(Colon, "':'");
    ABLA_TOKEN_CASE(Comma, "','");
    ABLA_TOKEN_CASE(Hash, "'#'");
    ABLA_TOKEN_CASE(Dollar, "'$'");
    ABLA_TOKEN_CASE(LeftBrace, "'{'");
    ABLA_TOKEN_CASE(RightBrace, "'}'");
    ABLA_TOKEN_CASE(LeftParen, "'('");
    ABLA_TOKEN_CASE(RightParen, "')'");
    ABLA_TOKEN_CASE(LeftBracket, "'['");
    ABLA_TOKEN_CASE(RightBracket, "']'");
    ABLA_TOKEN_CASE(Arrow, "'->'");
    ABLA_TOKEN_CASE(Semicolon, "';'");
    ABLA_TOKEN_CASE(At, "'@'");
    ABLA_TOKEN_CASE(Question, "'?'");
    ABLA_TOKEN_CASE(Less, "'<'");
    ABLA_TOKEN_CASE(Greater, "'>'");
    ABLA_TOKEN_CASE(Plus, "'+'");
    ABLA_TOKEN_CASE(Minus, "'-'");
    ABLA_TOKEN_CASE(Star, "'*'");
    ABLA_TOKEN_CASE(Slash, "'/'");
    ABLA_TOKEN_CASE(EqualEqual, "'=='");
    ABLA_TOKEN_CASE(BangEqual, "'!='");
    ABLA_TOKEN_CASE(GreaterEqual, "'>='");
    ABLA_TOKEN_CASE(LessEqual, "'<='");
    ABLA_TOKEN_CASE(Bang, "'!'");
    ABLA_TOKEN_CASE(AmpAmp, "'&&'");
    ABLA_TOKEN_CASE(PipePipe, "'||'");
    }
#undef ABLA_TOKEN_CASE
    return "token";
}

} // namespace abla
