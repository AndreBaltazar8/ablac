package dev.abla.utils

import kotlinx.coroutines.runBlocking
import kotlin.math.roundToInt

interface IMeasurementService {
    suspend fun <T : Any> measure(step: String, block: suspend (MeasurementScope) -> T): T
    fun <T : Any> measureBlocking(step: String, block: suspend (MeasurementScope) -> T): T
    fun print()
    val measurements: List<Measurement>
}

class MeasurementService : IMeasurementService {
    private val measurementScope = MeasurementScope("global")

    override suspend fun <T : Any> measure(step: String, block: suspend (MeasurementScope) -> T): T =
        measurementScope.measure(step, block)

    override fun <T : Any> measureBlocking(step: String, block: suspend (MeasurementScope) -> T): T =
        runBlocking {
            measure(step, block)
        }

    override fun print() = measurementScope.print()
    override val measurements: List<Measurement> = measurementScope.measurements
}

data class Measurement(val step: String, val timeElapsed: Long, val measurements: List<Measurement>) {
    fun print(depth: Int = 0) {
        println("${" ".repeat(depth)}${if (depth > 0) "- " else ""}${step}: ${(timeElapsed / 1_000_000.0).roundToInt()}ms")
        measurements.forEach { it.print(depth + 1) }
    }
}

class MeasurementScope(
    private val step: String
) {
    internal val measurements = mutableListOf<Measurement>()
    private suspend fun measure(block: suspend (MeasurementScope) -> Unit): Measurement {
        val start = System.nanoTime()
        block(this)
        val nanoTime = System.nanoTime() - start
        return Measurement(step, nanoTime, measurements)
    }

    suspend fun <T : Any> measure(step: String, block: suspend (MeasurementScope) -> T): T {
        lateinit var result: T
        measurements.add(MeasurementScope(step).measure {
            result = block(it)
        })
        return result
    }

    internal fun print() = measurements.forEach { it.print() }
}
