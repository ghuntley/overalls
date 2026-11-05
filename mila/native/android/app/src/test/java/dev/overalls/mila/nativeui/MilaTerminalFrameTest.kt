package dev.overalls.mila.nativeui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MilaTerminalFrameTest {
    @Test
    fun decodesOpaqueRgbPixels() {
        val frame = MilaTerminalFrame.decode("""{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":[{"x":0,"y":0,"width":1,"height":1,"pixels":[16711680]}]}""".toByteArray())
        assertEquals(0xffff0000.toInt(), frame.images.single().pixels.single())
    }

    @Test
    fun refusesOutOfRangePixels() {
        val badPixel = """{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":[{"x":0,"y":0,"width":1,"height":1,"pixels":[16777216]}]}"""
        assertTrue(runCatching { MilaTerminalFrame.decode(badPixel.toByteArray()) }.isFailure)
    }

    @Test
    fun refusesCoercedImagePixels() {
        for (pixel in listOf("1.5", "\"255\"", "true", "null")) {
            val frame = """{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":[{"x":0,"y":0,"width":1,"height":1,"pixels":[$pixel]}]}"""
            assertTrue(runCatching { MilaTerminalFrame.decode(frame.toByteArray()) }.isFailure)
        }
    }

    @Test
    fun refusesCoercedFrameFields() {
        val invalidFrames = listOf(
            """{"version":"1","columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":[]}""",
            """{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[[{"text":"x","foreground":null,"background":null,"bold":"true","italic":false,"underline":false,"inverse":false}]],"images":[]}""",
            """{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":"invalid"}""",
        )
        invalidFrames.forEach { frame ->
            assertTrue(runCatching { MilaTerminalFrame.decode(frame.toByteArray()) }.isFailure)
        }
    }

    @Test
    fun refusesCoercedSpanText() {
        for (text in listOf("7", "true", "null", "{}", "[]")) {
            val frame = """{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[[{"text":$text,"foreground":null,"background":null,"bold":false,"italic":false,"underline":false,"inverse":false}]],"images":[]}"""
            assertTrue(runCatching { MilaTerminalFrame.decode(frame.toByteArray()) }.isFailure)
        }
    }

    @Test
    fun acceptsLargeValidProjectionWithinTheJniBound() {
        val pixels = (0 until 1024 * 512).joinToString(",") { "16777215" }
        val bytes = """{"version":1,"columns":1,"rows":1,"cursor_column":0,"cursor_row":0,"lines":[],"images":[{"x":0,"y":0,"width":1024,"height":512,"pixels":[$pixels]}]}""".toByteArray()
        assertTrue(bytes.size > 4 shl 20)
        assertEquals(1024 * 512, MilaTerminalFrame.decode(bytes).images.single().pixels.size)
    }

    @Test
    fun refusesCombinedImageBudget() {
        val pixels = (0 until 1024 * 513).joinToString(",") { "0" }
        val image = """{"x":0,"y":0,"width":1024,"height":513,"pixels":[$pixels]}"""
        val oversized = """{"version":1,"columns":1,"rows":1,"cursor_column":0,"cursor_row":0,"lines":[],"images":[$image,$image]}"""
        assertTrue(runCatching { MilaTerminalFrame.decode(oversized.toByteArray()) }.isFailure)
    }
}
