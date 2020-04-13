package dev.ablac.runner

import dev.ablac.frontend.ICompileService
import dev.ablac.utils.IMeasurementService
import kotlinx.coroutines.runBlocking
import org.koin.core.KoinComponent
import org.koin.core.inject

class Runner : KoinComponent {
    private val compileService by inject<ICompileService>()
    private val measurementService by inject<IMeasurementService>()

    fun run(args: Array<String>) {
        measurementService.measureBlocking("global") {
            if (args.isEmpty())
                compileService.compileStream(System.`in`)
            else
                compileService.compileFile(args[0])

            compileService.output()
        }
        measurementService.print()
    }
}