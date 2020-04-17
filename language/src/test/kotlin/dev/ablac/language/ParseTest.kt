package dev.ablac.language

import dev.ablac.utils.MeasurementService
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import kotlin.concurrent.thread
import kotlin.random.Random

class ParseTest {
    @Test
    fun `1warmup`() = measureEfficiency("fun hi { 1 }", 10000)

    @Test
    fun testParseEfficiency() = measureEfficiency("fun hi { 1 }", 4500)

    @Test
    fun testParseEfficiencyExtern() = measureEfficiency("fun hi ", 1000)

    private fun measureEfficiency(code: String, expected: Long) {
        val measurementService = MeasurementService()
        val parseService = ParseService()
        val threads = mutableListOf<Thread>()

        measurementService.measureBlocking("total") {
            repeat(8) {
                threads.add(thread {
                    measurementService.measureBlocking("thread") {
                        var lines = 125_000
                        val random = Random.Default
                        while (lines > 0) {
                            val numLines = random.nextInt(1, minOf(lines, 1000) + 1)
                            parseService.parseSource("source", code.repeat(numLines), it)
                            lines -= numLines
                        }
                    }
                })
            }
            threads.forEach { it.join() }
        }

        val lastMeasurement = measurementService.measurements.last()
        lastMeasurement.print()
        assertTrue(lastMeasurement.timeElapsed < expected * 1_000_000L)
    }
}
