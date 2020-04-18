package dev.ablac.language

import dev.ablac.grammar.AblaParser
import dev.ablac.language.nodes.*
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
        else -> throw IllegalStateException("Unknown declaration type ${this::class.simpleName}")
    }

fun AblaParser.FunctionDeclarationContext.toAST() =
    FunctionDeclaration(
        functionName.text,
        functionDeclarationParameters()?.functionDeclarationParameter()?.map {
            it.parameter().toAST()
        }?.toTypedArray() ?: arrayOf(),
        functionBody()?.toAST(),
        position
    )

fun AblaParser.ParameterContext.toAST() =
    Parameter(simpleIdentifier().text, Type("int", arrayOf(), positionZero), position)

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
        callSuffix().fold<AblaParser.CallSuffixContext, PrimaryExpression>(simpleIdentifier().toAST()) { acc, suffix ->
            suffix.toAST(acc)
        },
        position
    )

fun AblaParser.CallSuffixContext.toAST(primaryExpression: PrimaryExpression) =
    FunctionCall(
        primaryExpression,
        valueArguments().valueArgument().map { it.toAST() }.toTypedArray(),
        position
    )

fun AblaParser.ValueArgumentContext.toAST() =
    Argument(simpleIdentifier()?.text, expression().toAST(), position)

fun AblaParser.ExpressionContext.toAST(): Expression =
    when (this) {
        is AblaParser.PerfixExpressionContext -> IdentifierExpression(text, position)
        is AblaParser.SuffixExpressionContext ->
            postfixUnarySuffix().fold<AblaParser.PostfixUnarySuffixContext, PrimaryExpression>(primaryExpression().toAST()) { acc, suffix ->
                suffix.toAST(acc)
            }
        else -> throw IllegalStateException("Unknown expression type ${this::class.simpleName}")
    }

fun AblaParser.PrimaryExpressionContext.toAST() : PrimaryExpression =
    when (this) {
        is AblaParser.SimpleIdentifierExpressionContext -> simpleIdentifier().toAST()
        is AblaParser.LiteralExpressionContext -> literal().toAST()
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
        is AblaParser.StringLiteralLiteralContext -> StringLiteral(text, position)
        else -> throw IllegalStateException("Unknown literal type ${this::class.simpleName}")
    }
