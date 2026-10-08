package com.manishdevan.flutterdb.connection

import com.google.gson.JsonElement
import com.google.gson.JsonObject

/** A VM service event as delivered on `streamNotify`. */
data class VmStreamEvent(val streamId: String, val event: JsonObject) {
    val kind: String? get() = event.string("kind")
    val isolateId: String? get() = event.get("isolate")?.takeIf { it.isJsonObject }?.asJsonObject?.string("id")
    val extensionRpc: String? get() = event.string("extensionRPC")
    val extensionKind: String? get() = event.string("extensionKind")

    private fun JsonObject.string(name: String): String? =
        get(name)?.takeIf { it.isJsonPrimitive }?.asString
}

/** Error returned by a VM service JSON-RPC call. */
class RpcError(val code: Int, message: String, val data: JsonElement? = null) : Exception(message) {
    companion object {
        /** Service connection closed or disposed. */
        const val CONNECTION_CLOSED = -32000

        /** Client-side timeout (not a VM service code). */
        const val CLIENT_TIMEOUT = -32001

        /** `streamListen`: already subscribed. */
        const val STREAM_ALREADY_SUBSCRIBED = 103
    }
}

/** Receives transport events; called on the transport's I/O thread. */
interface VmTransportListener {
    fun onEvent(event: VmStreamEvent)

    /** Called once when the transport closes for any reason. */
    fun onClose(reason: String)
}

/** JSON-RPC access to a Dart VM service. */
interface VmTransport {
    /** Human readable description, e.g. the VM service URI. */
    val description: String

    /** Whether `streamListen` and stream events are available. */
    val supportsStreams: Boolean

    /**
     * Calls [method]. Throws [RpcError] for JSON-RPC errors, a closed
     * connection ([RpcError.CONNECTION_CLOSED]) or a timeout
     * ([RpcError.CLIENT_TIMEOUT]).
     */
    suspend fun call(method: String, params: JsonObject = JsonObject(), timeoutMs: Long? = null): JsonElement

    /** Sets the listener; if the transport is already closed, [VmTransportListener.onClose] is called at once. */
    fun setListener(listener: VmTransportListener?)

    fun dispose()
}
