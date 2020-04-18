package dev.ablac.frontend

import dev.ablac.common.Symbol
import dev.ablac.common.SymbolTable
import dev.ablac.common.symbolTable
import dev.ablac.language.ASTVisitor
import dev.ablac.language.nodes.*
import dev.ablac.language.positionZero
import dev.ablac.utils.printFlushed
import kotlinx.coroutines.Job
import java.nio.file.FileSystems
import java.nio.file.Paths
import java.util.*

class ExecutionVisitor(
    private val compilationContext: CompilationContext?,
    private val compilerService: ICompileService
) : ASTVisitor() {
    private var job = Job(compilationContext?.parentJob).apply {
        compilationContext?.job?.complete()
    }

    private var fileName: String? = null
    private val workingDirectory: String
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
                functionDeclaration.parameters.forEach {
                    currentScope!![it.name] = values.pop()
                }

                val numValues = values.size
                if (functionDeclaration.block != null) {
                    functionDeclaration.block!!.accept(this)
                } else {
                    TODO("Extern implementation missing")
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
        if (executionLayer > 0)
            values.push(currentScope!![identifierExpression.identifier])
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

    override suspend fun visit(functionCall: FunctionCall) {
        functionCall.arguments.forEach {
            it.value.accept(this)
        }

        functionCall.primaryExpression.accept(this)

        if (executionLayer > 0) {
            values.pop()
            val primaryExpression = functionCall.primaryExpression
            val functionName = (primaryExpression as IdentifierExpression).identifier

            if (functionName == "import") {
                values.pop()
                functionCall.arguments[0].value.accept(this)

                val importName = (values.removeAt(values.lastIndex) as StringLiteral).string
                val file = Paths.get(workingDirectory, importName.substring(1, importName.length - 1)).toAbsolutePath()
                    .toString()

                compilerService.compileFile(file, parallel = true, compilationContext = CompilationContext(job, Job(job)))
                values.add(Integer("1", positionZero))
            } else {
                requirePendingImports()

                val function = currentTable?.find(functionName) as Symbol.Function
                function.node.accept(this)
            }
        } else
            super.visit(functionCall)
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
}