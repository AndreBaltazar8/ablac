parser grammar AblaParser;

options {
    tokenVocab = AblaLexer;
    superClass = AblaBaseParser;
}

file : fileDeclaration* EOF ;

fileDeclaration : functionDeclaration # functionDeclarationFD
                | compilerCall # compilerCallFD
                ;

functionDeclaration: modifierList? FUN functionName = simpleIdentifier functionDeclarationParameters? functionBody? ;
functionDeclarationParameters : LPAREN (functionDeclarationParameter (COMMA functionDeclarationParameter)* COMMA?)? RPAREN ;
functionDeclarationParameter : parameter (ASSIGNMENT expression)? ;
parameter : simpleIdentifier ;

annotation : simpleIdentifier valueArguments? ;
annotations : (AT annotation (COMMA annotation)*)+ ;

modifierList : annotations | annotations? modifier+ ;

modifier : functionModifier # functionModifierModifier ;

functionModifier : EXTERN (COLON stringLiteral) # externModifier
                 ;

compilerCall : COMPILER_DIRECTIVE simpleIdentifier callSuffix+ ;

functionBody : block # blockBody
             | ARROW expression # lambdaBody
             ;

block : LCURL (statement nlsemiOrRCurlNoConsume)* RCURL ;

statement : expression # expressionStatement
          ;

expression : prefixUnaryOperation expression # perfixExpression
           | primaryExpression postfixUnarySuffix* # suffixExpression
           ;

primaryExpression : simpleIdentifier # simpleIdentifierExpression
                  | literal # literalExpression
                  ;

prefixUnaryOperation : COMPILER_DIRECTIVE # compilerExecution
                     ;

postfixUnarySuffix : callSuffix # callSuffixSuffix
                   ;

callSuffix : valueArguments? functionLiteral
           | valueArguments
           ;

valueArguments : LPAREN RPAREN
               | LPAREN valueArgument (COMMA valueArgument)* COMMA? RPAREN
               ;

valueArgument : (simpleIdentifier ASSIGNMENT)? expression
              ;

functionLiteral : LCURL (statement nlsemiOrRCurlNoConsume)* RCURL ;

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
