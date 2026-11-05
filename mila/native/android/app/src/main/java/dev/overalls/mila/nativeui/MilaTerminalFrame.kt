package dev.overalls.mila.nativeui

import android.graphics.Bitmap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import org.json.JSONArray
import org.json.JSONObject

class MilaTerminalSpan(
    val text: String, val foreground: Long?, val background: Long?,
    val bold: Boolean, val italic: Boolean, val underline: Boolean, val inverse: Boolean,
)

/** Display-only cells from Rust's VT parser; no escape strings reach Compose. */
class MilaTerminalImage(val x: Int, val y: Int, val width: Int, val height: Int, val pixels: IntArray) {
    fun bitmap(): ImageBitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888).asImageBitmap()
}

class MilaTerminalFrame(val columns: Int, val rows: Int, val lines: List<List<MilaTerminalSpan>>, val images: List<MilaTerminalImage> = emptyList()) {
    fun annotated(): AnnotatedString = buildAnnotatedString {
        for ((index, line) in lines.withIndex()) {
            if (index != 0) append('\n')
            for (span in line) {
                val foreground = if (span.inverse) span.background ?: 0x101010L else span.foreground
                val background = if (span.inverse) span.foreground ?: 0xd0d0d0L else span.background
                withStyle(SpanStyle(
                    color = foreground?.let { Color((0xff000000L or it).toInt()) } ?: Color.Unspecified,
                    background = background?.let { Color((0xff000000L or it).toInt()) } ?: Color.Unspecified,
                    fontWeight = if (span.bold) FontWeight.Bold else FontWeight.Normal,
                    fontStyle = if (span.italic) FontStyle.Italic else FontStyle.Normal,
                    textDecoration = if (span.underline) TextDecoration.Underline else TextDecoration.None,
                    fontFamily = FontFamily.Monospace,
                )) { append(span.text) }
            }
        }
    }

    companion object {
        private fun JSONObject.integer(key: String): Int {
            val value = get(key)
            require(value is Int)
            return value
        }

        private fun JSONArray.integer(index: Int): Int {
            val value = get(index)
            require(value is Int)
            return value
        }

        private fun JSONObject.boolean(key: String): Boolean {
            val value = get(key)
            require(value is Boolean)
            return value
        }

        private fun JSONObject.string(key: String): String {
            val value = get(key)
            require(value is String)
            return value
        }

        /**
         * @cc [owner:ghuntley,label:security;terminal] android-terminal-image-frame-bounds
         * Frame decoding MUST accept the JNI's 16 MiB bounded projection and
         * refuse image pixels outside 24-bit RGB or more than 1,048,576 pixels
         * across the frame before constructing Android bitmaps. JSON scalar
         * types MUST be validated without coercing strings or fractions.
         */
        fun decode(bytes: ByteArray): MilaTerminalFrame {
            require(bytes.size <= 16 shl 20)
            val root = JSONObject(bytes.toString(Charsets.UTF_8))
            require(root.integer("version") == 1)
            val columns = root.integer("columns"); val rows = root.integer("rows")
            require(columns in 1..4096 && rows in 1..512)
            require(root.integer("cursor_column") in 0 until columns && root.integer("cursor_row") in 0 until rows)
            val source = root.getJSONArray("lines"); require(source.length() <= rows)
            var count = 0
            val lines = List(source.length()) { row ->
                val sourceLine = source.getJSONArray(row)
                require(sourceLine.length() <= columns)
                var width = 0
                List(sourceLine.length()) { index ->
                    val span = sourceLine.getJSONObject(index)
                    val text = span.string("text")
                    require(text.none(Char::isISOControl))
                    width += text.codePointCount(0, text.length)
                    fun rgb(key: String): Long? = if (span.isNull(key)) null else span.integer(key).also { require(it in 0..0xffffff) }.toLong()
                    MilaTerminalSpan(text, rgb("foreground"), rgb("background"), span.boolean("bold"), span.boolean("italic"), span.boolean("underline"), span.boolean("inverse"))
                }.also { require(width <= columns); count += width; require(count <= 16_384) }
            }
            val images = buildList {
                val sourceImages = root.getJSONArray("images")
                require(sourceImages.length() <= 8)
                var totalPixels = 0
                for (index in 0 until sourceImages.length()) {
                    val sourceImage = sourceImages.getJSONObject(index)
                    val x = sourceImage.integer("x"); val y = sourceImage.integer("y")
                    val width = sourceImage.integer("width"); val height = sourceImage.integer("height")
                    require(x in 0..65535 && y in 0..65535 && width in 1..1024 && height in 1..1024 && width * height <= 1 shl 20)
                    val sourcePixels = sourceImage.getJSONArray("pixels"); require(sourcePixels.length() == width * height)
                    totalPixels += sourcePixels.length()
                    require(totalPixels <= 1 shl 20)
                    val pixels = IntArray(sourcePixels.length()) { pixel ->
                        val rgb = sourcePixels.integer(pixel)
                        require(rgb in 0..0xffffff)
                        0xff000000.toInt() or rgb
                    }
                    add(MilaTerminalImage(x, y, width, height, pixels))
                }
            }
            return MilaTerminalFrame(columns, rows, lines, images)
        }
    }
}
