package dev.abla.language

import dev.abla.grammar.AblaParser
import dev.abla.language.nodes.*
import org.antlr.v4.runtime.ParserRuleContext
import org.antlr.v4.runtime.Token

val Token.startPoint get() = Point(line, charPositionInLine)
val Token.endPoint get() = Point(line, charPositionInLine + text.length)
val ParserRuleContext.position get() = Position(start.startPoint, stop.endPoint)

fun AblaParser.FileContext.toAST(fileName: String) =
    File(fileName, fileDeclaration().mapNotNull { it.toAST() }.toTypedArray(), position)

fun AblaParser.FileDeclarationContext.toAST(): Declaration =
    when (this) {
        is AblaParser.FunctionDeclarationFDContext -> functionDeclaration().toAST()
        is AblaParser.CompilerCallFDContext -> compilerCall().toAST()
        is AblaParser.ClassDeclarationFDContext -> classDeclaration().toAST()
        else -> throw IllegalStateException("Unknown declaration type ${this::class.simpleName}")
    }

fun AblaParser.FunctionDeclarationContext.toAST() =
    FunctionDeclaration(
        functionName.text,
        functionDeclarationParameters()?.functionDeclarationParameter()?.map {
            it.parameter().toAST()
        }?.toTypedArray() ?: arrayOf(),
        functionBody()?.toAST(),
        type()?.toAST(),
        modifierList()?.modifier()?.map { it.toAST() }?.toTypedArray() ?: arrayOf(),
        position
    )

fun AblaParser.ClassDeclarationContext.toAST() =
    ClassDeclaration(
        className.text,
        modifierList()?.modifier()?.map { it.toAST() }?.toTypedArray() ?: arrayOf(),
        classBody()?.classMemberDeclaration()?.map { it.toAST() }?.toTypedArray() ?: arrayOf(),
        position
    )

fun AblaParser.ClassMemberDeclarationContext.toAST() : Declaration =
    functionDeclaration()?.toAST() ?:
            classDeclaration()?.toAST() ?:
                throw IllegalStateException("Unknown class member type ${this::class.simpleName}")

fun AblaParser.ModifierContext.toAST(): Modifier =
    when (this) {
        is AblaParser.FunctionModifierModifierContext -> functionModifier().toAST()
        is AblaParser.AllocationModifierModifierContext -> allocationModifier().toAST()
        else -> throw IllegalStateException("Unknown modifier type ${this::class.simpleName}")
    }

fun AblaParser.FunctionModifierContext.toAST(): Modifier =
    when (this) {
        is AblaParser.ExternModifierContext -> Extern(stringLiteral()?.toAST(), position)
        else -> throw IllegalStateException("Unknown function modifier type ${this::class.simpleName}")
    }

fun AblaParser.AllocationModifierContext.toAST(): Modifier =
    when (this) {
        is AblaParser.CompilerModifierContext -> ModCompiler(position)
        else -> throw IllegalStateException("Unknown allocation modifier type ${this::class.simpleName}")
    }

fun AblaParser.ParameterContext.toAST() =
    Parameter(simpleIdentifier().text, type().toAST(), position)

fun AblaParser.TypeContext.toAST(): Type =
    userType()?.toAST() ?:
        parenthesizedType()?.type()?.toAST() ?:
        functionType()?.toAST() ?:
        nullableType()?.userType()?.let { NullableType(it.toAST(), position) } ?:
        throw IllegalStateException("Unknown type in $text, $position")

fun AblaParser.UserTypeContext.toAST(): UserType {
    val iterator = simpleUserType().iterator()
    if (!iterator.hasNext()) throw UnsupportedOperationException("Empty collection can't be reduced.")
    var accumulator: UserType = iterator.next().toAST(null)
    while (iterator.hasNext()) {
        accumulator = iterator.next().toAST(accumulator)
    }
    return accumulator
}

