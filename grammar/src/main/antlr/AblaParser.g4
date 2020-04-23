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
parameter : simpleIdentifier COLON type ;
userType : simpleUserType (DOT typeName = simpleUserType)* ;
simpleUserType : simpleIdentifier (typeArguments)? ;

typeArguments : LANGLE type (COMMA type)* COMMA? RANGLE ;
type: functionType | parenthesizedType | nullableType | userType ;
parenthesizedType : LPAREN type RPAREN ;
functionType: (functionTypeReceiver DOT)? functionTypeParameters ARROW type ;
functionTypeReceiver : parenthesizedType | nullableType | userType ;
functionTypeParameters : (LPAREN RPAREN) | (LPAREN (parameter | type) (COMMA (parameter | type))* COMMA? RPAREN) ;

nullableType: userType QUEST ;

annotation : simpleIdentifier valueArguments? ;
annotations : (AT annotation (COMMA annotation)*)+ ;

modifierList : annotations | annotations? modifier+ ;

modifier : functionModifier # functionModifierModifier
         | allocationModifier # allocationModifierModifier
         ;

functionModifier : EXTERN (COLON stringLiteral) # externModifier
                 ;

allocationModifier : COMPILER # compilerModifier
                   ;

compilerCall : COMPILER_DIRECTIVE (simpleIdentifier | functionLiteral) callSuffix+ ;

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
                  | functionLiteral # functionLiteralExpression
                  ;

prefixUnaryOperation : COMPILER_DIRECTIVE # compilerExecution
                     ;

postfixUnarySuffix : callSuffix # callSuffixSuffix
                   ;

callSuffix : typeArguments? valueArguments? functionLiteral
           | typeArguments? valueArguments
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
                 | EXTERN
                 ;

nlsemiOrRCurlNoConsume : SEMICOLON | {this.lineTerminator()}? | {this.noConsumeRCURL()}?;
