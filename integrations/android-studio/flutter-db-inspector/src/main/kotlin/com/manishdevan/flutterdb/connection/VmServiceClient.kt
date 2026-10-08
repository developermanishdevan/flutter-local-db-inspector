package com.manishdevan.flutterdb.connection

import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.manishdevan.flutterdb.protocol.Json
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.time.Duration
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Dart VM service JSON-RPC 2.0 over a `java.net.http` WebSocket: request ids,
 * per-call timeouts and `streamNotify` events.
 */
class VmServiceClient private constructor(
    override val description: String,
    private val http: HttpClient,
) : VmTransport {
    override val supportsStreams: Boolean = true

    private lateinit var socket: WebSocket
    private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonElement>>()
    private val nextId = AtomicLong(1)
    private val closed = AtomicBoolean(false)

    @Volatile
    private var closeReason: String? = null

    @Volatile
    private var listener: VmTransportListener? = null

    // java.net.http allows one outstanding send at a time: sends are chained.
    private val sendLock = Any()
    private var sendChain: CompletableFuture<*> = CompletableFuture.completedFuture(null)

    override suspend fun call(method: String, params: JsonObject, timeoutMs: Long?): JsonElement {
        if (closed.get()) throw RpcError(RpcError.CONNECTION_CLOSED, "Service connection closed")
        val id = nextId.getAndIncrement().toString()
        val deferred = CompletableDeferred<JsonElement>()
        pending[id] = deferred
        val message = Json.obj("jsonrpc" to "2.0", "id" to id, "method" to method, "params" to params)
        send(Json.stringify(message), id)
        try {
            if (timeoutMs == null) return deferred.await()
            return withTimeoutOrNull(timeoutMs) { deferred.await() }
                ?: throw RpcError(RpcError.CLIENT_TIMEOUT, "No response to $method within $timeoutMs ms")
        } finally {
            pending.remove(id)
        }
    }

    private fun send(text: String, id: String) {
        synchronized(sendLock) {
            val next = sendChain.handle { _, _ -> null }.thenCompose { socket.sendText(text, true) }
            next.whenComplete { _, error ->
                if (error != null) {
                    pending.remove(id)?.completeExceptionally(RpcError(RpcError.CONNECTION_CLOSED, error.message ?: "send failed"))
                }
            }
            sendChain = next
        }
    }

    override fun setListener(listener: VmTransportListener?) {
        this.listener = listener
        val reason = closeReason
        if (listener != null && reason != null) listener.onClose(reason)
    }

    private fun onMessage(text: String) {
        val message = try {
            Json.parseStrict(text).takeIf { it.isJsonObject }?.asJsonObject
        } catch (_: Exception) {
            null
        } ?: return
        val method = message.get("method")?.takeIf { it.isJsonPrimitive }?.asString
        if (method == "streamNotify") {
            val params = message.get("params")?.takeIf { it.isJsonObject }?.asJsonObject ?: return
            val streamId = params.get("streamId")?.takeIf { it.isJsonPrimitive }?.asString ?: return
            val event = params.get("event")?.takeIf { it.isJsonObject }?.asJsonObject ?: return
            listener?.onEvent(VmStreamEvent(streamId, event))
            return
        }
        val id = message.get("id")?.takeIf { it.isJsonPrimitive }?.asString ?: return
        val deferred = pending.remove(id) ?: return
        val error = message.get("error")?.takeIf { it.isJsonObject }?.asJsonObject
        if (error != null) {
            val code = error.get("code")?.takeIf { it.isJsonPrimitive }?.asInt ?: 0
            val text2 = error.get("message")?.takeIf { it.isJsonPrimitive }?.asString ?: "VM service error"
            deferred.completeExceptionally(RpcError(code, text2, error.get("data")))
        } else {
            deferred.complete(message.get("result") ?: JsonNull.INSTANCE)
        }
    }

    private fun handleClose(reason: String) {
        if (!closed.compareAndSet(false, true)) return
        closeReason = reason
        for (id in pending.keys.toList()) {
            pending.remove(id)?.completeExceptionally(RpcError(RpcError.CONNECTION_CLOSED, "Service connection closed ($reason)"))
        }
        listener?.onClose(reason)
    }

    override fun dispose() {
        if (closed.get()) return
        handleClose("disposed")
        val ws = if (this::socket.isInitialized) socket else null
        if (ws == null) {
            http.shutdownNow()
            return
        }
        ws.sendClose(WebSocket.NORMAL_CLOSURE, "")
            .orTimeout(1, TimeUnit.SECONDS)
            .whenComplete { _, _ ->
                ws.abort()
                http.shutdownNow()
            }
    }

    private inner class Listener : WebSocket.Listener {
        private val buffer = StringBuilder()

        override fun onOpen(webSocket: WebSocket) {
            webSocket.request(1)
        }

        override fun onText(webSocket: WebSocket, data: CharSequence, last: Boolean): CompletionStage<*>? {
            buffer.append(data)
            if (last) {
                val text = buffer.toString()
                buffer.setLength(0)
                onMessage(text)
            }
            webSocket.request(1)
            return null
        }

        override fun onClose(webSocket: WebSocket, statusCode: Int, reason: String): CompletionStage<*>? {
            handleClose(reason.ifEmpty { "connection closed ($statusCode)" })
            return null
        }

        override fun onError(webSocket: WebSocket, error: Throwable) {
            handleClose(error.message ?: error.javaClass.simpleName)
        }
    }

    companion object {
        /** Connects to a VM service; [uri] may be any form accepted by [VmServiceUri.toWebSocketUri]. */
        suspend fun connect(uri: String, timeoutMs: Long = 10_000): VmServiceClient {
            val wsUri = VmServiceUri.toWebSocketUri(uri)
            val http = HttpClient.newBuilder().connectTimeout(Duration.ofMillis(timeoutMs)).build()
            val client = VmServiceClient(wsUri, http)
            try {
                client.socket = withTimeout(timeoutMs) {
                    http.newWebSocketBuilder()
                        .connectTimeout(Duration.ofMillis(timeoutMs))
                        .buildAsync(URI(wsUri), client.Listener())
                        .await()
                }
            } catch (e: TimeoutCancellationException) {
                http.shutdownNow()
                throw IOException("Timed out connecting to $wsUri", e)
            } catch (e: CancellationException) {
                http.shutdownNow()
                throw e
            } catch (e: Exception) {
                http.shutdownNow()
                val cause = generateSequence<Throwable>(e) { it.cause }.last()
                throw IOException("Could not connect to $wsUri: ${cause.message ?: cause.javaClass.simpleName}", e)
            }
            return client
        }
    }
}
