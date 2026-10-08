package com.manishdevan.flutterdb.connection

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.manishdevan.flutterdb.protocol.ErrorCodes
import com.manishdevan.flutterdb.protocol.InspectorException
import com.manishdevan.flutterdb.protocol.InspectorStatus
import com.manishdevan.flutterdb.protocol.Json
import com.manishdevan.flutterdb.protocol.Methods
import com.manishdevan.flutterdb.protocol.Protocol
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withTimeout
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING, ERROR }

/** Something the manager can connect to (a run session, a pasted URI, ...). */
interface ConnectionTarget {
    /** Stable identity, e.g. the WebSocket URI. */
    val id: String
    val label: String

    suspend fun createTransport(): VmTransport
}

/** A target reached through a VM service URI and the real [VmServiceClient]. */
class UriConnectionTarget(uri: String, label: String? = null) : ConnectionTarget {
    override val id: String = VmServiceUri.toWebSocketUri(uri)
    override val label: String = label ?: VmServiceUri.label(id)

    override suspend fun createTransport(): VmTransport = VmServiceClient.connect(id)
}

data class ConnectionSnapshot(
    val state: ConnectionState,
    val targetId: String? = null,
    val targetLabel: String? = null,
    val isolateId: String? = null,
    val status: InspectorStatus? = null,
    /** Human readable explanation for `connecting`, `reconnecting` and `error`. */
    val message: String? = null,
)

data class ConnectionOptions(
    val requestTimeoutMs: Long = 30_000,
    /** How long a request waits for a hot restart to finish before failing. */
    val reconnectWaitMs: Long = 20_000,
    /** Isolate rescan interval while waiting for the extension. */
    val rescanIntervalMs: Long = 2_000,
)

/**
 * Owns the connection to one running app and keeps it alive across hot
 * restarts. A port of the VS Code extension's `ConnectionManager`:
 *
 * ```
 * connect → find isolate exposing ext.flutter_db_inspector.request → CONNECTED
 * IsolateExit (hot restart) → RECONNECTING → ServiceExtensionAdded → CONNECTED
 * transport closed (app stopped) → DISCONNECTED
 * ```
 *
 * All state lives on one serial coroutine dispatcher (the equivalent of the
 * JavaScript event loop), so interleaving happens only at suspension points
 * and is guarded by the connection `generation`. Independent of IntelliJ
 * APIs so it can be tested against a scripted VM and a real Dart VM.
 */
