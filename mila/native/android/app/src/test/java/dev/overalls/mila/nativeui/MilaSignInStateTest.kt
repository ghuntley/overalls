package dev.overalls.mila.nativeui
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
private class SignInAdapter(private val result: MilaFfiResult): MilaFfiAdapter { override suspend fun call(request: MilaFfiRequest)=result }

private class LifecycleAdapter(private val result: MilaFfiResult): MilaFfiAdapter, MilaSessionConnector {
 var clearedSessions = 0
 override suspend fun call(request: MilaFfiRequest) = result
 override fun connect(deployment: MilaDeployment, config: MilaSessionConnectConfig, signer: MilaDeviceKey): MilaSessionHandle? = null
 override fun bindSession(session: MilaSessionHandle?) { if (session == null) clearedSessions++ }
}

private class LifecycleStore : MilaDeploymentStore {
 var deployment: MilaDeployment? = null
 var approval = MilaApprovalState.Approved
 override fun read() = deployment
 override fun write(value: MilaDeployment) { deployment = value }
 override fun clear() { deployment = null }
 override fun readApproval() = approval
 override fun writeApproval(value: MilaApprovalState) { approval = value }
}

private class RefusedListingBindings(private val pendingFirst: Boolean) : FakeRustBindings() {
 var whoamiCalls = 0
 var listingCalls = 0
 var closeCalls = 0
 override fun sessionWhoami(handle: Long): ByteArray {
  whoamiCalls++
  return if (pendingFirst && whoamiCalls == 1) {
   "{\"version\":1,\"status\":\"approval_required\",\"approval_url\":\"https://mila.example/approve\",\"fingerprint\":\"SHA256:${"A".repeat(43)}\"}".toByteArray()
  } else "{\"version\":1,\"status\":\"succeeded\"}".toByteArray()
 }
 override fun sessionRead(handle: Long, more: Boolean): Int = -5
 override fun sessionListing(handle: Long): ByteArray {
  listingCalls++
  return "{\"machines\":[],\"has_more\":false}".toByteArray()
 }
 override fun sessionClose(handle: Long): Int { closeCalls++; return 0 }
}

private class RefusedListingAdapter(private val bindings: RefusedListingBindings) : MilaFfiAdapter, MilaSessionConnector {
 override suspend fun call(request: MilaFfiRequest): MilaFfiResult = MilaFfiResult.Failure(MilaFfiError.Unavailable)
 override fun connect(deployment: MilaDeployment, config: MilaSessionConnectConfig, signer: MilaDeviceKey): MilaSessionHandle =
  MilaSessionHandle(42L, bindings)
 override fun bindSession(session: MilaSessionHandle?) { }
}

private class PaginatedSignInBindings(private val pendingFirst: Boolean, refusedRead: Int? = null) :
 PaginatedListingBindings(refusedRead = refusedRead) {
 private var whoamiCalls = 0
 override fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle =
  MilaSessionHandle(42L, this)
 override fun sessionWhoami(handle: Long): ByteArray {
  whoamiCalls += 1
  return if (pendingFirst && whoamiCalls == 1) {
   "{\"version\":1,\"status\":\"approval_required\",\"approval_url\":\"https://mila.example/approve\",\"fingerprint\":\"SHA256:${"A".repeat(43)}\"}".toByteArray()
  } else "{\"version\":1,\"status\":\"succeeded\"}".toByteArray()
 }
}

class MilaSignInStateTest {
 // A fake connector never calls this signer's Android Keystore operations. Construct
 // only its inert alias for controller tests, without creating or exporting a key.
 private fun unusedSigner(): MilaDeviceKey = MilaDeviceKey::class.java
  .getDeclaredConstructor(String::class.java).apply { isAccessible = true }.newInstance("unused-test-key")

 @Test fun sessionConnectConfigRejectsMissingTrustAndKey() {
  assertThrows(IllegalArgumentException::class.java) { MilaSessionConnectConfig(byteArrayOf(), "ssh-key") }
  assertThrows(IllegalArgumentException::class.java) { MilaSessionConnectConfig(byteArrayOf(1), "") }
 }

 @Test fun successfulBootstrapProducesSignedInListing() = runBlocking {
  val payload = MilaFfiPayload("{\"machines\":[],\"has_more\":false}".toByteArray())
  val d=MilaDeployment("mila.example"); val c=MilaSignInController(SignInAdapter(MilaFfiResult.Success(MilaFfiResponse(payload))))
  c.signIn(d); assertEquals(MilaSignInState.SignedIn(d, MilaSessionListing(emptyList(),false)), c.state)
 }
 @Test fun failedBootstrapRetainsDeploymentAndError() = runBlocking {
  val d=MilaDeployment("mila.example"); val c=MilaSignInController(SignInAdapter(MilaFfiResult.Failure(MilaFfiError.Unavailable)))
  c.signIn(d); assertEquals(MilaSignInState.Failed(d,MilaFfiError.Unavailable), c.state)
 }

