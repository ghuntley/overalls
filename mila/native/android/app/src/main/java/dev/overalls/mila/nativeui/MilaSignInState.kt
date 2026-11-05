package dev.overalls.mila.nativeui

/** Explicit sign-in/session state; credentials remain inside the Rust adapter. */
sealed interface MilaSignInState {
 data object SignedOut : MilaSignInState
 data class Connecting(val deployment: MilaDeployment) : MilaSignInState
 data class AwaitingApproval(val deployment: MilaDeployment, val approval: MilaApprovalInfo) : MilaSignInState
 data class Expired(val deployment: MilaDeployment) : MilaSignInState
 data class SignedIn(val deployment: MilaDeployment, val listing: MilaSessionListing, val approval: MilaApprovalState = MilaApprovalState.NotRequired) : MilaSignInState
 data class Failed(val deployment: MilaDeployment, val error: MilaFfiError) : MilaSignInState
}

class MilaSignInController(private val adapter: MilaFfiAdapter, private val store: MilaDeploymentStore? = null, private val clock: () -> Long = { System.currentTimeMillis() / 1000 }) : AutoCloseable {
 var state: MilaSignInState = MilaSignInState.SignedOut; private set
 private var pendingSession: MilaSessionHandle? = null

 /**
  * @cc [owner:ghuntley,label:security;recovery] android-signin-fresh-listing
  * Sign-in and approval completion MUST publish SignedIn only after Rust accepts a fresh
  * machine read; a failed read MUST close the session without consuming its cached listing.
  */
 suspend fun signIn(deployment: MilaDeployment, config: MilaSessionConnectConfig, signer: MilaDeviceKey) {
  store?.write(deployment)
  // A fresh connection attempt must not inherit approval from a previous session.
  // Approval is re-established by whoami below, or explicitly marked pending.
  store?.writeApproval(MilaApprovalState.NotRequired)
  // A new attempt owns the adapter's session. Release a previous attempt before
  // connecting so a refused reconnect cannot leave the old authenticated channel live.
  pendingSession?.close()
  pendingSession = null
  (adapter as? MilaSessionConnector)?.bindSession(null)
  state = MilaSignInState.Connecting(deployment)
  val connector = adapter as? MilaSessionConnector
  val session = runCatching {
   require(connector != null) { "native session connector unavailable" }
   connector.connect(deployment, config, signer) ?: error("session connection refused")
  }.getOrNull()
  if (session == null) {
   state = MilaSignInState.Failed(deployment, MilaFfiError.Unavailable)
   return
  }
  when (val whoami = runCatching { MilaApprovalInfo.decode(session.whoami(), deployment.host) }.getOrDefault(MilaWhoami.Invalid)) {
   is MilaWhoami.Pending -> {
    pendingSession = session
    connector?.bindSession(session)
    store?.writeApproval(MilaApprovalState.Pending)
    state = MilaSignInState.AwaitingApproval(deployment, whoami.approval)
    return
   }
   MilaWhoami.Invalid, MilaWhoami.Refused -> {
    session.close()
    state = MilaSignInState.Failed(deployment, MilaFfiError.Unavailable)
    return
   }
   MilaWhoami.Approved -> Unit
  }
  val listing = runCatching {
   MilaSessionListing.decode(session.readCompleteListing())
  }.getOrNull()
  if (listing == null) {
   session.close()
   state = MilaSignInState.Failed(deployment, MilaFfiError.Unavailable)
  } else {
   pendingSession = null
   connector?.bindSession(session)
   state = MilaSignInState.SignedIn(deployment, listing, store?.readApproval() ?: MilaApprovalState.NotRequired)
  }
 }
 /** Re-checks the same SSH connection after browser approval; no new key or session is created. */
 suspend fun pollApproval(): Boolean {
  val awaiting = state as? MilaSignInState.AwaitingApproval ?: return state is MilaSignInState.SignedIn
  val session = pendingSession ?: return false.also { state = MilaSignInState.Failed(awaiting.deployment, MilaFfiError.Unavailable) }
  if (clock() - awaiting.approval.issuedAt >= APPROVAL_LIFETIME_SECONDS) {
   session.close()
   pendingSession = null
   store?.writeApproval(MilaApprovalState.Expired)
   state = MilaSignInState.Expired(awaiting.deployment)
   return false
  }
  val whoamiPayload = runCatching { session.whoami() }.getOrElse {
   session.close()
   pendingSession = null
   state = MilaSignInState.Failed(awaiting.deployment, MilaFfiError.Unavailable)
   return false
  }
  val whoami = MilaApprovalInfo.decode(whoamiPayload, awaiting.deployment.host)
  return when (whoami) {
   MilaWhoami.Approved -> {
    val listing = runCatching {
     MilaSessionListing.decode(session.readCompleteListing())
    }.getOrNull()
    if (listing == null) {
     session.close()
     pendingSession = null
     state = MilaSignInState.Failed(awaiting.deployment, MilaFfiError.Unavailable)
     false
    } else {
     store?.writeApproval(MilaApprovalState.Approved)
     pendingSession = null
     state = MilaSignInState.SignedIn(awaiting.deployment, listing, MilaApprovalState.Approved)
     true
    }
   }
   is MilaWhoami.Pending -> {
    // The control plane may rotate a short-lived approval URL while the same
    // certificate session remains pending. Publish the newest validated
    // envelope so the browser action and expiry timer never use stale data.
    state = MilaSignInState.AwaitingApproval(awaiting.deployment, whoami.approval)
    store?.writeApproval(MilaApprovalState.Pending)
    true
   }
   MilaWhoami.Refused, MilaWhoami.Invalid -> {
    session.close()
    pendingSession = null
    state = MilaSignInState.Failed(awaiting.deployment, MilaFfiError.Unavailable)
    false
   }
  }
 }
 suspend fun signIn(deployment: MilaDeployment) {
  store?.write(deployment)
  store?.writeApproval(MilaApprovalState.NotRequired)
  // Legacy bootstrap reconnects must release any approval session before rebinding.
  pendingSession?.close()
  pendingSession = null
  (adapter as? MilaSessionConnector)?.bindSession(null)
  state = MilaSignInState.Connecting(deployment)
  state = when (val result = adapter.call(MilaFfiRequest(MilaFfiOperation.Bootstrap))) {
   is MilaFfiResult.Failure -> MilaSignInState.Failed(deployment, result.error)
   is MilaFfiResult.Success -> runCatching { MilaSessionListing.decode(result.response.payload.copyBytes()) }
    .fold({ MilaSignInState.SignedIn(deployment, it, store?.readApproval() ?: MilaApprovalState.NotRequired) }, { MilaSignInState.Failed(deployment, MilaFfiError.Unavailable) })
  }
 }
 suspend fun reconnect(): Boolean {
  val deployment = store?.read() ?: return false
  signIn(deployment)
  return state is MilaSignInState.SignedIn
 }

