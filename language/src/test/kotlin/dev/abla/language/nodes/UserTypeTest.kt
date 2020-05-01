package dev.abla.language.nodes

import dev.abla.language.positionZero
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class UserTypeTest {
    @Test
    fun testToHuman() {
        val type = UserType(
            "List",
            arrayOf(UserType("Int", arrayOf(), null, positionZero)),
            null,
            positionZero
        )
        assertEquals("List<Int>", type.toHuman())
    }
}