 @Test fun approvedSignInRefusesCachedListingAfterFailedRustRead() = runBlocking {
  val deployment = MilaDeployment("mila.example")
  val bindings = RefusedListingBindings(pendingFirst = false)
  val controller = MilaSignInController(RefusedListingAdapter(bindings))

  controller.signIn(deployment, MilaSessionConnectConfig(byteArrayOf(1), "unused-public-key"), unusedSigner())

  assertEquals(MilaSignInState.Failed(deployment, MilaFfiError.Unavailable), controller.state)
  assertEquals(0, bindings.listingCalls)
  assertEquals(1, bindings.closeCalls)
 }

 @Test fun approvalCompletionRefusesCachedListingAfterFailedRustRead() = runBlocking {
  val deployment = MilaDeployment("mila.example")
  val bindings = RefusedListingBindings(pendingFirst = true)
  val controller = MilaSignInController(RefusedListingAdapter(bindings))
  controller.signIn(deployment, MilaSessionConnectConfig(byteArrayOf(1), "unused-public-key"), unusedSigner())
  assertTrue(controller.state is MilaSignInState.AwaitingApproval)

  assertFalse(controller.pollApproval())

  assertEquals(MilaSignInState.Failed(deployment, MilaFfiError.Unavailable), controller.state)
  assertEquals(0, bindings.listingCalls)
  assertEquals(1, bindings.closeCalls)
 }

 @Test fun initialAndApprovedSignInLoadEveryPageBeforePublishing() = runBlocking {
  for (pendingFirst in listOf(false, true)) {
   val deployment = MilaDeployment("mila.example")
   val bindings = PaginatedSignInBindings(pendingFirst)
   val adapter = LinkedMilaFfiAdapter(bindings)
   val controller = MilaSignInController(adapter)
   controller.signIn(deployment, MilaSessionConnectConfig(byteArrayOf(1), "unused-public-key"), unusedSigner())
   if (pendingFirst) {
    assertTrue(controller.state is MilaSignInState.AwaitingApproval)
    assertTrue(bindings.pages.isEmpty())
    assertTrue(controller.pollApproval())
   }

   val listing = (controller.state as MilaSignInState.SignedIn).listing
   assertFalse(listing.hasMore)
   assertEquals(500, listing.machines.size)
   assertEquals(listOf(false, true), bindings.pages)
   assertTrue(adapter.snapshotData().isSuccess)
   assertEquals(0, bindings.closeCalls)
  }
 }

 @Test fun failedContinuationPreventsInitialAndApprovedSignIn() = runBlocking {
  for (pendingFirst in listOf(false, true)) {
   val deployment = MilaDeployment("mila.example")
   val bindings = PaginatedSignInBindings(pendingFirst, refusedRead = 2)
   val controller = MilaSignInController(LinkedMilaFfiAdapter(bindings))
   controller.signIn(deployment, MilaSessionConnectConfig(byteArrayOf(1), "unused-public-key"), unusedSigner())
   if (pendingFirst) assertFalse(controller.pollApproval())

   assertEquals(MilaSignInState.Failed(deployment, MilaFfiError.Unavailable), controller.state)
   assertEquals(listOf(false, true), bindings.pages)
   assertEquals(1, bindings.listingReads)
   assertEquals(1, bindings.closeCalls)
  }
 }

 @Test fun reconnectClearsStaleApprovalBeforeFailedAttempt() = runBlocking {
  val d = MilaDeployment("mila.example")
  val store = LifecycleStore()
  val controller = MilaSignInController(
   SignInAdapter(MilaFfiResult.Failure(MilaFfiError.Unavailable)), store
  )
  store.write(d)
  assertFalse(controller.reconnect())
  assertEquals(MilaApprovalState.NotRequired, store.readApproval())
 }

 @Test fun closingControllerReleasesSessionAndKeepsReconnectSelection() = runBlocking {
  val d = MilaDeployment("mila.example")
  val store = LifecycleStore()
  val adapter = LifecycleAdapter(
   MilaFfiResult.Success(MilaFfiResponse(MilaFfiPayload("{\"machines\":[],\"has_more\":false}".toByteArray())))
  )
  val controller = MilaSignInController(adapter, store)

  controller.signIn(d)
  assertEquals(1, adapter.clearedSessions)
  controller.close()
  assertEquals(MilaSignInState.SignedOut, controller.state)
  assertEquals(MilaApprovalState.NotRequired, store.readApproval())
  assertEquals(2, adapter.clearedSessions)
  assertEquals(d, store.read())

  assertTrue(controller.reconnect())
  assertEquals(3, adapter.clearedSessions)
  assertEquals(MilaSignInState.SignedIn(d, MilaSessionListing(emptyList(), false)), controller.state)
 }
}
