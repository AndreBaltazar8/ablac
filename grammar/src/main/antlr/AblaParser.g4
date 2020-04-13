parser grammar AblaParser;

options {
    tokenVocab = AblaLexer;
    superClass = AblaBaseParser;
}

file : fileDeclaration* EOF ;

fileDeclaration : functionDeclaration # functionDeclarationFD
                | compilerCall # compilerCallFD
                ;

functionDeclaration: FUN functionName = simpleIdentifier functionBody? ;
compilerCall: COMPILER_DIRECTIVE functionCall ;

functionBody : block # blockBody
             | ARROW expression # lambdaBody
             ;

block : LCURL (statement nlsemiOrRCurlNoConsume)* RCURL ;

statement : expression # expressionStatement
          ;

expression : simpleIdentifier # identifierExpression
           | COMPILER_DIRECTIVE expression # compilerExecution
           | functionCall # functionCallExpression
           | literal # literalConstantExpression
           ;

functionCall : simpleIdentifier LPAREN (expression (COMMA expression)* COMMA?) RPAREN ;

literal : stringLiteral # stringLiteralLiteral
        | IntegerLiteral # integerLiteral
        | BooleanLiteral # booleanLiteral
        ;

stringLiteral : QUOTE_OPEN (lineStringContent | lineStringExpression)* QUOTE_CLOSE;
lineStringContent : LineStrText | LineStrEscapedChar | LineStrRef ;
lineStringExpression : LineStrExprStart expression RCURL ;

simpleIdentifier : ID
                 | FUN
                 ;

nlsemiOrRCurlNoConsume : SEMICOLON | {this.lineTerminator()}? | {this.noConsumeRCURL()}?;
