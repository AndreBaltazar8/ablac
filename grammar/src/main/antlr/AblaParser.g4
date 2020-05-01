parser grammar AblaParser;

options {
    tokenVocab = AblaLexer;
    superClass = AblaBaseParser;
}

file : fileDeclaration* EOF ;

fileDeclaration : functionDeclaration # functionDeclarationFD
                | compilerCall # compilerCallFD
                | classDeclaration # classDeclarationFD
                ;

functionDeclaration: modifierList? FUN (functionTypeReceiver DOT)? functionName = simpleIdentifier (typeParameters)? functionDeclarationParameters? (COLON type)? functionBody? ;
functionDeclarationParameters : LPAREN (functionDeclarationParameter (COMMA functionDeclarationParameter)* COMMA?)? RPAREN ;
functionDeclarationParameter : parameter (ASSIGNMENT expression)? ;

typeParameters : LANGLE typeParameter (COMMA typeParameter)* COMMA? RANGLE ;
typeParameter : simpleIdentifier (COLON type)? ;

classDeclaration : modifierList? CLASS className = simpleIdentifier (typeParameters)? (classBody)? ;
classBody : LCURL classMemberDeclaration* RCURL ;
classMemberDeclaration : classDeclaration
                       | functionDeclaration
                       ;

parameter : simpleIdentifier COLON type ;

userType : simpleUserType (DOT typeName = simpleUserType)* ;
simpleUserType : simpleIdentifier (typeArguments)? ;

typeArguments : LANGLE type (COMMA type)* COMMA? RANGLE ;
type: functionType | parenthesizedType | nullableType | userType ;
parenthesizedType : LPAREN type RPAREN ;
functionType: (functionTypeReceiver DOT)? functionTypeParameters ARROW type ;
functionTypeReceiver : parenthesizedType | nullableType | userType ;
functionTypeParameters : (LPAREN RPAREN) | (LPAREN functionTypeParameter (COMMA functionTypeParameter)* COMMA? RPAREN) ;
functionTypeParameter: (parameter | type) ;

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
             | ASSIGNMENT expression # lambdaBody
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

stringLiteral : QUOTE_OPEN lineString* QUOTE_CLOSE;
lineString : lineStringContent | lineStringExpression ;
lineStringContent : LineStrText | LineStrEscapedChar | LineStrRef ;
lineStringExpression : LineStrExprStart expression RCURL ;

simpleIdentifier : ID ;

nlsemiOrRCurlNoConsume : SEMICOLON | {this.lineTerminator()}? | {this.noConsumeRCURL()}?;
