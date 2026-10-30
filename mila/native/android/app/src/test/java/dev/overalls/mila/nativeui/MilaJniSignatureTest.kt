package dev.overalls.mila.nativeui

import java.io.File
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Checks every `external fun` on [MilaRustFfi] against the Rust `Java_..._MilaRustFfi_*` export of
 * the same name in `mila-ffi`. A Kotlin `Long?` return, for example, is a boxed `java.lang.Long`
 * object to JNI while Rust returns a primitive `jlong`; ART then treats the handle as an object
 * reference and the process crashes on the first successful call.
 */
class MilaJniSignatureTest {
    private sealed interface JniType {
        data class Exact(val type: Class<*>) : JniType
        /** Any reference type: Rust receives or returns an untyped `jobject`. */
        data object Reference : JniType
    }

    private data class Export(val name: String, val parameters: List<JniType>, val result: JniType)

    private val source: File = listOf("../../../rust/mila-ffi/src/lib.rs", "../../../../rust/mila-ffi/src/lib.rs")
        .map(::File).firstOrNull(File::isFile) ?: error("mila-ffi lib.rs not found from ${File(".").absolutePath}")

    private fun jniType(rust: String): JniType = when (rust.substringAfterLast("::").substringBefore("<").trim()) {
        "jlong" -> JniType.Exact(java.lang.Long.TYPE)
        "jint" -> JniType.Exact(Integer.TYPE)
        "jboolean" -> JniType.Exact(java.lang.Boolean.TYPE)
        "jbyteArray", "JByteArray" -> JniType.Exact(ByteArray::class.java)
        "jstring", "JString" -> JniType.Exact(String::class.java)
        "jobject", "JObject" -> JniType.Reference
        else -> error("unmapped JNI type $rust")
    }

    private fun exports(): Map<String, Export> {
        val pattern = Regex(
            """extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_(\w+)\s*\((.*?)\)\s*(?:->\s*([\w:]+))?\s*\{""",
            RegexOption.DOT_MATCHES_ALL,
        )
        return pattern.findAll(source.readText()).associate { match ->
            val (name, parameters, result) = match.destructured
            val types = parameters.split(',').map(String::trim).filter(String::isNotEmpty)
                .map { it.substringAfter(':').trim() }
            assertTrue("$name must take JNIEnv and JClass first", types.size >= 2 && "JNIEnv" in types[0] && "JClass" in types[1])
            name to Export(
                name,
                types.drop(2).map(::jniType),
                if (result.isBlank()) JniType.Exact(Void.TYPE) else jniType(result),
            )
        }
    }

    private fun matches(expected: JniType, actual: Class<*>): Boolean = when (expected) {
        is JniType.Exact -> expected.type == actual
        JniType.Reference -> !actual.isPrimitive
    }

    @Test fun everyExternalMatchesItsRustExport() {
        val rust = exports()
        val natives: List<Method> = MilaRustFfi::class.java.declaredMethods.filter { Modifier.isNative(it.modifiers) }
        assertTrue("MilaRustFfi declares no external functions", natives.isNotEmpty())
        for (method in natives) {
            val export = rust[method.name] ?: throw AssertionError("${method.name} has no Rust export")
            assertEquals("${method.name} parameter count", export.parameters.size, method.parameterTypes.size)
            export.parameters.zip(method.parameterTypes).forEachIndexed { index, (expected, actual) ->
                assertTrue("${method.name} parameter $index is ${actual.name}, Rust expects $expected", matches(expected, actual))
            }
            assertTrue("${method.name} returns ${method.returnType.name}, Rust returns ${export.result}", matches(export.result, method.returnType))
        }
    }
}
