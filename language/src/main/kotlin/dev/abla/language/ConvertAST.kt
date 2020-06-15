package dev.abla.language

import dev.abla.grammar.AblaParser
import dev.abla.language.nodes.*
import dev.abla.language.nodes.Annotation as AblaAnnotation
import org.antlr.v4.runtime.ParserRuleContext
import org.antlr.v4.runtime.Token

val Token.startPoint get() = Point(line, charPositionInLine)
val Token.endPoint get() = Point(line, charPositionInLine + text.length)
val ParserRuleContext.position get() = Position(start.startPoint, stop.endPoint)

fun AblaParser.FileContext.toAST(fileName: String) =
    File(fileName, fileDeclaration().mapNotNull { it.toAST() }.toMutableList(), position)

fun AblaParser.FileDeclarationContext.toAST(): Declaration =
    when (this) {
        is AblaParser.FunctionDeclarationFDContext -> functionDeclaration().toAST()
        is AblaParser.CompilerCallFDContext -> compilerCall().toAST()
        is AblaParser.ClassDeclarationFDContext -> classDeclaration().toAST()
        is AblaParser.PropertyDeclarationFDContext -> propertyDeclaration().toAST()
        else -> throw IllegalStateException("Unknown declaration type ${this::class.simpleName}")
    }

fun AblaParser.FunctionDeclarationContext.toAST() =
    FunctionDeclaration(
        functionName.text,
        functionDeclarationParameters()?.functionDeclarationParameter()?.map {
            it.parameter().toAST()
        }?.toMutableList() ?: mutableListOf(),
        functionBody()?.toAST(),
        type()?.toAST(),
        modifierList()?.modifier()?.map { it.toAST() }?.toMutableList() ?: mutableListOf(),
        modifierList()?.annotations()?.annotation()?.map { it.toAST() }?.toMutableList() ?: mutableListOf(),
        functionTypeReceiver()?.toAST(),
        position
    )

fun AblaParser.ClassDeclarationContext.toAST() =
    ClassDeclaration(
        className.text,
        modifierList()?.modifier()?.map { it.toAST() }?.toMutableList() ?: mutableListOf(),
        primaryConstructor()?.toAST(),
        classBody()?.classMemberDeclaration()?.map { it.toAST() }?.toMutableList() ?: mutableListOf(),
        position
    )

fun AblaParser.PrimaryConstructorContext.toAST() =
    ClassConstructor(
        modifierList()?.modifier()?.map { mod -> mod.toAST() }?.toMutableList() ?: mutableListOf(),
        classConstructorParameters()?.classConstructorParameter()?.map {
            if (it.VAL() != null || it.VAR() != null)
                PropertyDeclaration(
                    it.VAL() != null,
                    it.simpleIdentifier().text,
                    it.type().toAST(),
                    it.expression()?.toAST(),
                    it.modifierList()?.modifier()?.map { mod -> mod.toAST() }?.toMutableList() ?: mutableListOf(),
                    it.position
                )
            else
                Parameter(it.simpleIdentifier().text, it.type().toAST(), it.position)
        }?.toMutableList() ?: mutableListOf(),
        position
    )

fun AblaParser.ClassMemberDeclarationContext.toAST() : Declaration =
    functionDeclaration()?.toAST() ?:
        classDeclaration()?.toAST() ?:
        propertyDeclaration()?.toAST() ?:
        compilerCall()?.toAST() ?:
        throw IllegalStateException("Unknown class member type ${this::class.simpleName}")

fun AblaParser.AnnotationContext.toAST(): AblaAnnotation =
    AblaAnnotation(
        simpleIdentifier().text,
        valueArguments()?.valueArgument()?.map { it.toAST() }?.toMutableList() ?: mutableListOf(),
        position
    )

fun AblaParser.ModifierContext.toAST(): Modifier =
    functionModifier()?.toAST() ?:
    allocationModifier()?.toAST() ?:
    inheritanceModifier()?.toAST() ?:
    throw IllegalStateException("Unknown modifier type ${this::class.simpleName}")

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

fun AblaParser.InheritanceModifierContext.toAST(): Modifier =
    when (this) {
        is AblaParser.AbstractModifierContext -> Abstract(position)
        else -> throw IllegalStateException("Unknown inheritance modifier type ${this::class.simpleName}")
    }

