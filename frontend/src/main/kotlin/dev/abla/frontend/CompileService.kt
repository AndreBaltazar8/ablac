package dev.abla.frontend

import dev.abla.common.*
import dev.abla.language.IParseService
import dev.abla.language.nodes.*
import dev.abla.language.positionZero
import dev.abla.utils.ILockService
import dev.abla.utils.IMeasurementService
import dev.abla.utils.MeasurementScope
import kotlinx.coroutines.*
import java.io.InputStream
import java.nio.file.Paths
import java.util.*

interface ICompileService {
    suspend fun compileFile(fileName: String, parallel: Boolean = true, compilationContext: CompilationContext? = null)
    suspend fun compileSource(source: String, parallel: Boolean = true, compilationContext: CompilationContext? = null)
    suspend fun compileStream(stream: InputStream, parallel: Boolean = true, compilationContext: CompilationContext? = null)
    suspend fun output(codeGenerator: ICodeGenerator)
}

class CompileService(
    private val parserService: IParseService,
    private val lockService: ILockService,
    private val measurementService: IMeasurementService
) : ICompileService{
    private val parentJob = Job()
    private val coroutineScope = CoroutineScope(parentJob + Dispatchers.Default)

    private val global = SymbolTable()

    private val pendingCompilation = Collections.synchronizedMap(mutableMapOf<String, PendingCompilationUnit>())
    private val compiledUnits = Collections.synchronizedMap(mutableMapOf<String, CompilationUnit>())
    private var compileNumber: Int = 0
        get() = synchronized(this) {
            return field++
        }

    override suspend fun compileFile(fileName: String, parallel: Boolean, compilationContext: CompilationContext?) {
        compile(fileName, true, parallel, compilationContext) { parserService.parseFile(fileName, it) }
    }

    override suspend fun compileSource(source: String, parallel: Boolean, compilationContext: CompilationContext?) {
        val name = "<source#$compileNumber>"
        compile(name, false, parallel, compilationContext) { parserService.parseSource(name, source, it) }
    }

    override suspend fun compileStream(
        stream: InputStream,
        parallel: Boolean,
        compilationContext: CompilationContext?
    ) {
        val name = "<stream#$compileNumber>"
        compile(name, false, parallel, compilationContext) { parserService.parseStream(name, stream, it) }
    }

    override suspend fun output(codeGenerator: ICodeGenerator) {
        parentJob.complete()
        parentJob.join()

        println("Compiled Units: ${compiledUnits.size}")

        codeGenerator.generateCode(compiledUnits.values)
    }

    private suspend fun compile(
        fileName: String,
        checkExistent: Boolean,
        parallel: Boolean,
        compilationContext: CompilationContext?,
        block: suspend (MeasurementScope) -> File
    ) {
        lockService.namedLock(fileName) { lock ->
            if (checkExistent) {
                lock.lock()

                val compilationUnit = compiledUnits[fileName]
                if (compilationUnit != null) {
                    compilationContext?.job?.complete()
                    return@namedLock
                }

                val pending = pendingCompilation[fileName]
                if (pending != null) {
                    if (parallel)
                        pending.job.join()
                    compilationContext?.job?.complete()
                    return@namedLock
                }
            }

            val job = coroutineScope.launch(start = CoroutineStart.LAZY) {
                measurementService.measure("compile $fileName") {
                    val pendingCompilationUnit = pendingCompilation[fileName]
                        ?: throw IllegalStateException("Pending compilation unit is gone.")

                    val file = pendingCompilationUnit.parse(it)
                    val compilationUnit = CompilationUnit(fileName, file)
                    compiledUnits[fileName] = compilationUnit
                    pendingCompilation.remove(fileName)

                    it.measure("type gather") {
                        compilationUnit.file.accept(TypeGather(global))
                    }

                    it.measure("execution") {
                        compilationUnit.file.accept(ExecutionVisitor(compilationContext))
                    }
                }
            }

            pendingCompilation[fileName] = PendingCompilationUnit(fileName, block, job)

            job.start()

            if (checkExistent)
                lock.unlock()

            if (!parallel)
                job.join()
        }
    }

    init {
        addCompileFunction("import", arrayOf(Parameter("fileName", BuiltInTypes.String))) { executionVisitor, args ->
            val importName = args[0] as String
            val file = Paths.get(executionVisitor.workingDirectory, importName).toAbsolutePath().toString()

            compileFile(
                file,
                true,
                CompilationContext(executionVisitor.executionJob, Job(executionVisitor.executionJob))
            )

            Integer("1", positionZero)
        }
    }

    private fun addCompileFunction(
        name: String,
        parameters: Array<Parameter> = arrayOf(),
        modifiers: Array<Modifier> = arrayOf(),
        executionBlock: suspend (ExecutionVisitor, Array<Any>) -> Literal
    ) {
        val declaration = CompilerFunctionDeclaration(name, parameters, arrayOf(*modifiers, ModCompiler(positionZero)), executionBlock)
        global.symbols.add(Symbol.Function(name, declaration))
    }

    data class PendingCompilationUnit(val fileName: String, val parse: suspend (MeasurementScope) -> File, var job: Job)
}

data class CompilationContext(val parentJob: Job, val job: CompletableJob)
