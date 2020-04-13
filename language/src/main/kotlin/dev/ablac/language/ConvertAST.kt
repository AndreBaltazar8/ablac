package dev.ablac.language

import dev.ablac.grammar.AblaParser
import dev.ablac.language.nodes.*
import org.antlr.v4.runtime.ParserRuleContext
import org.antlr.v4.runtime.Token

val Token.startPoint get() = Point(line, charPositionInLine)
val Token.endPoint get() = Point(line, charPositionInLine + text.length)
val ParserRuleContext.position get() = Position(start.startPoint, stop.endPoint)

fun AblaParser.FileContext.toAST(fileName: String) =
    File(fileName, fileDeclaration().mapNotNull{ it.toAST() }.toTypedArray(), position)

fun AblaParser.FileDeclarationContext.toAST() : Declaration =
    when (this) {
        is AblaParser.FunctionDeclarationFDContext -> functionDeclaration().toAST()
        is AblaParser.CompilerCallFDContext -> compilerCall().toAST()
        else -> throw IllegalStateException("Unknown declaration type ${this::class.simpleName}")
    }

fun AblaParser.FunctionDeclarationContext.toAST() =
    FunctionDeclaration(functionName.text, functionBody()?.toAST(), position)

fun AblaParser.FunctionBodyContext.toAST() : Block =
    when(this) {
        is AblaParser.BlockBodyContext -> block().toAST()
        is AblaParser.LambdaBodyContext -> Block(arrayOf(expression().toAST()), position)
        else -> throw IllegalStateException("Unknown function body type ${this::class.simpleName}")
    }

fun AblaParser.BlockContext.toAST() : Block = Block(statement().mapNotNull{ it.toAST() }.toTypedArray(), position)

fun AblaParser.StatementContext.toAST() : Statement =
    when(this) {
        is AblaParser.ExpressionStatementContext -> expression().toAST()
        else -> throw IllegalStateException("Unknown statement type ${this::class.simpleName}")
    }

fun AblaParser.CompilerCallContext.toAST() = CompilerExec(functionCall().toAST(), position)
fun AblaParser.FunctionCallContext.toAST() =
    FunctionCall(simpleIdentifier().text, expression().map{ it.toAST() }.toTypedArray(), position)

fun AblaParser.ExpressionContext.toAST() : Expression =
    when (this) {
        is AblaParser.IdentifierExpressionContext -> IdentifierExpression(text, position)
        is AblaParser.LiteralConstantExpressionContext -> literal().toAST()
        else -> throw IllegalStateException("Unknown expression type ${this::class.simpleName}")
    }

fun AblaParser.LiteralContext.toAST(): Literal =
    when (this) {
        is AblaParser.IntegerLiteralContext -> Integer(text, position)
        is AblaParser.StringLiteralLiteralContext -> StringLiteral(text, position)
        else -> throw IllegalStateException("Unknown literal type ${this::class.simpleName}")
    }