fun AblaParser.ParameterContext.toAST() =
    Parameter(simpleIdentifier().text, type().toAST(), position)

fun AblaParser.TypeContext.toAST(): Type {
    val type = userType()?.toAST() ?:
    parenthesizedType()?.type()?.toAST() ?:
    functionType()?.toAST() ?:
    nullableType()?.userType()?.let { NullableType(it.toAST(), position) } ?:
    throw IllegalStateException("Unknown type in $text, $position")

    return MUL().fold(type) { acc, _ -> PointerType(acc, position) }
}

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
        is AblaParser.LambdaBodyContext -> Block(mutableListOf(expression().toAST()), position)
        else -> throw IllegalStateException("Unknown function body type ${this::class.simpleName}")
    }

fun AblaParser.BlockContext.toAST(): Block = Block(statement().mapNotNull { it.toAST() }.toMutableList(), position)

fun AblaParser.StatementContext.toAST(): Statement =
    expression()?.toAST() ?:
        propertyDeclaration()?.toAST() ?:
        whileStatement()?.toAST() ?:
        functionDeclaration()?.toAST() ?:
        throw IllegalStateException("Unknown statement type ${this::class.simpleName}")

fun AblaParser.WhileStatementContext.toAST(): WhileStatement =
    WhileStatement(
        condition.toAST(),
        controlStructureBody().toAST(),
        position
    )

fun AblaParser.PropertyDeclarationContext.toAST(): PropertyDeclaration =
    PropertyDeclaration(
        VAL() != null,
        variableDeclaration().simpleIdentifier().text,
        variableDeclaration().type()?.toAST(),
        expression()?.toAST(),
        modifierList()?.modifier()?.map { it.toAST() }?.toMutableList() ?: mutableListOf(),
        position
    )

fun AblaParser.CompilerCallContext.toAST() =
    CompilerExec(
        callSuffix().fold<AblaParser.CallSuffixContext, Expression>(simpleIdentifier()?.toAST() ?: functionLiteral().toAST()) { acc, suffix ->
            suffix.toAST(acc)
        },
        position
    )

fun AblaParser.CallSuffixContext.toAST(expression: Expression) =
    FunctionCall(
        expression,
        listOfNotNull(
            *(valueArguments()?.valueArgument()?.map { it.toAST() }?.toTypedArray() ?: arrayOf<Argument>()),
            functionLiteral()?.toAST()?.run { Argument(null, this, this.position) }
        ).toMutableList(),
        position
    )

fun AblaParser.NavigationSuffixContext.toAST(expression: Expression) =
    MemberAccess(
        expression,
        simpleIdentifier().text,
        position
    )

fun AblaParser.ValueArgumentContext.toAST() =
    Argument(simpleIdentifier()?.text, expression().toAST(), position)

fun AblaParser.ExpressionContext.toAST(): Expression = assignmentExpression().toAST()

fun AblaParser.AssignmentExpressionContext.toAST(): Expression =
    applyAssignmentRightAssoc(equalityOperation().toAST(), assignmentExpressionAssignments()) {
        AssignmentResolved(equalityOperation().toAST(), position)
    }

fun AblaParser.EqualityOperationContext.toAST(): Expression =
    equalityOperationOps()?.fold(comparisonOperation().toAST()) { acc, it ->
        BinaryOperation(
            it.equalityOperator().toAST(),
            acc,
            it.comparisonOperation().toAST(),
            position
        )
    } ?: comparisonOperation().toAST()

fun AblaParser.ComparisonOperationContext.toAST(): Expression =
    comparisonOperationOps()?.fold(arithmaticOperationLower().toAST()) { acc, it ->
        BinaryOperation(
            it.comparisonOperator().toAST(),
            acc,
            it.arithmaticOperationLower().toAST(),
            position
        )
    } ?: arithmaticOperationLower().toAST()

fun AblaParser.ArithmaticOperationLowerContext.toAST(): Expression =
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
            postfixUnarySuffix().fold<AblaParser.PostfixUnarySuffixContext, Expression>(primaryExpression().toAST()) { acc, suffix ->
                suffix.toAST(acc)
            }
        else -> throw IllegalStateException("Unknown expression type ${this::class.simpleName}")
    }

