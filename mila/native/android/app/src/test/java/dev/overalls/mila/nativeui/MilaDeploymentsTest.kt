package dev.overalls.mila.nativeui

import org.junit.Assert.*
import org.junit.Test

class MilaDeploymentsTest {
 @Test fun userHostIsCanonicalizedBeforePersistence(){
  val deployment = parseMilaDeploymentHost("  Overalls.Example:8443 ").getOrThrow()
  assertEquals("overalls.example", deployment.host)
  assertEquals(8443, deployment.port)
  assertEquals("overalls.example:8443", deployment.label)
 }
 @Test fun malformedUserHostNeverCreatesDeployment(){
  assertTrue(parseMilaDeploymentHost("localhost").isFailure)
  assertTrue(parseMilaDeploymentHost("overalls.example:0").isFailure)
  assertTrue(parseMilaDeploymentHost("overalls.example:65536").isFailure)
  assertTrue(parseMilaDeploymentHost("overalls.example:8443:22").isFailure)
 }
 @Test fun selectionDeduplicatesAndSelectsKnownHost() {
  val model = MilaDeploymentSelection(listOf(MilaDeployment("mila.example"), MilaDeployment("mila.example")))
  assertEquals(1, model.deployments.size)
  assertTrue(model.select("mila.example"))
  assertFalse(model.select("other.example"))
 }
 @Test fun forgetRemovesSelectedDeploymentAndSelectsNext() {
  val model = MilaDeploymentSelection(listOf(MilaDeployment("one.example"), MilaDeployment("two.example")))
  assertTrue(model.remove("one.example"))
  assertEquals("two.example", model.selected?.host)
  assertFalse(model.remove("missing.example"))
 }
 @Test(expected = IllegalArgumentException::class) fun invalidHostRejected() { MilaDeployment("localhost") }
 @Test(expected = IllegalArgumentException::class) fun invalidPortRejected() { MilaDeployment("mila.example", 70000) }
 @Test(expected = IllegalArgumentException::class) fun unsafeLabelRejected() { MilaDeployment("mila.example", label = "bad\nlabel") }
 @Test(expected = IllegalArgumentException::class) fun oversizedUtf8LabelRejected() { MilaDeployment("mila.example", label = "é".repeat(65)) }

    @Test fun loopbackIsRefusedUnlessInstrumentationEnablesIt() {
        assertTrue(parseMilaDeploymentHost("localhost:2222").isFailure)
        assertTrue(runCatching { MilaDeployment("localhost", 2222) }.isFailure)
        MilaInstrumentationLoopback.allowed = true
        try {
            assertEquals("localhost", MilaDeployment("localhost", 2222).host)
            assertTrue(runCatching { MilaDeployment("localhost.", 22) }.isFailure)
        } finally {
            MilaInstrumentationLoopback.allowed = false
        }
        assertTrue(runCatching { MilaDeployment("localhost", 2222) }.isFailure)
    }
}
