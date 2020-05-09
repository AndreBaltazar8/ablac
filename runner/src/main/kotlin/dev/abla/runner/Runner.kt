package dev.abla.runner

import dev.abla.common.CodeGenParameters
import dev.abla.llvm.ILLVMCodeGenerator
import dev.abla.frontend.ICompileService
import dev.abla.utils.IMeasurementService
import org.koin.core.KoinComponent
import org.koin.core.inject

class Runner : KoinComponent {
    private val compileService by inject<ICompileService>()
    private val llvmCodeGenerator by inject<ILLVMCodeGenerator>()
    private val measurementService by inject<IMeasurementService>()

    fun run(args: Array<String>) {
        measurementService.measureBlocking("global") {
            if (args.isEmpty())
                compileService.compileStream(System.`in`)
            else
                compileService.compileFile(args[0])

            compileService.output(llvmCodeGenerator, CodeGenParameters("main"))
        }
        measurementService.measurements.last().print()
    }
}