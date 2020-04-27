package dev.abla.grammar;

import org.antlr.v4.runtime.Lexer;
import org.antlr.v4.runtime.Parser;
import org.antlr.v4.runtime.Token;
import org.antlr.v4.runtime.TokenStream;

abstract class AblaBaseParser extends Parser {
    AblaBaseParser(TokenStream input) {
        super(input);
    }

    public boolean lineTerminator() {
        int tokensBehind = 1;
        Token token = null;
        do {
            token = getTokenStream().get(getCurrentToken().getTokenIndex() - tokensBehind);
            if (token.getType() == AblaParser.NL || token.getType() == AblaParser.DelimitedComment && (token.getText().contains("\n") || token.getText().contains("\r")))
                return true;
            tokensBehind++;
        } while (token.getChannel() == Lexer.HIDDEN);
        return true;
    }

    public boolean noConsumeRCURL() {
        return getCurrentToken().getType() == AblaParser.RCURL;
    }
}
