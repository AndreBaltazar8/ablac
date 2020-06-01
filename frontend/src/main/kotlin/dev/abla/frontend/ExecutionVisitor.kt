package dev.abla.frontend

import com.sun.jna.NativeLibrary
import dev.abla.common.*
import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.*
import dev.abla.language.positionZero
import dev.abla.utils.BackingField
import kotlinx.coroutines.Job
import java.lang.IllegalStateException
import java.nio.file.FileSystems
import java.util.*

class ExecutionVisitor(
    private val compilationContext: CompilationContext?
) : ASTVisitor() {
    private var job = Job(compilationContext?.parentJob).apply {
        compilationContext?.job?.complete()
    }
    val executionJob get() = job

    private var fileName: String? = null
    val workingDirectory: String
        get() = fileName!!.let { fileName ->
            if (fileName.contains("<"))
                FileSystems.getDefault().getPath("").toAbsolutePath().toString()
            else
                java.io.File(fileName).parent.toString()
        }

    private var executionLayer = 0
    private var values = Stack<ExecutionValue>()
    private var currentScope: ExecutionScope? = null
    private val currentTable get() = currentScope?.symbolTable

    override suspend fun visit(file: File) {
        fileName = file.fileName
        withTable(file.symbolTable) {
            super.visit(file)
            job.complete()
        }
    }

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        withTable(functionDeclaration.symbolTable) {
            if (executionLayer > 0) {
                if (functionDeclaration.callInfo == null)
                    return@withTable

                if (functionDeclaration.isCompiler)
                    populateCompilerContext(functionDeclaration)

                if (functionDeclaration.callInfo?.instance != null)
                    currentScope!!["this"] = values.pop()
                functionDeclaration.parameters.reversed().forEach {
                    currentScope!![it.name] = values.pop()
                }

                functionDeclaration.callInfo = null

                val numValues = values.size
                val block = functionDeclaration.block
                if (block != null) {
                    withTable(block.symbolTable) {
                        block.accept(this)
                    }
                } else {
                    val extern = functionDeclaration.modifiers.first { it is Extern } as Extern
                    if (extern.libName == null)
                        throw Exception("Must specify lib name in extern to run at compile time")
                    val result = NativeLibrary.getInstance(extern.libName!!.toValue(currentScope!!) as String)
                        .getFunction(functionDeclaration.name)
                        .invoke(
                            Int::class.java,
                            functionDeclaration.parameters.map {
                                currentScope!![it.name]?.value.toValue(currentScope!!)
                            }.toTypedArray()
                        )
                    values.push(ExecutionValue.Value(Integer(result.toString(), positionZero)))
                }

                if (values.isNotEmpty() && !functionDeclaration.returnType.isNullOrVoid()) {
                    val returnValue = values.pop()
                    repeat(values.size - numValues) {
                        values.pop()
                    }
                    values.push(returnValue)
                } else {
                    repeat(values.size - numValues) {
                        values.pop()
                    }
                }
            } else
                super.visit(functionDeclaration)
        }
    }

    private suspend fun populateCompilerContext(functionDeclaration: FunctionDeclaration) {
        val symbol = findClassSymbol("CompilerContext")

        symbol.node.symbolTable!!.symbols.apply {
            replaceFunction("rename", arrayOf(Parameter("fnName", UserType.String))) { _, args ->
                functionDeclaration.name = args[0] as String
                functionDeclaration.symbol.name = args[0] as String
                ExecutionValue.Value(Integer("1", positionZero))
            }
            replaceFunction(
                "setBody",
                arrayOf(Parameter("function", FunctionType(arrayOf(), UserType.Void, null, positionZero)))
            ) { _, args ->
                functionDeclaration.block = (args[0] as FunctionLiteral).block.copy()
                ExecutionValue.Value(Integer("1", positionZero))
            }
            replaceFunction(
                "modify",
                arrayOf(
                    Parameter("fnName", UserType.String),
                    Parameter("function", FunctionType(arrayOf(), UserType.Void, null, positionZero))
                )
            ) { _, args ->
                val sym = functionDeclaration.symbolTable!!.find(args[0] as String)
                if (sym !is Symbol.Function)
                    throw Exception("Not a method")
                sym.node.block = (args[1] as FunctionLiteral).block.copy()
                sym.node.block!!.symbolTable = sym.node.symbolTable
                ExecutionValue.Value(Integer("1", positionZero))
            }
            replaceFunction("find", arrayOf(Parameter("fnName", UserType.String))) { _, args ->
                val sym = symbol.node.symbolTable!!.find(args[0] as String)
                if (sym !is Symbol.Function)
                    throw Exception("Not a method")
                ExecutionValue.Instance(UserType("CompilerFunctionContext"),
                    object : ExecutionScope(null, currentTable!!) {
                        override fun modify(identifier: String, value: ExecutionValue) {
                            super.modify(identifier, value)
                            if (identifier == "block")
                                sym.node.block = (value as ExecutionValue.CompilerNode).node as Block
                        }
                    }.apply {
                        set("block", ExecutionValue.CompilerNode(sym.node.block!!))
                    }
                )
            }
            replaceFunction("findAnnotated", arrayOf(Parameter("annotation", UserType.String))) { _, args ->
                val annotationName = args[0] as String
                val symbolTable = symbol.node.symbolTable!!
                val sym = symbolTable.findFunction { it.node.annotations.any { annotation -> annotation.name == annotationName } }
                if (sym !is Symbol.Function)
                    throw Exception("Not a method")
                ExecutionValue.Instance(UserType("CompilerFunctionContext"),
                    object : ExecutionScope(null, currentTable!!) {
                        override fun modify(identifier: String, value: ExecutionValue) {
                            super.modify(identifier, value)
                            if (identifier == "block")
                                sym.node.block = (value as ExecutionValue.CompilerNode).node as Block
                        }
                    }.apply {
                        set("block", ExecutionValue.CompilerNode(sym.node.block!!))
                    }
                )
            }
            replaceFunction(
                "defineInClass",
                arrayOf(Parameter("function", FunctionType(arrayOf(), UserType.Void, null, positionZero)))
            ) { _, args ->
                (args[0] as FunctionLiteral).block.statements.filterIsInstance<FunctionDeclaration>().forEach { func ->
                    val classSymbol = functionDeclaration.symbol.receiver!!
                    val functionSymbol = Symbol.Function(func.name, func)
                    classSymbol.methods.add(functionSymbol)
                    classSymbol.node.symbolTable!!.symbols.add(functionSymbol)
                }
                ExecutionValue.Value(Integer("1", positionZero))
            }
        }
        val scope = ExecutionScope(null, symbol.node.symbolTable!!).apply {
            set("name", functionDeclaration.name.toExecutionValue())
        }
        currentScope!!["compilerContext"] = ExecutionValue.Instance(UserType("CompilerContext"), scope)
    }

    private suspend fun findClassSymbol(className: String): Symbol.Class {
        var symbol = currentTable!!.find(className)
        if (symbol == null) {
            requirePendingImports()
            symbol = currentTable!!.find(className)
        }
        if (symbol !is Symbol.Class)
            throw NotImplementedError("Unsupported")
        return symbol
    }

    override suspend fun visit(classDeclaration: ClassDeclaration) {
        withTable(classDeclaration.symbolTable) {
            super.visit(classDeclaration)
        }
    }

    override suspend fun visit(identifierExpression: IdentifierExpression) {
        val symbolTable = currentScope!!.symbolTable
        identifierExpression.symbolLazy = lazy { symbolTable.find(identifierExpression.identifier) }

        if (executionLayer > 0) {
            val identifier = identifierExpression.identifier
            var value = currentScope!![identifier]
            if (value == null) {
                requirePendingImports()
            }
            value = currentScope!![identifier]
            if (value == null)
                throw IllegalStateException("Unknown identifier $identifier")

            if (identifierExpression.returnForAssignment) {
                if (value.isFinal)
                    throw IllegalStateException("Cannot assign value to final identifier $identifier")

                val scope = currentScope!!
                values.push(ExecutionValue.AssignableValue {
                    scope.modify(identifier, it)
                })
            } else
                values.push(value)
        }
    }

    override suspend fun visit(compilerExec: CompilerExec) {
        if (!compilerExec.compiled) {
            executionLayer++
            super.visit(compilerExec)
            compilerExec.compiled = true
            if (values.size == 0)
                compilerExec.expression = Integer("0", positionZero)
            else
                compilerExec.expression = if (executionLayer > 1) values.peek().value else values.pop().value
            executionLayer--
        } else {
            super.visit(compilerExec)
        }
    }

    override suspend fun visit(stringLiteral: StringLiteral) {
        if (executionLayer > 0)
            values.add(ExecutionValue.Value(stringLiteral))
        else
            super.visit(stringLiteral)
    }

    override suspend fun visit(integer: Integer) {
        if (executionLayer > 0)
            values.add(ExecutionValue.Value(integer))
    }

    override suspend fun visit(functionLiteral: FunctionLiteral) {
        if (executionLayer > 0)
            values.add(ExecutionValue.Value(functionLiteral))
        else
            super.visit(functionLiteral)
    }

    override suspend fun visit(functionCall: FunctionCall) {
        functionCall.arguments.forEach {
            it.value.accept(this)
        }

        functionCall.expression.accept(this)

        if (executionLayer > 0) {
            val function = when (val topVal = values.pop()) {
                is ExecutionValue.Value -> topVal.value
                is ExecutionValue.ConstSymbol -> topVal.symbol.node
                else -> throw IllegalStateException("Unknown callable for $functionCall")
            }

            function.let {
                when (it) {
                    is CompilerFunctionDeclaration -> {
                        // TODO: support passing instances to compiler functions
                        if (functionCall.expression is MemberAccess)
                            values.pop()
                        values.add(it.executionBlock(this, functionCall.arguments.reversed().map {
                            values.pop().value.toValue(currentScope!!)
                        }.reversed().toTypedArray()))
                    }
                    is FunctionLiteral -> {
                        val numValues = values.size
                        withTable(it.block.symbolTable) {
                            it.block.accept(this)
                        }
                        val returnValue = values.pop()
                        repeat(values.size - numValues) {
                            values.pop()
                        }
                        values.push(returnValue)
                    }
                    is ClassDeclaration -> {
                        val instance = ExecutionValue.Instance(it.toType(), ExecutionScope(null, it.symbolTable!!))
                        it.symbol.fields.forEach { field ->
                            val property = field.node as PropertyDeclaration
                            if (property.value == null)
                                return
                            property.value?.accept(this)
                            instance.scope[property.name] = values.pop().copyWith(property.isFinal)
                        }
                        values.push(instance)
                    }
                    is FunctionDeclaration -> {
                        val isMemberAccess = functionCall.expression is MemberAccess
                        it.callInfo = CallInfo(if (isMemberAccess) values.peek()!! as ExecutionValue.Instance else null)
                        it.accept(this)
                    }
                    else -> throw NotImplementedError("Unsupported")
                }
            }
        }
    }

    override suspend fun visit(memberAccess: MemberAccess) {
        super.visit(memberAccess)
        if (executionLayer > 0) {
            val classInstance = values.peek() as ExecutionValue.Instance
            val classType = classInstance.type
            if (classType !is UserType)
                throw NotImplementedError("Unsupported")
            val symbol = currentTable!!.find(classType.identifier)
            if (symbol !is Symbol.Class)
                throw NotImplementedError("Unsupported")
            val previousScope = currentScope
            currentScope = classInstance.scope
            IdentifierExpression(memberAccess.name, memberAccess.position).apply {
                returnForAssignment = memberAccess.returnForAssignment
                accept(this@ExecutionVisitor)
            }
            currentScope = previousScope
        }
    }

    override suspend fun visit(binaryOperation: BinaryOperation) {
        if (executionLayer > 0) {
            binaryOperation.lhs.accept(this)
            val lhsValue = values.pop().value.toValue(currentScope!!) as Int
            binaryOperation.rhs.accept(this)
            val rhsValue = values.pop().value.toValue(currentScope!!) as Int
            val result = when (binaryOperation.operator) {
                BinaryOperator.Plus -> lhsValue + rhsValue
                BinaryOperator.Minus -> lhsValue - rhsValue
                BinaryOperator.Mul -> lhsValue * rhsValue
                BinaryOperator.Div -> lhsValue / rhsValue
                BinaryOperator.Equals -> if (lhsValue == rhsValue) 1 else 0
                BinaryOperator.NotEquals -> if (lhsValue != rhsValue) 1 else 0
                BinaryOperator.GreaterThan -> if (lhsValue > rhsValue) 1 else 0
                BinaryOperator.LesserThan -> if (lhsValue < rhsValue) 1 else 0
                BinaryOperator.GreaterThanEqual -> if (lhsValue >= rhsValue) 1 else 0
                BinaryOperator.LesserThanEqual -> if (lhsValue <= rhsValue) 1 else 0
            }.toString()
            values.push(ExecutionValue.Value(Integer(result, positionZero)))
        } else
            super.visit(binaryOperation)
    }

    override suspend fun visit(ifElseExpression: IfElseExpression) {
        if (executionLayer > 0) {
            ifElseExpression.condition.accept(this)
            val conditionValue = values.pop().value.toValue(currentScope!!)
            val conditionTrue = conditionValue as Int == 1
            val ifBody = ifElseExpression.ifBody
            val elseBody = ifElseExpression.elseBody
            if (conditionTrue) {
                withTable(ifBody.symbolTable) {
                    ifBody.accept(this)
                }
            } else if (!conditionTrue && elseBody != null) {
                withTable(elseBody.symbolTable) {
                    elseBody.accept(this)
                }
            }
        } else
            super.visit(ifElseExpression)
    }

    override suspend fun visit(propertyDeclaration: PropertyDeclaration) {
        if (executionLayer > 0) {
            propertyDeclaration.value?.let {
                it.accept(this)
                currentScope!![propertyDeclaration.name] = values.pop().copyWith(propertyDeclaration.isFinal)
            }
        } else
            super.visit(propertyDeclaration)
    }

    override suspend fun visit(assignment: Assignment) {
        if (executionLayer > 0) {
            assignment.lhs.accept(this)
            val value = values.pop()
            if (value !is ExecutionValue.AssignableValue)
                throw IllegalStateException("Cannot assign value at $assignment")
            assignment.rhs.accept(this)
            value.assign(values[values.lastIndex])
        } else
            super.visit(assignment)
    }

    override suspend fun visit(whileStatement: WhileStatement) {
        if (executionLayer > 0) {
                while (true) {
                    whileStatement.condition.accept(this)

                    withTable(whileStatement.block.symbolTable) {
                        val conditionValue = values.pop().value.toValue(currentScope!!)
                        val conditionTrue = conditionValue as Int == 1

                        if (!conditionTrue)
                            return@visit

                        whileStatement.block.accept(this)
                    }
                }
        } else
            super.visit(whileStatement)
    }

    override suspend fun visit(whenExpression: WhenExpression) {
        if (executionLayer > 0) {
            lateinit var valueToCompare: Any
            val condition = whenExpression.condition

            if (condition != null) {
                condition.accept(this)
                valueToCompare = values.pop().value.toValue(currentScope!!)
            }

            loop@ for (case in whenExpression.cases) {
                when (case) {
                    is WhenExpression.ElseCase -> {
                        case.body.accept(this)
                        break@loop
                    }
                    is WhenExpression.ExpressionCase -> {
                        for (expression in case.expressions) {
                            expression.accept(this)
                            val value = values.pop().value.toValue(currentScope!!)
                            if (condition != null) {
                                if (value == valueToCompare) {
                                    case.body.accept(this)
                                    break@loop
                                }
                            } else if (value as Int == 1) {
                                case.body.accept(this)
                                break@loop
                            }
                        }
                    }
                }
            }
        } else
            super.visit(whenExpression)
    }

    /*
     * TODO: Forcing everything to join here. Maybe a solution could be found to force execution only until the type
     *  that we are looking for is found. This makes it continue to execute normally without being blocked
     */
    private suspend fun requirePendingImports() {
        val newJob = Job(compilationContext?.parentJob)
        job.complete()
        job.join()
        job = newJob
    }

    private inline fun withTable(symbolTable: SymbolTable?, function: () -> Unit) {
        currentScope = ExecutionScope(currentScope, symbolTable!!)
        function()
        currentScope = currentScope!!.parent
    }

    private suspend fun Literal?.toValue(currentScope: ExecutionScope): Any =
        when (this) {
            is Integer -> number.toInt()
            is StringLiteral -> {
                stringParts.map {
                    when (it) {
                        is StringLiteral.StringConst -> it.string
                        is StringLiteral.StringExpression -> {
                            it.expression.accept(this@ExecutionVisitor)
                            values.pop().value.toValue(currentScope).toString()
                        }
                        else -> throw IllegalStateException("Unknown string part type ${it.javaClass.simpleName}")
                    }
                }.joinToString("")
            }
            is FunctionLiteral -> this
            else -> throw Exception("Unknown literal conversion")
        }

    private fun String.toExecutionValue(): ExecutionValue =
        ExecutionValue.Value(StringLiteral(arrayOf(StringLiteral.StringConst(this, positionZero)), positionZero))

    data class CallInfo(val instance: ExecutionValue.Instance?)

    var FunctionDeclaration.callInfo: CallInfo? by BackingField.nullable()
}

private fun MutableList<Symbol<*>>.replaceFunction(
    name: String,
    parameters: Array<Parameter> = arrayOf(),
    modifiers: Array<Modifier> = arrayOf(),
    executionBlock: suspend (ExecutionVisitor, Array<Any>) -> ExecutionValue
) {
    val finalModifiers = arrayOf(*modifiers, ModCompiler(positionZero))
    val function = CompilerFunctionDeclaration(name, parameters, finalModifiers, executionBlock)
    removeAll { symbol -> symbol.name == name }
    add(Symbol.Function(name, function))
}

