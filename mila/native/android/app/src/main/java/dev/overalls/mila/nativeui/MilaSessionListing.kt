package dev.overalls.mila.nativeui

import java.util.UUID

data class MilaMachineRow(val id: UUID, val name: String, val status: String)
data class MilaSessionListing(val machines: List<MilaMachineRow>, val hasMore: Boolean) {
    companion object {
        private const val MAX_DISPLAY_BYTES = 128

        private fun boundedDisplay(value: String, fallback: String): String {
            val candidate = if (value.isEmpty()) fallback else value
            require(candidate.toByteArray(Charsets.UTF_8).size <= MAX_DISPLAY_BYTES) { "display text exceeds bound" }
            require(candidate.none { it.isISOControl() }) { "display text contains control character" }
            require(!candidate.contains("\\n") && !candidate.contains("\\r") && !candidate.contains("\\t")) {
                "display text contains escaped control character"
            }
            return candidate
        }

        /**
         * @cc [owner:ghuntley,label:protocol] android-listing-json-decode
         * Android MUST decode the Rust session listing as JSON (object key order is not part of
         * the contract; serde_json emits sorted keys) and refuse malformed or oversized rows.
         * A row's status is its observed state, else its desired state.
         */
        fun decode(bytes: ByteArray): MilaSessionListing {
            require(bytes.size <= 8 * 1024 * 1024) { "listing exceeds bound" }
            val root = org.json.JSONObject(bytes.toString(Charsets.UTF_8))
            val rows = root.optJSONArray("machines") ?: throw IllegalArgumentException("machines missing")
            require(rows.length() <= 10_000) { "too many machines" }
            val machines = (0 until minOf(rows.length(), 257)).map { index ->
                val row = rows.optJSONObject(index) ?: throw IllegalArgumentException("invalid machine row")
                fun field(name: String): String? = row.opt(name)?.takeIf { it is String } as String?
                val id = runCatching { UUID.fromString(field("id") ?: throw IllegalArgumentException("invalid machine id")) }
                    .getOrElse { throw IllegalArgumentException("invalid machine id", it) }
                require(id.toString().equals(field("id"), ignoreCase = true)) { "invalid machine id" }
                val name = boundedDisplay(field("name") ?: id.toString(), id.toString())
                val status = boundedDisplay(field("observed_state") ?: field("desired_state") ?: field("status") ?: "unknown", "unknown")
                MilaMachineRow(id, name, status)
            }
            val truncated = rows.length() > 256
            return MilaSessionListing(machines.take(256), root.optBoolean("has_more", false) || truncated)
        }
    }
}

/** Typed projection of a Rust listing; malformed or oversized native data is refused. */
fun MilaSessionHandle.decodeListing(): MilaSessionListing = MilaSessionListing.decode(listing())
