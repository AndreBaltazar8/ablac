package dev.ablac.frontend

import dev.ablac.language.ASTVisitor
import dev.ablac.language.nodes.*
import dev.ablac.language.positionZero
import kotlinx.coroutines.Job
import java.nio.file.FileSystems
import java.nio.file.Paths

class ExecutionVisitor(
    private val compilationContext: CompilationContext?,
    private val compilerService: ICompileService
) : ASTVisitor() {
    private var job = Job(compilationContext?.parentJob).apply {
        compilationContext?.job?.complete()
    }

    private var _fileName: String? = null
    private val workingDirectory: String
        get() = _fileName!!.let { fileName ->
            if (fileName.contains("<"))
                FileSystems.getDefault().getPath("").toAbsolutePath().toString()
            else
                java.io.File(fileName).parent.toString()
        }

    private var _executionLayer = 0
    private var _values = mutableListOf<Any>()
    override suspend fun visit(file: File) {
        _fileName = file.fileName

        super.visit(file)
        job.complete()
    }

    override suspend fun visit(compilerExec: CompilerExec) {
        if (!compilerExec.compiled) {
            _executionLayer++
            super.visit(compilerExec)
            compilerExec.compiled = true
            compilerExec.expression = Integer("1", positionZero)
            _executionLayer--
        } else {
            super.visit(compilerExec)
        }
    }

    override suspend fun visit(stringLiteral: StringLiteral) {
        _values.add(stringLiteral)
    }

    override suspend fun visit(functionCall: FunctionCall) {
        if (_executionLayer > 0) {
            val primaryExpression = functionCall.primaryExpression
            if (primaryExpression is IdentifierExpression && primaryExpression.identifier == "import") {
                functionCall.arguments[0].value.accept(this)

                val importName = (_values.removeAt(_values.lastIndex) as StringLiteral).string
                val file = Paths.get(workingDirectory, importName.substring(1, importName.length - 1)).toAbsolutePath()
                    .toString()

                compilerService.compileFile(file, parallel = true, compilationContext = CompilationContext(job, Job(job)))
            } else {
                requirePendingImports()
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
}