parser grammar AblaParser;

options {
    tokenVocab = AblaLexer;
    superClass = AblaBaseParser;
}

file : fileDeclaration* EOF ;

fileDeclaration : functionDeclaration # functionDeclarationFD
                | compilerCall # compilerCallFD
                | classDeclaration # classDeclarationFD
                | propertyDeclaration #propertyDeclarationFD
                ;

functionDeclaration: modifierList? FUN (functionTypeReceiver DOT)? functionName = simpleIdentifier (typeParameters)? functionDeclarationParameters? (COLON type)? functionBody? ;
functionDeclarationParameters : LPAREN (functionDeclarationParameter (COMMA functionDeclarationParameter)* COMMA?)? RPAREN ;
functionDeclarationParameter : parameter (ASSIGNMENT expression)? ;

typeParameters : LANGLE typeParameter (COMMA typeParameter)* COMMA? RANGLE ;
typeParameter : simpleIdentifier (COLON type)? ;

classDeclaration : modifierList? CLASS className = simpleIdentifier (typeParameters)? ({this.matchNoLineTerminator()}? primaryConstructor)? (classBody)? ;
classBody : LCURL classMemberDeclaration* RCURL ;
classMemberDeclaration : classDeclaration
                       | functionDeclaration
                       | propertyDeclaration
                       | compilerCall
                       ;

primaryConstructor : modifierList? CONSTRUCTOR? classConstructorParameters ;

classConstructorParameters : (LPAREN RPAREN) | (LPAREN classConstructorParameter (COMMA classConstructorParameter)* COMMA? RPAREN) ;
classConstructorParameter : modifierList? (VAR | VAL)? simpleIdentifier COLON type (ASSIGNMENT expression)? ;

parameter : simpleIdentifier COLON type ;

userType : simpleUserType (DOT typeName = simpleUserType)* ;
simpleUserType : simpleIdentifier (typeArguments)? ;

typeArguments : LANGLE type (COMMA type)* COMMA? RANGLE ;
type: (functionType | parenthesizedType | nullableType | userType) MUL*;
parenthesizedType : LPAREN type RPAREN ;
functionType: (functionTypeReceiver DOT)? functionTypeParameters ARROW type ;
functionTypeReceiver : parenthesizedType | nullableType | userType ;
functionTypeParameters : (LPAREN RPAREN) | (LPAREN functionTypeParameter (COMMA functionTypeParameter)* COMMA? RPAREN) ;
functionTypeParameter: (parameter | type) ;

nullableType: userType QUEST ;

annotation : simpleIdentifier valueArguments? ;
annotations : (AT annotation (COMMA annotation)*)+ ;

modifierList : annotations | annotations? modifier+ ;

modifier : functionModifier
         | allocationModifier
         | inheritanceModifier
         ;

functionModifier : EXTERN (COLON stringLiteral)? # externModifier
                 ;

allocationModifier : COMPILER # compilerModifier
                   ;

inheritanceModifier : ABSTRACT # abstractModifier
                    ;

compilerCall : COMPILER_DIRECTIVE (simpleIdentifier | functionLiteral) callSuffix+ ;

functionBody : block # blockBody
             | ASSIGNMENT expression # lambdaBody
             ;

block : LCURL (statement nlsemiOrRCurlNoConsume)* RCURL ;

statement : expression
          | propertyDeclaration
          | whileStatement
          | functionDeclaration
          ;

whileStatement : WHILE LPAREN condition=expression RPAREN (controlStructureBody | SEMICOLON) ;

propertyDeclaration : modifierList? (VAR | VAL) variableDeclaration (ASSIGNMENT expression)? ;

variableDeclaration : simpleIdentifier (COLON type)? ;

expression : assignmentExpression ;

assignmentExpression : equalityOperation assignmentExpressionAssignments* ;
assignmentExpressionAssignments : ASSIGNMENT equalityOperation ;

equalityOperation : comparisonOperation equalityOperationOps* ;
equalityOperationOps : equalityOperator comparisonOperation ;

comparisonOperation : arithmaticOperationLower comparisonOperationOps* ;
comparisonOperationOps : comparisonOperator arithmaticOperationLower ;

arithmaticOperationLower : binaryOperationHigher binaryOperationOps* ;
binaryOperationOps : binaryOperatorLower binaryOperationHigher ;

binaryOperationHigher : atomicExpression binaryOperationHigherOps* ;
binaryOperationHigherOps : binaryOperatorHigher atomicExpression ;

atomicExpression : prefixUnaryOperation atomicExpression # perfixExpression
                 | primaryExpression postfixUnarySuffix* # suffixExpression
                 ;

controlStructureBody : block | statement ;

equalityOperator : EQUALS | NOT_EQUALS ;
comparisonOperator : RANGLE | LANGLE | GTE | LTE ;
binaryOperatorHigher : MUL | DIV ;
binaryOperatorLower : PLUS | MINUS ;

primaryExpression : simpleIdentifier # simpleIdentifierExpression
                  | literal # literalExpression
                  | functionLiteral # functionLiteralExpression
                  | LPAREN expression RPAREN #parenthesizedExpression
                  | IF LPAREN condition=expression RPAREN ifBody=controlStructureBody (ELSE elseBody=controlStructureBody)? #ifExpression
                  | WHEN (LPAREN condition=expression RPAREN)? LCURL whenCase* RCURL #whenExpression
                  ;

whenCase : expression (COMMA expression)* ARROW controlStructureBody
         | ELSE ARROW controlStructureBody
         ;

prefixUnaryOperation : COMPILER_DIRECTIVE # compilerExecution
                     ;

postfixUnarySuffix : callSuffix
                   | navigationSuffix
                   | indexSuffix
                   ;

callSuffix : typeArguments? valueArguments? {this.matchNoLineTerminator()}? functionLiteral
           | typeArguments? valueArguments
           ;

navigationSuffix : DOT simpleIdentifier
                 ;

indexSuffix : LSQUARE index=expression RSQUARE
            ;

valueArguments : {this.matchNoLineTerminator()}? LPAREN RPAREN
               | {this.matchNoLineTerminator()}? LPAREN valueArgument (COMMA valueArgument)* COMMA? RPAREN
               ;

valueArgument : (simpleIdentifier ASSIGNMENT)? expression
              ;

functionLiteral : LCURL (simpleIdentifier (COMMA simpleIdentifier)* ARROW)? (statement nlsemiOrRCurlNoConsume)* RCURL ;

literal : stringLiteral # stringLiteralLiteral
        | IntegerLiteral # integerLiteral
        | BooleanLiteral # booleanLiteral
        | LSQUARE (expression (COMMA expression)* COMMA?)? RSQUARE # arrayLiteral
        ;

stringLiteral : QUOTE_OPEN lineString* QUOTE_CLOSE;
lineString : lineStringContent | lineStringExpression ;
lineStringContent : LineStrText | LineStrEscapedChar | LineStrRef ;
lineStringExpression : LineStrExprStart expression RCURL ;

simpleIdentifier : ID ;

nlsemiOrRCurlNoConsume : SEMICOLON | {this.lineTerminator()}? | {this.noConsumeRCURL()}?;