fun AblaParser.FunctionTypeContext.toAST(): FunctionType =
    FunctionType(
        functionTypeParameters().functionTypeParameter().map { it.toAST() }.toTypedArray(),
        type().toAST(),
        functionTypeReceiver()?.toAST(),
        position
    )

fun AblaParser.FunctionTypeReceiverContext.toAST(): Type =
    userType()?.toAST() ?:
        parenthesizedType()?.type()?.toAST() ?:
        nullableType()?.userType()?.let { NullableType(it.toAST(), position) } ?:
        throw IllegalStateException("Unknown function receiver type type in $text, $position")

fun AblaParser.FunctionTypeParameterContext.toAST(): Parameter =
    parameter()?.toAST() ?:
            type()?.toAST()?.let { Parameter("", it, position) } ?:
            throw IllegalStateException("Unknown function type parameter type in $text, $position")

fun AblaParser.SimpleUserTypeContext.toAST(parent: UserType?): UserType =
    UserType(
        this.simpleIdentifier().text,
        typeArguments()?.type()?.mapNotNull { it.toAST() }?.toTypedArray() ?: arrayOf(),
        parent,
        position
    )

fun AblaParser.FunctionBodyContext.toAST(): Block =
    when (this) {
        is AblaParser.BlockBodyContext -> block().toAST()
        is AblaParser.LambdaBodyContext -> Block(arrayOf(expression().toAST()), position)
        else -> throw IllegalStateException("Unknown function body type ${this::class.simpleName}")
    }

fun AblaParser.BlockContext.toAST(): Block = Block(statement().mapNotNull { it.toAST() }.toTypedArray(), position)

fun AblaParser.StatementContext.toAST(): Statement =
    when (this) {
        is AblaParser.ExpressionStatementContext -> expression().toAST()
        else -> throw IllegalStateException("Unknown statement type ${this::class.simpleName}")
    }

fun AblaParser.CompilerCallContext.toAST() =
    CompilerExec(
        callSuffix().fold<AblaParser.CallSuffixContext, PrimaryExpression>(simpleIdentifier()?.toAST() ?: functionLiteral().toAST()) { acc, suffix ->
            suffix.toAST(acc)
        },
        position
    )

fun AblaParser.CallSuffixContext.toAST(primaryExpression: PrimaryExpression) =
    FunctionCall(
        primaryExpression,
        listOfNotNull(
            *(valueArguments()?.valueArgument()?.map { it.toAST() }?.toTypedArray() ?: arrayOf<Argument>()),
            functionLiteral()?.toAST()?.run { Argument(null, this, this.position) }
        ).toTypedArray(),
        position
    )

fun AblaParser.ValueArgumentContext.toAST() =
    Argument(simpleIdentifier()?.text, expression().toAST(), position)

fun AblaParser.ExpressionContext.toAST(): Expression =
    binaryOperationOps()?.fold(binaryOperationHigher().toAST()) { acc, it ->
        BinaryOperation(
            it.binaryOperatorLower().toAST(),
            acc,
            it.binaryOperationHigher().toAST(),
            position
        )
    } ?: binaryOperationHigher().toAST()

fun AblaParser.BinaryOperationHigherContext.toAST(): Expression =
    binaryOperationHigherOps()?.asSequence()?.fold(atomicExpression().toAST()) { acc, it ->
        BinaryOperation(
            it.binaryOperatorHigher().toAST(),
            acc,
            it.atomicExpression().toAST(),
            position
        )
    } ?: atomicExpression().toAST()

fun AblaParser.AtomicExpressionContext.toAST(): Expression =
    when (this) {
        is AblaParser.PerfixExpressionContext -> prefixUnaryOperation().toAST(atomicExpression().toAST())
        is AblaParser.SuffixExpressionContext ->
            postfixUnarySuffix().fold<AblaParser.PostfixUnarySuffixContext, PrimaryExpression>(primaryExpression().toAST()) { acc, suffix ->
                suffix.toAST(acc)
            }
        is AblaParser.ParenthesizedExpressionContext -> expression().toAST()
        else -> throw IllegalStateException("Unknown expression type ${this::class.simpleName}")
    }

