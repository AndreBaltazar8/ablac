package dev.ablac.language.nodes

import dev.ablac.language.positionZero
import kotlin.test.Test
import kotlin.test.assertEquals

class TypeTest {
    @Test
    fun testToHuman() {
        val type = Type("List", arrayOf(Type("Int", arrayOf(), positionZero)), positionZero)
        assertEquals("List<Int>", type.toHuman())
    }
}