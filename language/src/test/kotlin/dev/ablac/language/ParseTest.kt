package dev.ablac.language

import dev.ablac.utils.MeasurementService
import kotlin.concurrent.thread
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertTrue

class ParseTest {
    @Test
    fun testParseEfficiency() {
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
                            parseService.parseSource("source", "fun hi ".repeat(numLines), it)
                            lines -= numLines
                        }
                    }
                })
            }
            threads.forEach { it.join() }
        }

        val lastMeasurement = measurementService.measurements.last()
        lastMeasurement.print()
        assertTrue(lastMeasurement.timeElapsed < 1_000_000_000L)
    }
}