fun AblaParser.ControlStructureBodyContext.toAST(): Block =
    block()?.toAST() ?:
        statement()?.toAST()?.let { Block(mutableListOf(it), positionZero) } ?:
        throw IllegalStateException("Unknown control structure block $text, $position")

fun AblaParser.EqualityOperatorContext.toAST(): BinaryOperator =
    EQUALS()?.let { BinaryOperator.Equals } ?:
    NOT_EQUALS()?.let { BinaryOperator.NotEquals } ?:
    throw IllegalStateException("Unknown equality operator type $text, $position")

fun AblaParser.ComparisonOperatorContext.toAST(): BinaryOperator =
    RANGLE()?.let { BinaryOperator.GreaterThan } ?:
        LANGLE()?.let { BinaryOperator.LesserThan } ?:
        GTE()?.let { BinaryOperator.GreaterThanEqual } ?:
        LTE()?.let { BinaryOperator.LesserThanEqual } ?:
        throw IllegalStateException("Unknown comparison operator type $text, $position")

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

fun AblaParser.PrimaryExpressionContext.toAST(): Expression =
    when (this) {
        is AblaParser.SimpleIdentifierExpressionContext -> simpleIdentifier().toAST()
        is AblaParser.LiteralExpressionContext -> literal().toAST()
        is AblaParser.FunctionLiteralExpressionContext -> functionLiteral().toAST()
        is AblaParser.ParenthesizedExpressionContext -> expression().toAST()
        is AblaParser.IfExpressionContext -> IfElseExpression(condition.toAST(), ifBody.toAST(), elseBody?.toAST(), position)
        is AblaParser.WhenExpressionContext -> WhenExpression(condition?.toAST(), whenCase()?.map { it.toAST() }?.toMutableList() ?: mutableListOf(), position)
        else -> throw IllegalStateException("Unknown primary expression type ${this::class.simpleName}")
    }

fun AblaParser.WhenCaseContext.toAST(): WhenExpression.Case =
    ELSE()?.let { WhenExpression.ElseCase(controlStructureBody().toAST()) } ?:
    expression()?.let { WhenExpression.ExpressionCase(it.map { expression -> expression.toAST() }.toMutableList(), controlStructureBody().toAST()) } ?:
    throw IllegalStateException("Unknown when case type $text")

fun AblaParser.PostfixUnarySuffixContext.toAST(expression: Expression) =
    callSuffix()?.toAST(expression) ?:
        navigationSuffix()?.toAST(expression) ?:
        throw IllegalStateException("Unknown postfix unary suffix type ${this::class.simpleName}")

fun AblaParser.SimpleIdentifierContext.toAST(): IdentifierExpression = IdentifierExpression(text, position)

fun AblaParser.LiteralContext.toAST(): Literal =
    when (this) {
        is AblaParser.IntegerLiteralContext -> Integer(text, position)
        is AblaParser.StringLiteralLiteralContext -> stringLiteral().toAST()
        is AblaParser.ArrayLiteralContext -> toAST()
        else -> throw IllegalStateException("Unknown literal type ${this::class.simpleName}")
    }

fun AblaParser.ArrayLiteralContext.toAST() = ArrayLiteral(expression().map { it.toAST() }.toMutableList(), position)

fun AblaParser.FunctionLiteralContext.toAST() =
    FunctionLiteral(
        Block(statement().mapNotNull { it.toAST() }.toMutableList(), position),
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


// Maybe there is an easier way?
data class AssignmentResolved(val rhs: Expression, val position: Position)
private inline fun <T> applyAssignmentRightAssoc(
    first: Expression,
    operations: List<T>?,
    operationReduce: T.() -> AssignmentResolved
): Expression {
    if (operations == null)
        return first
    lateinit var last: AssignmentResolved
    val iterator = operations.listIterator(operations.size)
    if (iterator.hasPrevious()) {
        last = iterator.previous().operationReduce()
    } else
        return first

    if (!iterator.hasPrevious())
        return Assignment(first, last.rhs, last.position)

    while (iterator.hasPrevious()) {
        val transformResult = iterator.previous().operationReduce()
        last = transformResult.copy(rhs = Assignment(transformResult.rhs, last.rhs, last.position))
    }

    return Assignment(first, last.rhs, last.position)
}