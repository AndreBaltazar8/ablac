lexer grammar AblaLexer;

DelimitedComment : '/*' ( DelimitedComment | . )*? '*/' -> channel(HIDDEN) ;

LineComment : '//' ~[\r\n]* -> channel(HIDDEN) ;

WS : [\u0020\u0009\u000C]+ -> channel(HIDDEN) ;
NL: ('\n' | '\r' '\n'?) -> channel(HIDDEN) ;

ASSIGNMENT : '=' ;
COLON : ':' ;
COMMA : ',' ;
COMPILER_DIRECTIVE : '#' ;
LCURL : '{' ;
RCURL : '}' ;
LPAREN : '(' ;
RPAREN : ')' ;
ARROW : '=>' ;
FUN : 'fun' ;
SEMICOLON : ';' ;
AT : '@' ;
EXTERN : 'extern' ;

BooleanLiteral : 'true' | 'false' ;
IntegerLiteral : DigitNoZero DigitOrSeparator* Digit | Digit ;

ID : NonDigit (NonDigit | Digit)* ;

fragment NonDigit : [a-zA-Z_] ;
fragment Digit : [0-9] ;
fragment DigitNoZero : [1-9] ;
fragment DigitOrSeparator: Digit | '_' ;
fragment HexDigit : [0-9a-fA-F] ;

fragment UniCharacterLiteral : '\\' 'u' HexDigit HexDigit HexDigit HexDigit ;
fragment EscapedIdentifier : '\\' ('t' | 'b' | 'r' | 'n' | '\'' | '"' | '\\' | '$') ;
FieldIdentifier : '$' ID ;

QUOTE_OPEN : '"' -> pushMode(LineString) ;
mode LineString ;

QUOTE_CLOSE : '"' -> popMode;

LineStrRef : FieldIdentifier ;
LineStrText : ~('\\' | '"' | '$')+ | '$' ;
LineStrEscapedChar : EscapedIdentifier | UniCharacterLiteral ;

LineStrExprStart : '${' -> pushMode(DEFAULT_MODE) ;