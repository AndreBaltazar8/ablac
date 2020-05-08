package dev.abla.frontend

import com.sun.jna.NativeLibrary
import dev.abla.common.SymbolTable
import dev.abla.common.elseSymbolTable
import dev.abla.common.ifSymbolTable
import dev.abla.common.symbolTable
import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.*
import dev.abla.language.positionZero
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
    private var values = Stack<Literal>()
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
                functionDeclaration.parameters.reversed().forEach {
                    currentScope!![it.name] = values.pop()
                }

                val numValues = values.size
                if (functionDeclaration.block != null) {
                    functionDeclaration.block!!.accept(this)
                } else {
                    val extern = functionDeclaration.modifiers.first { it is Extern } as Extern
                    if (extern.libName == null)
                        throw Exception("Must specify lib name in extern to run at compile time")
                    val result = NativeLibrary.getInstance(extern.libName!!.toValue(currentScope!!) as String)
                        .getFunction(functionDeclaration.name)
                        .invoke(
                            Int::class.java,
                            functionDeclaration.parameters.map {
                                currentScope!![it.name].toValue(currentScope!!)
                            }.toTypedArray()
                        )
                    values.push(Integer(result.toString(), positionZero))
                }

                val returnValue = values.pop()
                repeat(values.size - numValues) {
                    values.pop()
                }
                values.push(returnValue)
            } else
                super.visit(functionDeclaration)
        }
    }

    override suspend fun visit(identifierExpression: IdentifierExpression) {
        if (executionLayer > 0) {
            val value = currentScope!![identifierExpression.identifier]
            //?: throw IllegalStateException("Unknown value for identifier ${identifierExpression.identifier}") // TODO: check for this later
            values.push(value)
        }
    }

    override suspend fun visit(compilerExec: CompilerExec) {
        if (!compilerExec.compiled) {
            executionLayer++
            super.visit(compilerExec)
            compilerExec.compiled = true
            compilerExec.expression = values.pop()
            executionLayer--
        } else {
            super.visit(compilerExec)
        }
    }

    override suspend fun visit(stringLiteral: StringLiteral) {
        if (executionLayer > 0)
            values.add(stringLiteral)
    }

    override suspend fun visit(integer: Integer) {
        if (executionLayer > 0)
            values.add(integer)
    }

    override suspend fun visit(functionLiteral: FunctionLiteral) {
        if (executionLayer > 0)
            values.add(functionLiteral)
    }

    override suspend fun visit(functionCall: FunctionCall) {
        functionCall.arguments.forEach {
            it.value.accept(this)
        }

        functionCall.primaryExpression.accept(this)

        if (executionLayer > 0) {
            val topVal = values.pop()

            val function = if (topVal is FunctionLiteral)
                topVal
            else {
                val primaryExpression = functionCall.primaryExpression
                val functionName = (primaryExpression as IdentifierExpression).identifier

                var symbol = currentTable?.find(functionName)
                if (symbol == null) {
                    requirePendingImports()
                    symbol = currentTable?.find(functionName)
                }
                if (symbol == null)
                    throw Exception("Unknown function $functionName")
                symbol.node
            }

            function.let {
                if (it is CompilerFunctionDeclaration)
                    values.add(it.executionBlock(this, functionCall.arguments.reversed().map {
                        values.pop().toValue(currentScope!!)
                    }.reversed().toTypedArray()))
                else if (it is FunctionLiteral) {
                    val numValues = values.size
                    it.block.accept(this)
                    val returnValue = values.pop()
                    repeat(values.size - numValues) {
                        values.pop()
                    }
                    values.push(returnValue)
                } else
                    it.accept(this)
            }
        }
    }

    override suspend fun visit(binaryOperation: BinaryOperation) {
        if (executionLayer > 0) {
            binaryOperation.lhs.accept(this)
            val lhsValue = values.pop().toValue(currentScope!!) as Int
            binaryOperation.rhs.accept(this)
            val rhsValue = values.pop().toValue(currentScope!!) as Int
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
            values.push(Integer(result, positionZero))
        } else
            super.visit(binaryOperation)
    }

    override suspend fun visit(ifElseExpression: IfElseExpression) {
        if (executionLayer > 0) {
            ifElseExpression.condition.accept(this)
            val conditionValue = values.pop().toValue(currentScope!!)
            val conditionTrue = conditionValue as Int == 1
            val ifBody = ifElseExpression.ifBody
            val elseBody = ifElseExpression.elseBody
            if (conditionTrue && ifBody != null) {
                withTable(ifElseExpression.ifSymbolTable) {
                    ifBody.accept(this)
                }
            } else if (!conditionTrue && elseBody != null) {
                withTable(ifElseExpression.elseSymbolTable) {
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
                currentScope!![propertyDeclaration.name] = values.pop()
            }
        } else
            super.visit(propertyDeclaration)
    }

    override suspend fun visit(assignment: Assignment) {
        if (executionLayer > 0) {
            val lhs = assignment.lhs
            if (lhs is IdentifierExpression) {
                val node = currentTable!!.find(lhs.identifier)?.node
                when {
                    node == null -> throw IllegalStateException("Unknown identifier ${lhs.identifier}")
                    node is PropertyDeclaration && node.isFinal -> throw IllegalStateException("Cannot assign value to final variable ${lhs.identifier}")
                    node is PropertyDeclaration -> {
                        assignment.rhs.accept(this)
                        currentScope!![lhs.identifier] = values[values.lastIndex]
                    }
                    else -> throw IllegalStateException("Only supports assignments to properties. Found: ${node.javaClass.simpleName}")
                }
            } else
                throw IllegalStateException("Unknown assignment to expression of type ${assignment.rhs.javaClass.simpleName}")
        } else
            super.visit(assignment)
    }

    override suspend fun visit(whileStatement: WhileStatement) {
        if (executionLayer > 0) {
            withTable(whileStatement.symbolTable) {
                while (true) {
                    whileStatement.condition.accept(this)

                    val conditionValue = values.pop().toValue(currentScope!!)
                    val conditionTrue = conditionValue as Int == 1

                    if (!conditionTrue)
                        break

                    whileStatement.block?.accept(this)
                }
            }
        } else
            super.visit(whileStatement)
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

    private suspend fun withTable(symbolTable: SymbolTable?, function: suspend () -> Unit) {
        currentScope = ExecutionScope(currentScope, symbolTable!!)
        function()
        currentScope = currentScope!!.parent
    }

    suspend fun Literal?.toValue(currentScope: ExecutionScope): Any =
        when (this) {
            is Integer -> number.toInt()
            is StringLiteral -> {
                stringParts.map {
                    when (it) {
                        is StringLiteral.StringConst -> it.string
                        is StringLiteral.StringExpression -> {
                            it.expression.accept(this@ExecutionVisitor)
                            values.pop().toValue(currentScope).toString()
                        }
                        else -> throw IllegalStateException("Unknown string part type ${it.javaClass.simpleName}")
                    }
                }.joinToString("")
            }
            is FunctionLiteral -> this
            else -> throw Exception("Unknown literal conversion")
        }
}