 /** Reconnects through the certificate-authenticated Rust session when the caller supplies
  * the same deployment material and non-exportable signer. The legacy bootstrap path is not
  * used for a packaged reconnect. */
 suspend fun reconnect(config: MilaSessionConnectConfig, signer: MilaDeviceKey): Boolean {
  val deployment = store?.read() ?: return false
  signIn(deployment, config, signer)
  return state is MilaSignInState.SignedIn
 }
 fun setApproval(state: MilaApprovalState) {
  val signedIn = this.state as? MilaSignInState.SignedIn ?: return
  store?.writeApproval(state)
  this.state = signedIn.copy(approval = state)
 }
 /**
  * @cc [owner:ghuntley,label:security] mila-android-session-close
  * Closing an Android sign-in controller MUST release its adapter-owned authenticated session and
  * MUST retain the validated deployment selection so a later controller can reconnect without
  * retaining credentials in UI state.
  */
 fun signOut() {
  pendingSession?.close()
  pendingSession = null
  (adapter as? MilaSessionConnector)?.bindSession(null)
  store?.writeApproval(MilaApprovalState.NotRequired)
  state = MilaSignInState.SignedOut
 }

 override fun close() = signOut()

 private companion object { const val APPROVAL_LIFETIME_SECONDS = 600L }
}