fun AblaParser.BinaryOperatorLowerContext.toAST(): BinaryOperator =
    PLUS()?.let { BinaryOperator.Plus } ?:
        MINUS()?.let { BinaryOperator.Minus } ?:
        throw IllegalStateException("Unknown operator lower type $text, $position")

fun AblaParser.BinaryOperatorHigherContext.toAST(): BinaryOperator =
    MUL()?.let { BinaryOperator.Mul } ?:
        DIV()?.let { BinaryOperator.Div } ?:
        throw IllegalStateException("Unknown operator higher type $text, $position")

fun AblaParser.PrefixUnaryOperationContext.toAST(expression: Expression) =
    when (this) {
        is AblaParser.CompilerExecutionContext -> CompilerExec(expression, position)
        else -> throw IllegalStateException("Unknown prefix unary operation type ${this::class.simpleName}")
    }

fun AblaParser.PrimaryExpressionContext.toAST(): PrimaryExpression =
    when (this) {
        is AblaParser.SimpleIdentifierExpressionContext -> simpleIdentifier().toAST()
        is AblaParser.LiteralExpressionContext -> literal().toAST()
        is AblaParser.FunctionLiteralExpressionContext -> functionLiteral().toAST()
        else -> throw IllegalStateException("Unknown primary expression type ${this::class.simpleName}")
    }

fun AblaParser.PostfixUnarySuffixContext.toAST(primaryExpression: PrimaryExpression) =
    when (this) {
        is AblaParser.CallSuffixSuffixContext -> callSuffix().toAST(primaryExpression)
        else -> throw IllegalStateException("Unknown postfix unary suffix type ${this::class.simpleName}")
    }

fun AblaParser.SimpleIdentifierContext.toAST(): IdentifierExpression = IdentifierExpression(text, position)

fun AblaParser.LiteralContext.toAST(): Literal =
    when (this) {
        is AblaParser.IntegerLiteralContext -> Integer(text, position)
        is AblaParser.StringLiteralLiteralContext -> stringLiteral().toAST()
        else -> throw IllegalStateException("Unknown literal type ${this::class.simpleName}")
    }

fun AblaParser.FunctionLiteralContext.toAST() =
    FunctionLiteral(
        Block(statement().mapNotNull { it.toAST() }.toTypedArray(), position),
        position
    )

fun AblaParser.StringLiteralContext.toAST() =
    StringLiteral(
        lineString()?.map { it.toAST() }?.toTypedArray() ?: arrayOf(),
        position
    )

fun AblaParser.LineStringContext.toAST(): StringLiteral.StringPart =
    lineStringContent()?.toAST() ?:
            lineStringExpression()?.toAST() ?:
            throw IllegalStateException("Unknown string type in $text, $position")

fun AblaParser.LineStringContentContext.toAST() =
    LineStrText()?.let { StringLiteral.StringConst(text, position) } ?:
        LineStrEscapedChar()?.let { StringLiteral.StringConst(text.unescapeAbla(), position) } ?:
        LineStrRef()?.let {
            StringLiteral.StringExpression(
                IdentifierExpression(
                    text.substring(1),
                    position.copy(start = Point(start.line, start.charPositionInLine + 1))
                ),
                position
            )
        } ?: throw IllegalStateException("Unknown string content type in $text, $position")

fun AblaParser.LineStringExpressionContext.toAST() =
    StringLiteral.StringExpression(expression().toAST(), position)

fun String.unescapeAbla(): String =
    when (this[1]) {
        't' -> "\t"
        'b' -> "\b"
        'r' -> "\r"
        'n' -> "\n"
        'u' -> substring(2, 6).toInt(16).toChar().toString()
        else -> substring(1)
    }
