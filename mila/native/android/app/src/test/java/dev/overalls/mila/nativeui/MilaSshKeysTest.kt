package dev.overalls.mila.nativeui
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.UUID
private class Keys: MilaSshKeyStore { var values=mutableListOf(MilaSshKey("fp1","phone"), MilaSshKey("","bad")); override fun list()=values; override fun revoke(f:String):Boolean { val n=values.removeIf{it.fingerprint==f}; return n } }
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MilaSshKeysTest {
 @Test fun listsOnlyIdentifiedKeysAndRevokes(){ val k=Keys(); val c=MilaSshKeyController(k); assertEquals(1,c.keys.size); assertTrue(c.revoke("fp1")); assertTrue(c.keys.isEmpty()); assertFalse(c.revoke("missing")) }

 @Test fun authenticatedStoreDecodesBoundedRowsAndUsesOpaqueId() {
  val id = UUID.fromString("00000000-0000-0000-0000-000000000001")
  val bindings = object : AndroidKeysRustBindings() {
   var revoked: Pair<String, String>? = null
   override fun sessionSshKeys(handle: Long): ByteArray? = "{\"keys\":[{\"id\":\"$id\",\"label\":\"phone\",\"algorithm\":\"ssh-ed25519\",\"fingerprint\":\"SHA256:test\"}]}".toByteArray()
   override fun sessionSshKeyRevoke(handle: Long, key: String, requestId: String): Int { revoked = key to requestId; return 0 }
  }
  val controller = MilaSshKeyController(MilaSessionSshKeyStore(MilaSessionHandle(7, bindings)))
  assertEquals(id, controller.keys.single().id)
  assertTrue(controller.revoke(controller.keys.single()))
  assertEquals(id.toString(), bindings.revoked?.first)
  assertTrue(bindings.revoked?.second?.matches(Regex("porsche-[0-9a-f]{32}")) == true)
 }

 @Test fun uncertainRevokeReusesTheSameRequestId() {
  val id = UUID.fromString("00000000-0000-0000-0000-000000000006")
  val bindings = object : AndroidKeysRustBindings() {
   var requests = mutableListOf<String>()
   var attempts = 0
   override fun sessionSshKeys(handle: Long): ByteArray? = "{\"keys\":[{\"id\":\"$id\",\"label\":\"phone\",\"algorithm\":\"ssh-ed25519\",\"fingerprint\":\"SHA256:test\"}]}".toByteArray()
   override fun sessionSshKeyRevoke(handle: Long, key: String, requestId: String): Int {
    requests += requestId
    attempts += 1
    return if (attempts == 1) -11 else 0
   }
  }
  val store = MilaSessionSshKeyStore(MilaSessionHandle(11, bindings))
  assertFalse(store.revoke(id.toString()))
  assertTrue(store.revoke(id.toString()))
  assertEquals(2, bindings.requests.size)
  assertEquals(bindings.requests[0], bindings.requests[1])
 }

 @Test fun malformedWhitespaceProjectionFailsClosed() {
  val bindings = object : AndroidKeysRustBindings() {
   override fun sessionSshKeys(handle: Long): ByteArray? = "{\"keys\":[{\"id\":\"00000000-0000-0000-0000-000000000003\",\"fingerprint\":\"SHA256: bad\",\"algorithm\":\"ssh-ed25519\",\"label\":\"phone\"}]}".toByteArray()
  }
  val controller = MilaSshKeyController(MilaSessionSshKeyStore(MilaSessionHandle(8, bindings)))
  assertTrue(controller.keys.isEmpty())
 }

 @Test fun oversizedUtf8DisplayValuesFailClosed() {
  val bindings = object : AndroidKeysRustBindings() {
   override fun sessionSshKeys(handle: Long): ByteArray? = ("{\"keys\":[{" +
    "\"id\":\"00000000-0000-0000-0000-000000000004\"," +
    "\"fingerprint\":\"SHA256:test\",\"algorithm\":\"ssh-ed25519\"," +
    "\"label\":\"" + "é".repeat(200) + "\"}]}" ).toByteArray()
  }
  val controller = MilaSshKeyController(MilaSessionSshKeyStore(MilaSessionHandle(9, bindings)))
  assertTrue(controller.keys.isEmpty())
 }

 @Test fun utf8DisplayBoundIsStableAcrossMultibyteInputs() {
  // Exercise the byte bound with several Unicode widths; every generated
  // value over 256 bytes must fail closed regardless of code-point count.
  listOf("é", "中", "🙂").forEach { unit ->
   val label = unit.repeat(257)
   val bindings = object : AndroidKeysRustBindings() {
    override fun sessionSshKeys(handle: Long): ByteArray? = ("{\"keys\":[{" +
     "\"id\":\"00000000-0000-0000-0000-000000000005\"," +
     "\"fingerprint\":\"SHA256:test\",\"algorithm\":\"ssh-ed25519\"," +
     "\"label\":\"" + label + "\"}]}").toByteArray()
   }
   assertTrue(MilaSshKeyController(MilaSessionSshKeyStore(MilaSessionHandle(10, bindings))).keys.isEmpty())
  }
 }

 @Test fun unbindingSessionClearsKeysAndRefusesRevoke() {
  val store = Keys()
  val controller = MilaSshKeyController(store)
  assertEquals(1, controller.keys.size)
  controller.bindStore(null)
  assertTrue(controller.keys.isEmpty())
  assertFalse(controller.revoke("fp1"))
 }

 @Test fun refreshClearsProjectionWhenSessionStoreCloses() {
  val store = object : MilaSshKeyStore {
   override fun list(): List<MilaSshKey> = error("closed session")
   override fun revoke(fingerprint: String): Boolean = error("closed session")
  }
  val controller = MilaSshKeyController(Keys())
  assertFalse(controller.keys.isEmpty())
  controller.bindStore(store)
  assertTrue(controller.keys.isEmpty())
  assertFalse(controller.revoke("fp1"))
 }

 @Test fun currentDeviceCannotBeRevoked() {
  val id = UUID.fromString("00000000-0000-0000-0000-000000000002")
  val store = object : MilaSshKeyStore {
   override fun list() = listOf(MilaSshKey(id, "SHA256:device", "ssh-ed25519", "phone", true))
   override fun revoke(fingerprint: String) = error("must not revoke")
  }
  assertFalse(MilaSshKeyController(store).revoke("SHA256:device"))
 }

 @Test fun staleRevokeCannotRefreshNewSessionProjection() {
  lateinit var controller: MilaSshKeyController
  val old = object : MilaSshKeyStore {
   override fun list() = listOf(MilaSshKey("old", "old"))
   override fun revoke(fingerprint: String): Boolean {
    controller.bindStore(object : MilaSshKeyStore {
     override fun list() = listOf(MilaSshKey("new", "new"))
     override fun revoke(fingerprint: String) = false
    })
    return true
   }
  }
  controller = MilaSshKeyController(old)
  assertTrue(controller.revoke("old"))
  assertEquals(listOf("new"), controller.keys.map { it.fingerprint })
 }
}

private open class AndroidKeysRustBindings : MilaRustBindings {
 override fun abiVersion() = 1
 override fun canonicalRoute(value: String): String? = value
 override fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int? = 0
 override fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle? = null
 override fun threadCommandKind(value: String) = 1
 override fun machineCommandKind(value: String) = 1
 override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean) = 0
 override fun terminalInput(length: Int, readWrite: Boolean) = 0
 override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean) = 0
}