class ConnectionManager(
    parentScope: CoroutineScope,
    options: ConnectionOptions = ConnectionOptions(),
    private val log: (String) -> Unit = {},
) {
    // A dedicated thread instead of `limitedParallelism`, whose overloads differ across platform versions.
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "Flutter DB Inspector connection").apply { isDaemon = true }
    }
    private val serial = executor.asCoroutineDispatcher()
    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext.job) + serial)

    @Volatile
    var options: ConnectionOptions = options

    @Volatile
    private var transport: VmTransport? = null
    private var target: ConnectionTarget? = null
    private var isolateId: String? = null
    private var status: InspectorStatus? = null
    private var state = ConnectionState.DISCONNECTED
    private var message: String? = null
    private var generation = 0
    private var rescanJob: Job? = null
    private val requestCounter = AtomicLong()
    private val connectedWaiters = mutableListOf<CompletableDeferred<Unit>>()

    private val stateListeners = CopyOnWriteArrayList<(ConnectionSnapshot) -> Unit>()
    private val databasesListeners = CopyOnWriteArrayList<() -> Unit>()

    /** The latest state; safe to read from any thread. */
    @Volatile
    var snapshot: ConnectionSnapshot = ConnectionSnapshot(ConnectionState.DISCONNECTED)
        private set

    val isConnected: Boolean get() = snapshot.state == ConnectionState.CONNECTED

    val currentTargetId: String? get() = snapshot.targetId

    /** Called on every state change (on the manager's thread). Returns a remover. */
    fun addStateListener(listener: (ConnectionSnapshot) -> Unit): () -> Unit {
        stateListeners += listener
        return { stateListeners -= listener }
    }

    /**
     * Called when the set of databases may have changed: after (re)connecting
     * and when the app registers or unregisters a database. Returns a remover.
     */
    fun addDatabasesListener(listener: () -> Unit): () -> Unit {
        databasesListeners += listener
        return { databasesListeners -= listener }
    }

    private fun updateSnapshot() {
        snapshot = ConnectionSnapshot(state, target?.id, target?.label, isolateId, status, message)
    }

    private fun setState(newState: ConnectionState, newMessage: String? = null) {
        val changed = state != newState || message != newMessage
        state = newState
        message = newMessage
        updateSnapshot()
        if (newState == ConnectionState.CONNECTED) {
            connectedWaiters.forEach { it.complete(Unit) }
            connectedWaiters.clear()
        }
        if (changed) {
            log("state → $newState${newMessage?.let { " ($it)" } ?: ""}")
            val s = snapshot
            stateListeners.forEach { runCatching { it(s) }.onFailure { e -> log("state listener failed: $e") } }
        }
    }

    private fun fireDatabasesChanged() {
        databasesListeners.forEach { runCatching { it() }.onFailure { e -> log("databases listener failed: $e") } }
    }

    /** Connects to [target], replacing any current connection. */
    suspend fun connect(target: ConnectionTarget): Unit = withContext(serial) {
        teardown()
        val gen = ++generation
        this@ConnectionManager.target = target
        setState(ConnectionState.CONNECTING, "Connecting to ${target.label}…")

        val created = try {
            target.createTransport()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (gen == generation) setState(ConnectionState.ERROR, errorMessage(e))
            return@withContext
        }
        if (gen != generation) {
            created.dispose()
            return@withContext
        }
        transport = created
        log("connected to ${created.description}")
        created.setListener(object : VmTransportListener {
            override fun onEvent(event: VmStreamEvent) {
                scope.launch { onVmEvent(event, gen) }
            }

            override fun onClose(reason: String) {
                scope.launch {
                    if (gen != generation) return@launch
                    log("transport closed: $reason")
                    teardown()
                    setState(ConnectionState.DISCONNECTED, "The app stopped or the VM service closed the connection.")
                }
            }
        })

        if (created.supportsStreams) {
            listOf("Isolate", "Extension").map { stream -> scope.async { listen(created, stream) } }.awaitAll()
        }
        if (gen != generation) return@withContext
        scanIsolates(gen)
        // Still searching (not connected, and no terminal error from the handshake).
        if (gen == generation && isolateId == null && state == ConnectionState.CONNECTING) {
            setState(ConnectionState.CONNECTING, "Waiting for the app to call DbInspector.initialize()…")
            startRescan(gen)
        }
    }

    /** Closes the connection. */
    suspend fun disconnect(): Unit = withContext(serial) {
        generation++
        teardown()
        target = null
        setState(ConnectionState.DISCONNECTED)
    }

    /** [disconnect] without waiting. */
    fun disconnectAsync() {
        scope.launch { disconnect() }
    }

    /** Disconnects and stops all background work; the manager can't be reused. */
    fun dispose() {
        transport?.dispose()
        transport = null
        scope.cancel()
        executor.shutdown()
        stateListeners.clear()
        databasesListeners.clear()
    }

    private fun teardown() {
        stopRescan()
        transport?.let {
            it.setListener(null)
            it.dispose()
        }
        transport = null
        isolateId = null
        status = null
        updateSnapshot()
    }

    private suspend fun listen(transport: VmTransport, streamId: String) {
        try {
            transport.call("streamListen", Json.obj("streamId" to streamId), options.requestTimeoutMs)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 103: already subscribed (e.g. a shared DDS connection) — fine.
            if (!(e is RpcError && e.code == RpcError.STREAM_ALREADY_SUBSCRIBED)) {
                log("streamListen($streamId) failed: ${errorMessage(e)}")
            }
        }
    }

    private fun startRescan(gen: Int) {
        stopRescan()
        rescanJob = scope.launch {
            while (isActive) {
                delay(options.rescanIntervalMs)
                if (gen != generation || isolateId != null) break
                scanIsolates(gen)
            }
        }
    }

    private fun stopRescan() {
        rescanJob?.cancel()
        rescanJob = null
    }

    /** Looks for the isolate exposing the inspector extension. */
    private suspend fun scanIsolates(gen: Int) {
        val transport = transport ?: return
        try {
            val vm = transport.call("getVM", JsonObject(), options.requestTimeoutMs).asObjectOrEmpty()
            val isolates = vm.get("isolates")?.takeIf { it.isJsonArray }?.asJsonArray ?: return
            for (ref in isolates) {
                val id = ref.asObjectOrEmpty().get("id")?.takeIf { it.isJsonPrimitive }?.asString ?: continue
                val isolate = transport.call("getIsolate", Json.obj("isolateId" to id), options.requestTimeoutMs).asObjectOrEmpty()
                val rpcs = isolate.get("extensionRPCs")?.takeIf { it.isJsonArray }?.asJsonArray
                    ?.mapNotNull { it.takeIf { e -> e.isJsonPrimitive }?.asString }.orEmpty()
                if (Protocol.SERVICE_EXTENSION in rpcs) {
                    if (gen == generation) adopt(id, gen)
                    return
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log("isolate scan failed: ${errorMessage(e)}")
        }
    }

    /** Makes [id] the active isolate after a protocol handshake. */
    private suspend fun adopt(id: String, gen: Int) {
        if (isolateId == id && state == ConnectionState.CONNECTED) return
        isolateId = id
        updateSnapshot()
        stopRescan()
        try {
            val status = InspectorStatus.parse(rawRequest(Methods.INSPECTOR_STATUS, JsonObject()))
            if (gen != generation || isolateId != id) return
            if (status.supportedVersions.none { it in Protocol.SUPPORTED_VERSIONS }) {
                isolateId = null
                setState(
                    ConnectionState.ERROR,
                    "The app speaks protocol v${status.protocolVersion}; this plugin supports " +
                        "v${Protocol.SUPPORTED_VERSIONS.joinToString(", v")}. Update the plugin or the package.",
                )
                return
            }
            this.status = status
            setState(ConnectionState.CONNECTED, "${target?.label ?: "App"} · ${status.mode}")
            fireDatabasesChanged()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (gen != generation) return
            isolateId = null
            if (e is InspectorException && e.code == ErrorCodes.INSPECTOR_DISABLED) {
                setState(ConnectionState.ERROR, "The inspector is disabled in this build (release mode or enabled: false).")
                return
            }
            log("handshake failed: ${errorMessage(e)}")
            setState(ConnectionState.RECONNECTING, "Waiting for the app…")
            startRescan(gen)
        }
    }

    private suspend fun onVmEvent(event: VmStreamEvent, gen: Int) {
        if (gen != generation) return
        when (event.streamId) {
            "Isolate" -> {
                val eventIsolate = event.isolateId
                if (event.kind == "ServiceExtensionAdded" && event.extensionRpc == Protocol.SERVICE_EXTENSION && eventIsolate != null) {
                    log("extension registered on $eventIsolate")
                    adopt(eventIsolate, gen)
                } else if (event.kind == "IsolateExit" && eventIsolate != null && eventIsolate == isolateId) {
                    // Hot restart (or the isolate died): wait for the extension to return.
                    isolateId = null
                    status = null
                    setState(ConnectionState.RECONNECTING, "App restarted — reconnecting…")
                    startRescan(gen)
                }
            }
            "Extension" ->
                if (event.extensionKind == Protocol.EVENT_DATABASES_CHANGED && event.isolateId == isolateId) {
                    fireDatabasesChanged()
                }
        }
    }

    /** Returns once connected, or throws after [timeoutMs]. */
    private suspend fun waitUntilConnected(timeoutMs: Long) {
        if (state == ConnectionState.CONNECTED) return
        val waiter = CompletableDeferred<Unit>()
        connectedWaiters += waiter
        try {
            withTimeout(timeoutMs) { waiter.await() }
        } catch (e: TimeoutCancellationException) {
            connectedWaiters -= waiter
            throw InspectorException(ErrorCodes.CONNECTION_LOST, "The app did not come back after restarting.", cause = e)
        }
    }

    /**
     * Sends a protocol request and returns its `result`. Throws
     * [InspectorException] for protocol errors and connection problems.
     * Requests made during a hot restart wait for the app to come back.
     */
    suspend fun request(method: String, params: JsonObject = JsonObject()): JsonObject = withContext(serial) {
        if (state == ConnectionState.RECONNECTING || (state == ConnectionState.CONNECTING && transport != null)) {
            waitUntilConnected(options.reconnectWaitMs)
        }
        if (state != ConnectionState.CONNECTED) {
            throw InspectorException(ErrorCodes.NOT_CONNECTED, "No Flutter app is connected.")
        }
        try {
            rawRequest(method, params)
        } catch (e: IsolateGoneException) {
            // Reads are safe to repeat once the app is back; writes may have run, so report them.
            if (method !in IDEMPOTENT_METHODS) throw e.error
            waitUntilConnected(options.reconnectWaitMs)
            try {
                rawRequest(method, params)
            } catch (again: IsolateGoneException) {
                throw again.error
            }
        }
    }

    /** The isolate went away while a request was running (hot restart, stop). */
    private class IsolateGoneException(val error: InspectorException) : Exception(error.message, error)

    private fun isolateGone(isolate: String, cause: Throwable?): IsolateGoneException {
        if (isolateId == isolate && state == ConnectionState.CONNECTED) {
            isolateId = null
            status = null
            setState(ConnectionState.RECONNECTING, "App restarted — reconnecting…")
            startRescan(generation)
        }
        return IsolateGoneException(
            InspectorException(ErrorCodes.CONNECTION_LOST, "The app restarted while the request was running. Try again.", cause = cause),
        )
    }

    private suspend fun rawRequest(method: String, params: JsonObject): JsonObject {
        val transport = transport
        val isolate = isolateId
        if (transport == null || isolate == null) {
            throw InspectorException(ErrorCodes.NOT_CONNECTED, "No Flutter app is connected.")
        }
        val envelope = Json.obj(
            "version" to Protocol.VERSION,
            "requestId" to "intellij-${requestCounter.incrementAndGet()}",
            "method" to method,
            "params" to params,
        )
        val timeout = options.requestTimeoutMs
        val raw = try {
            transport.call(
                Protocol.SERVICE_EXTENSION,
                Json.obj("isolateId" to isolate, Protocol.SERVICE_EXTENSION_PARAM to Json.stringify(envelope)),
                timeout,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: RpcError) {
            if (e.code == RpcError.CLIENT_TIMEOUT) {
                throw InspectorException(ErrorCodes.CLIENT_TIMEOUT, "The app did not answer $method within $timeout ms.", cause = e)
            }
            log("$method failed: ${e.code} ${e.message} ${e.data ?: ""}")
            if (e.code in ISOLATE_GONE_CODES) throw isolateGone(isolate, e)
            throw InspectorException(ErrorCodes.CONNECTION_LOST, e.message ?: "VM service error", cause = e)
        } catch (e: Exception) {
            log("$method failed: ${errorMessage(e)}")
            throw InspectorException(ErrorCodes.CONNECTION_LOST, errorMessage(e), cause = e)
        }
        // A Sentinel (e.g. `Collected`) instead of a response: the isolate died mid-request.
        if (raw.isJsonObject && raw.asJsonObject.get("type")?.takeIf { it.isJsonPrimitive }?.asString == "Sentinel") {
            log("$method answered with a Sentinel: $raw")
            throw isolateGone(isolate, null)
        }
        return parseResponse(raw)
    }

    companion object {
        /** Methods that never change app data and may be repeated after a restart. */
        private val IDEMPOTENT_METHODS = setOf(
            Methods.INSPECTOR_STATUS, Methods.DATABASE_LIST, Methods.DATABASE_INFO, Methods.DATABASE_STATS,
            Methods.SCHEMA_LIST, Methods.SCHEMA_TABLE, Methods.ROWS_QUERY, Methods.ROWS_COUNT, Methods.VALUE_READ,
        )

        /** VM service errors meaning "the isolate went away" (hot restart, stop). */
        private val ISOLATE_GONE_CODES = setOf(
            -32000, // service connection disposed
            -32601, // method not found: extension not (yet) registered
            105, // isolate must be runnable
            106, // isolate is reloading
            113, // extension not registered / isolate exited
        )

        /** Unwraps a protocol response; throws [InspectorException] for errors. */
        fun parseResponse(raw: JsonElement): JsonObject {
            val value = if (raw.isJsonPrimitive && raw.asJsonPrimitive.isString) {
                Json.parseOrNull(raw.asString)
            } else {
                raw
            }
            if (value == null || !value.isJsonObject || !value.asJsonObject.has("success")) {
                throw InspectorException(ErrorCodes.INTERNAL_ERROR, "The app returned a malformed response.")
            }
            val response = value.asJsonObject
            val success = response.get("success").let { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean && it.asBoolean }
            if (!success) {
                val error = response.get("error")?.takeIf { it.isJsonObject }?.asJsonObject ?: JsonObject()
                throw InspectorException(
                    error.get("code")?.takeIf { it.isJsonPrimitive }?.asString ?: ErrorCodes.INTERNAL_ERROR,
                    error.get("message")?.takeIf { it.isJsonPrimitive }?.asString ?: "Request failed",
                    error.get("details")?.takeIf { it.isJsonObject }?.asJsonObject ?: JsonObject(),
                )
            }
            return response.get("result")?.takeIf { it.isJsonObject }?.asJsonObject ?: JsonObject()
        }

        fun errorMessage(error: Throwable): String = error.message ?: error.javaClass.simpleName
    }
}

private fun JsonElement.asObjectOrEmpty(): JsonObject = if (isJsonObject) asJsonObject else JsonObject()
