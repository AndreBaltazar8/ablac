package dev.ablac.language.nodes

import dev.ablac.language.positionZero
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class TypeTest {
    @Test
    fun testToHuman() {
        val type = Type("List", arrayOf(Type("Int", arrayOf(), positionZero)), positionZero)
        assertEquals("List<Int>", type.toHuman())
    }
}