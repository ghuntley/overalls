package dev.overalls.mila.nativeui

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import java.net.URI
import java.util.UUID
import kotlinx.coroutines.launch

/** Validated endpoint returned by the Rust web command. */
data class MilaWebEndpoint(val machineId: UUID, val port: Int, val public: Boolean, val revision: Long, val url: String?)

fun parseMilaWebEndpoint(json: String): Result<MilaWebEndpoint> = runCatching {
    // Porsche wraps reads in a `{version, status, result}` envelope; accept the bare form too.
    val o = JSONObject(json).let { it.optJSONObject("result") ?: it }
    val id = UUID.fromString(o.getString("machine_id"))
    val port = o.getInt("port").also { require(it in 1..65535) }
    val visibility = o.getString("visibility").also { require(it == "public" || it == "private") }
    val revision = o.getLong("policy_revision").also { require(it > 0) }
    val url = if (o.isNull("url")) null else o.getString("url").also {
        validateHttps(it)
        // Porsche may return a public proxy URL without the machine's port in
        // its authority. Only an explicitly supplied URI port must match.
        val parsed = URI(it)
        require(parsed.port == -1 || parsed.port == port)
    }
    MilaWebEndpoint(id, port, visibility == "public", revision, url)
}

private fun validateHttps(value: String) {
    require(value.length <= 2048)
    val uri = URI(value)
    require(uri.scheme == "https" && uri.userInfo == null && uri.fragment == null)
    require(uri.host != null && uri.host.matches(Regex("^[A-Za-z0-9.-]+$")))
}

/**
 * @cc [owner:mila,label:security] webview-origin-fence
 * Embedded navigation remains on the exact HTTPS origin returned by Rust.
 */
internal fun isAllowedMilaWebTarget(base: String, target: String): Boolean = runCatching {
    validateHttps(base)
    validateHttps(target)
    val origin = URI(base)
    val candidate = URI(target)
    origin.host.equals(candidate.host, ignoreCase = true) &&
        effectivePort(origin) == effectivePort(candidate)
}.getOrDefault(false)

private fun effectivePort(uri: URI): Int = if (uri.port == -1) 443 else uri.port

class MilaWebController(private val adapter: MilaFfiAdapter) {
    private var signedIn: Boolean = false
    private var sessionGeneration: Long = 0
    fun setSession(authenticated: Boolean) {
        sessionGeneration += 1
        signedIn = authenticated
        // Never carry a web endpoint across authentication generations.
        clear()
    }
    var endpoint by mutableStateOf<MilaWebEndpoint?>(null); private set
    var error by mutableStateOf<String?>(null); private set
    fun clear() { endpoint = null; error = null }
    suspend fun setFromText(machine: UUID, value: String, public: Boolean): Boolean {
        val port = value.toIntOrNull()
        if (port == null) {
            error = "web port must be a number"
            return false
        }
        return set(machine, port, public)
    }
    suspend fun show(machine: UUID): Boolean = runCatching {
        check(signedIn) { "web controls require sign-in" }
        val generation = sessionGeneration
        val result = adapter.webShow(machine).getOrThrow()
        check(signedIn && generation == sessionGeneration) { "stale web response" }
        endpoint = parseMilaWebEndpoint(result).getOrThrow().also { require(it.machineId == machine) { "web endpoint machine mismatch" } }
        error = null
    }.onFailure { error = it.message ?: "web endpoint unavailable" }.isSuccess
    suspend fun set(machine: UUID, port: Int, public: Boolean): Boolean = runCatching {
        check(signedIn) { "web controls require sign-in" }
        require(port in 1..65535)
        val current = endpoint?.also { require(it.machineId == machine) }
            ?: error("load endpoint before changing it")
        adapter.webSet(machine, port, public, current.revision).getOrElse { failure ->
            // Preserve the endpoint revision on conflicts so the UI can reload it
            // and retry with the server's current optimistic-concurrency token.
            throw IllegalStateException(
                if (failure.message?.contains("revision", ignoreCase = true) == true) {
                    "web policy revision conflict"
                } else {
                    failure.message ?: "web endpoint rejected"
                },
                failure,
            )
        }
        show(machine)
    }.onFailure { error = it.message ?: "web endpoint rejected" }.isSuccess
}

@Composable
fun MilaWebView(url: String, modifier: Modifier = Modifier) {
    var webViewRef by remember { mutableStateOf<WebView?>(null) }
    DisposableEffect(url) {
        onDispose {
            webViewRef?.apply {
                stopLoading()
                loadUrl("about:blank")
                clearHistory()
                clearCache(true)
            }
            webViewRef = null
        }
    }
    AndroidView(modifier = modifier, factory = { context ->
        WebView(context).apply {
            settings.javaScriptEnabled = true
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, target: String): Boolean =
                    !isAllowedMilaWebTarget(url, target)
            }
            loadUrl(url)
            webViewRef = this
        }
    }, update = { if (it.url != url) it.loadUrl(url) })
}

@Composable
fun MilaWebControls(adapter: MilaFfiAdapter, machine: MilaMachineRow, signedIn: Boolean) {
    val controller = remember { MilaWebController(adapter) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(machine.id, signedIn) { controller.setSession(signedIn); if (signedIn) controller.show(machine.id) }
    var port by remember { mutableStateOf("") }
    var public by remember { mutableStateOf(true) }
    LaunchedEffect(controller.endpoint?.revision) {
        controller.endpoint?.let { port = it.port.toString(); public = it.public }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(MilaStrings.text(MilaMessage.WebEndpoint))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Button(enabled = signedIn, onClick = { scope.launch { controller.show(machine.id) } }) { Text(MilaStrings.text(MilaMessage.WebShow)) }
            Button(enabled = signedIn, onClick = { scope.launch { controller.setFromText(machine.id, port, public) } }) { Text(MilaStrings.text(MilaMessage.WebSave)) }
        }
        OutlinedTextField(port, { port = it }, label = { Text(MilaStrings.text(MilaMessage.WebPort)) })
        controller.endpoint?.let { endpoint ->
            Text(if (endpoint.public) MilaStrings.text(MilaMessage.WebPublic) else MilaStrings.text(MilaMessage.WebPrivate))
            Text("Revision ${endpoint.revision}")
            endpoint.url?.let { MilaWebView(it, Modifier) }
        }
        controller.error?.let { Text(it) }
    }
}
