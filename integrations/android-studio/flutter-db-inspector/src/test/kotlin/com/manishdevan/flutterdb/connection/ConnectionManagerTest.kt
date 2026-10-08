package com.manishdevan.flutterdb.connection

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.manishdevan.flutterdb.protocol.ErrorCodes
import com.manishdevan.flutterdb.protocol.InspectorException
import com.manishdevan.flutterdb.protocol.Json
import com.manishdevan.flutterdb.protocol.Protocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/** Scripted VM: isolates, extension registration and protocol answers. */
private class ScriptedVm : VmTransport {
    override val description = "scripted"
    override val supportsStreams = true

    @Volatile
    private var current: VmTransportListener? = null
    val isolates = CopyOnWriteArrayList<Pair<String, MutableList<String>>>()
    var protocolVersions = listOf(1)
    var disabled = false
    val calls = CopyOnWriteArrayList<String>()

    override suspend fun call(method: String, params: JsonObject, timeoutMs: Long?): JsonElement {
        calls += method
        return when (method) {
            "streamListen" -> JsonObject()
            "getVM" -> Json.obj("isolates" to JsonArray().apply { isolates.forEach { add(Json.obj("id" to it.first)) } })
            "getIsolate" -> Json.obj(
                "extensionRPCs" to (isolates.firstOrNull { it.first == params.get("isolateId").asString }?.second ?: emptyList<String>()),
            )
            Protocol.SERVICE_EXTENSION -> {
                val isolate = isolates.firstOrNull { it.first == params.get("isolateId").asString }
                if (isolate == null || Protocol.SERVICE_EXTENSION !in isolate.second) throw RpcError(-32601, "Method not found")
                val request = Json.parseStrict(params.get(Protocol.SERVICE_EXTENSION_PARAM).asString).asJsonObject
                val requestId = request.get("requestId").asString
                when (val m = request.get("method").asString) {
                    "inspector.status" ->
                        if (disabled) {
                            error(requestId, "INSPECTOR_DISABLED", "disabled")
                        } else {
                            Json.obj(
                                "version" to 1, "requestId" to requestId, "success" to true,
                                "result" to Json.obj(
                                    "protocolVersion" to protocolVersions.first(), "supportedVersions" to protocolVersions,
                                    "packageVersion" to "t", "mode" to "fullAccess", "methods" to emptyList<String>(), "limits" to JsonObject(),
                                ),
                            )
                        }
                    "boom" -> error(requestId, "TABLE_NOT_FOUND", "gone")
                    "slow" -> {
                        delay(10_000)
                        JsonObject()
                    }
                    else -> Json.obj("version" to 1, "requestId" to requestId, "success" to true, "result" to Json.obj("echo" to m))
                }
            }
            else -> throw RpcError(-32601, "unknown $method")
        }
    }

    private fun error(requestId: String, code: String, message: String) = Json.obj(
        "version" to 1, "requestId" to requestId, "success" to false,
        "error" to Json.obj("code" to code, "message" to message, "details" to JsonObject()),
    )

    override fun setListener(listener: VmTransportListener?) {
        current = listener
    }

    fun fire(streamId: String, event: JsonObject) = current?.onEvent(VmStreamEvent(streamId, event))

    fun register(id: String) {
        isolates += id to mutableListOf(Protocol.SERVICE_EXTENSION)
        fire("Isolate", Json.obj("kind" to "ServiceExtensionAdded", "extensionRPC" to Protocol.SERVICE_EXTENSION, "isolate" to Json.obj("id" to id)))
    }

    fun exit(id: String) {
        isolates.removeIf { it.first == id }
        fire("Isolate", Json.obj("kind" to "IsolateExit", "isolate" to Json.obj("id" to id)))
    }

    fun close() = current?.onClose("closed by test")

    override fun dispose() = Unit
}

class ConnectionManagerTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val fast = ConnectionOptions(requestTimeoutMs = 2_000, reconnectWaitMs = 5_000, rescanIntervalMs = 20)

    @After
    fun tearDown() = scope.cancel()

    private fun target(vm: VmTransport) = object : ConnectionTarget {
        override val id = "vm"
        override val label = "test"
        override suspend fun createTransport() = vm
    }

    private suspend fun ConnectionManager.await(state: ConnectionState, timeoutMs: Long = 5_000): ConnectionSnapshot =
        withTimeout(timeoutMs) {
            while (snapshot.state != state) delay(5)
            snapshot
        }

    @Test
    fun `waits for the extension, then connects`() = runBlocking {
        val vm = ScriptedVm()
        vm.isolates += "isolates/1" to mutableListOf()
        val manager = ConnectionManager(scope, fast)
        val databasesChanged = AtomicInteger()
        manager.addDatabasesListener { databasesChanged.incrementAndGet() }
        manager.connect(target(vm))
        assertEquals(ConnectionState.CONNECTING, manager.snapshot.state)
        assertEquals("Waiting for the app to call DbInspector.initialize()…", manager.snapshot.message)
        vm.register("isolates/2")
        val s = manager.await(ConnectionState.CONNECTED)
        assertEquals("isolates/2", s.isolateId)
        assertEquals("fullAccess", s.status?.mode)
        assertEquals(1, databasesChanged.get())
        assertEquals("database.list", manager.request("database.list").get("echo").asString)
        manager.dispose()
    }

    @Test
    fun `finds an isolate that already has the extension`() = runBlocking {
        val vm = ScriptedVm()
        vm.isolates += "isolates/main" to mutableListOf()
        vm.isolates += "isolates/app" to mutableListOf(Protocol.SERVICE_EXTENSION)
        val manager = ConnectionManager(scope, fast)
        manager.connect(target(vm))
        assertEquals(ConnectionState.CONNECTED, manager.snapshot.state)
        assertEquals("isolates/app", manager.snapshot.isolateId)
        assertTrue(vm.calls.count { it == "streamListen" } == 2)
        manager.dispose()
    }

    @Test
    fun `hot restart - reconnecting then connected on the new isolate, waiting requests succeed`() = runBlocking {
        val vm = ScriptedVm()
        vm.register("isolates/1")
        val manager = ConnectionManager(scope, fast)
        val states = CopyOnWriteArrayList<ConnectionState>()
        manager.addStateListener { states += it.state }
        manager.connect(target(vm))
        manager.await(ConnectionState.CONNECTED)
        vm.exit("isolates/1")
        manager.await(ConnectionState.RECONNECTING)
        val pending = async { manager.request("schema.list") }
        delay(50)
        vm.register("isolates/2")
        assertEquals("schema.list", pending.await().get("echo").asString)
        assertEquals("isolates/2", manager.snapshot.isolateId)
        assertTrue(states.containsAll(listOf(ConnectionState.CONNECTING, ConnectionState.CONNECTED, ConnectionState.RECONNECTING)))
        manager.dispose()
    }

    @Test
    fun `databasesChanged events from the active isolate only are forwarded`() = runBlocking {
        val vm = ScriptedVm()
        vm.register("isolates/1")
        val manager = ConnectionManager(scope, fast)
        manager.connect(target(vm))
        manager.await(ConnectionState.CONNECTED)
        val fired = AtomicInteger()
        manager.addDatabasesListener { fired.incrementAndGet() }
        vm.fire("Extension", Json.obj("kind" to "Extension", "extensionKind" to Protocol.EVENT_DATABASES_CHANGED, "isolate" to Json.obj("id" to "isolates/1")))
        vm.fire("Extension", Json.obj("kind" to "Extension", "extensionKind" to Protocol.EVENT_DATABASES_CHANGED, "isolate" to Json.obj("id" to "other")))
        withTimeout(2_000) { while (fired.get() < 1) delay(5) }
        delay(100)
        assertEquals(1, fired.get())
        manager.dispose()
    }

    @Test
    fun `protocol errors keep their code`() = runBlocking {
        val vm = ScriptedVm()
        vm.register("isolates/1")
        val manager = ConnectionManager(scope, fast)
        manager.connect(target(vm))
        manager.await(ConnectionState.CONNECTED)
        try {
            manager.request("boom")
            fail("expected an error")
        } catch (e: InspectorException) {
            assertEquals("TABLE_NOT_FOUND", e.code)
        }
        manager.dispose()
    }

    @Test
    fun `unsupported protocol version is an error`() = runBlocking {
        val vm = ScriptedVm()
        vm.protocolVersions = listOf(2)
        vm.register("isolates/1")
        val manager = ConnectionManager(scope, fast)
        manager.connect(target(vm))
        val s = manager.await(ConnectionState.ERROR)
        assertTrue(s.message!!.contains("protocol v2"))
        manager.dispose()
    }

    @Test
    fun `disabled inspector is an error`() = runBlocking {
        val vm = ScriptedVm()
        vm.disabled = true
        vm.register("isolates/1")
        val manager = ConnectionManager(scope, fast)
        manager.connect(target(vm))
        val s = manager.await(ConnectionState.ERROR)
        assertTrue(s.message!!.contains("disabled"))
        manager.dispose()
    }

    @Test
    fun `transport close disconnects and requests fail with NOT_CONNECTED`() = runBlocking {
        val vm = ScriptedVm()
        vm.register("isolates/1")
        val manager = ConnectionManager(scope, fast)
        manager.connect(target(vm))
        manager.await(ConnectionState.CONNECTED)
        vm.close()
        val s = manager.await(ConnectionState.DISCONNECTED)
        assertNotNull(s.message)
        try {
            manager.request("database.list")
            fail("expected an error")
        } catch (e: InspectorException) {
            assertEquals(ErrorCodes.NOT_CONNECTED, e.code)
        }
        manager.dispose()
    }

    @Test
    fun `isolate gone during a request switches to reconnecting`() = runBlocking {
        val vm = ScriptedVm()
        vm.register("isolates/1")
        val manager = ConnectionManager(scope, fast)
        manager.connect(target(vm))
        manager.await(ConnectionState.CONNECTED)
        vm.isolates.clear() // extension disappears without an IsolateExit event
        try {
            manager.request("database.list")
            fail("expected an error")
        } catch (e: InspectorException) {
            assertEquals(ErrorCodes.CONNECTION_LOST, e.code)
        }
        assertEquals(ConnectionState.RECONNECTING, manager.snapshot.state)
        vm.register("isolates/2")
        manager.await(ConnectionState.CONNECTED)
        manager.dispose()
    }

    @Test
    fun `slow requests time out with CLIENT_TIMEOUT`() = runBlocking {
        val scripted = ScriptedVm().apply { register("isolates/1") }
        val timing = object : VmTransport by scripted {
            override suspend fun call(method: String, params: JsonObject, timeoutMs: Long?): JsonElement {
                if (method != Protocol.SERVICE_EXTENSION || params.get(Protocol.SERVICE_EXTENSION_PARAM).asString.contains("inspector.status")) {
                    return scripted.call(method, params, timeoutMs)
                }
                // Behave like VmServiceClient: enforce the timeout.
                return kotlinx.coroutines.withTimeoutOrNull(timeoutMs ?: Long.MAX_VALUE) { scripted.call(method, params, null) }
                    ?: throw RpcError(RpcError.CLIENT_TIMEOUT, "No response")
            }
        }
        val manager = ConnectionManager(scope, fast.copy(requestTimeoutMs = 100))
        manager.connect(target(timing))
        manager.await(ConnectionState.CONNECTED)
        try {
            manager.request("slow")
            fail("expected an error")
        } catch (e: InspectorException) {
            assertEquals(ErrorCodes.CLIENT_TIMEOUT, e.code)
        }
        assertEquals(ConnectionState.CONNECTED, manager.snapshot.state)
        manager.dispose()
    }

    @Test
    fun `failing transport creation is an error and disconnect resets`() = runBlocking {
        val manager = ConnectionManager(scope, fast)
        manager.connect(object : ConnectionTarget {
            override val id = "bad"
            override val label = "bad"
            override suspend fun createTransport(): VmTransport = throw java.io.IOException("Could not connect to ws://x")
        })
        assertEquals(ConnectionState.ERROR, manager.snapshot.state)
        assertEquals("Could not connect to ws://x", manager.snapshot.message)
        manager.disconnect()
        assertEquals(ConnectionState.DISCONNECTED, manager.snapshot.state)
        manager.dispose()
    }

    @Test
    fun `a Sentinel answer during a restart retries reads on the new isolate but not writes`() = runBlocking {
        val scripted = ScriptedVm().apply { register("isolates/1") }
        val sentinels = AtomicInteger(0)
        val dying = object : VmTransport by scripted {
            override suspend fun call(method: String, params: JsonObject, timeoutMs: Long?): JsonElement {
                if (method == Protocol.SERVICE_EXTENSION && params.get("isolateId").asString == "isolates/1" && sentinels.get() > 0) {
                    sentinels.decrementAndGet()
                    scripted.isolates.removeIf { it.first == "isolates/1" }
                    scripted.register("isolates/2")
                    return Json.obj("type" to "Sentinel", "kind" to "Collected", "valueAsString" to "<collected>")
                }
                return scripted.call(method, params, timeoutMs)
            }
        }
        val manager = ConnectionManager(scope, fast)
        manager.connect(target(dying))
        manager.await(ConnectionState.CONNECTED)
        sentinels.set(1)
        assertEquals("database.list", manager.request("database.list").get("echo").asString)
        assertEquals("isolates/2", manager.snapshot.isolateId)

        scripted.isolates.clear()
        scripted.register("isolates/1")
        manager.await(ConnectionState.CONNECTED)
        withTimeout(2_000) { while (manager.snapshot.isolateId != "isolates/1") delay(5) }
        sentinels.set(1)
        try {
            manager.request("row.update")
            fail("expected an error")
        } catch (e: InspectorException) {
            assertEquals(ErrorCodes.CONNECTION_LOST, e.code)
        }
        manager.dispose()
    }
}
