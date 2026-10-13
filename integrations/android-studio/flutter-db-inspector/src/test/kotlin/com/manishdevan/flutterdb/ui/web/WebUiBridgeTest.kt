package com.manishdevan.flutterdb.ui.web

import com.google.gson.JsonObject
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.protocol.ErrorCodes
import com.manishdevan.flutterdb.protocol.InspectorException
import com.manishdevan.flutterdb.protocol.Json
import com.manishdevan.flutterdb.service.SavedQueryStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebUiBridgeTest {
    private class FakeHost : WebUiHost {
        val calls = mutableListOf<Pair<String, JsonObject>>()
        val copied = mutableListOf<Pair<String, String?>>()
        val saved = mutableListOf<Pair<String, ByteArray>>()
        val notified = mutableListOf<Pair<String, String?>>()
        val errors = mutableListOf<String>()
        var readyCount = 0
        var cancelSave = false
        var app: String? = null
        var store: SavedQueryStore? = SavedQueryStore()

        override suspend fun call(method: String, params: JsonObject): JsonObject {
            calls += method to params
            if (method == "row.update") {
                throw InspectorException(ErrorCodes.WRITE_NOT_ALLOWED, "confirm first", Json.obj("requiresConfirmation" to true))
            }
            if (method == "boom") error("kaput")
            return Json.obj("count" to Json.number("9007199254740993"))
        }

        override suspend fun copy(text: String, label: String?) {
            copied += text to label
        }

        override suspend fun saveFile(name: String, bytes: ByteArray): Boolean {
            if (cancelSave) return false
            saved += name to bytes
            return true
        }

        override fun notify(message: String, level: String?) {
            notified += message to level
        }

        override fun onReady() {
            readyCount++
        }

        override fun logError(message: String) {
            errors += message
        }

        override fun currentApp(): String? = app

        override val savedQueries: SavedQueryStore? get() = store
    }

    private val host = FakeHost()
    private val posted = mutableListOf<JsonObject>()

    // Unconfined: requests complete before onMessage returns.
    private val bridge = WebUiBridge(CoroutineScope(Dispatchers.Unconfined), host) { posted += Json.parseStrict(it).asJsonObject }

    private fun request(id: Int, vararg fields: Pair<String, Any?>): JsonObject {
        bridge.onMessage(Json.stringify(Json.obj("type" to "request", "id" to id, "request" to Json.obj(*fields))))
        val result = posted.last()
        assertEquals("result", result.get("type").asString)
        assertEquals(id, result.get("id").asInt)
        return result
    }

    @Test
    fun `call forwards method and params and returns the result verbatim`() {
        val result = request(1, "op" to "call", "method" to "rows.count", "params" to Json.obj("databaseId" to "db"))
        assertEquals(listOf("rows.count" to Json.obj("databaseId" to "db")), host.calls)
        assertTrue(result.get("ok").asBoolean)
        // Exact 64-bit integers survive the round trip.
        assertEquals("""{"count":9007199254740993}""", Json.stringify(result.get("result")))
    }

    @Test
    fun `protocol errors keep code, message and details`() {
        val result = request(2, "op" to "call", "method" to "row.update", "params" to JsonObject())
        assertFalse(result.get("ok").asBoolean)
        val error = result.getAsJsonObject("error")
        assertEquals(ErrorCodes.WRITE_NOT_ALLOWED, error.get("code").asString)
        assertEquals("confirm first", error.get("message").asString)
        assertTrue(error.getAsJsonObject("details").get("requiresConfirmation").asBoolean)
    }

    @Test
    fun `unexpected failures become INTERNAL_ERROR and calls without params get an empty object`() {
        val error = request(3, "op" to "call", "method" to "boom").getAsJsonObject("error")
        assertEquals(ErrorCodes.INTERNAL_ERROR, error.get("code").asString)
        assertEquals("kaput", error.get("message").asString)
        assertNull(error.get("details"))
        assertEquals(JsonObject(), host.calls.single().second)
    }

    @Test
    fun `unknown ops and malformed requests are answered with INVALID_REQUEST`() {
        for ((id, fields) in listOf(
            4 to arrayOf<Pair<String, Any?>>("op" to "export"),
            5 to arrayOf<Pair<String, Any?>>("op" to "call"),
            6 to arrayOf<Pair<String, Any?>>("op" to "saveFile", "name" to "a.bin", "base64" to "not base64!"),
            7 to arrayOf<Pair<String, Any?>>("op" to "copy"),
        )) {
            val result = request(id, *fields)
            assertFalse(result.get("ok").asBoolean)
            assertEquals(ErrorCodes.INVALID_REQUEST, result.getAsJsonObject("error").get("code").asString)
        }
        bridge.onMessage("""{"type":"request","id":8}""")
        assertEquals(ErrorCodes.INVALID_REQUEST, posted.last().getAsJsonObject("error").get("code").asString)
    }

    @Test
    fun `copy, notify and saveFile`() {
        assertEquals(JsonObject(), request(10, "op" to "copy", "text" to "hello", "label" to "cell").getAsJsonObject("result"))
        assertEquals(listOf("hello" to "cell"), host.copied)

        request(11, "op" to "notify", "message" to "Exported", "level" to "warning")
        assertEquals(listOf("Exported" to "warning"), host.notified)

        assertEquals(JsonObject(), request(12, "op" to "saveFile", "name" to "rows.csv", "text" to "a,é").getAsJsonObject("result"))
        assertArrayEquals("a,é".toByteArray(Charsets.UTF_8), host.saved.last().second)
        request(13, "op" to "saveFile", "name" to "blob.bin", "base64" to "AAEC/w==")
        assertEquals("blob.bin", host.saved.last().first)
        assertArrayEquals(byteArrayOf(0, 1, 2, -1), host.saved.last().second)

        host.cancelSave = true
        val cancelled = request(14, "op" to "saveFile", "name" to "x.txt", "text" to "")
        assertTrue(cancelled.get("ok").asBoolean)
        assertTrue(cancelled.getAsJsonObject("result").get("cancelled").asBoolean)
    }

    @Test
    fun `ready, error and junk messages`() {
        bridge.onMessage("""{"type":"ready"}""")
        bridge.onMessage("""{"type":"error","message":"TypeError: x"}""")
        bridge.onMessage("not json")
        bridge.onMessage("""{"type":"surprise"}""")
        assertEquals(1, host.readyCount)
        assertEquals("TypeError: x", host.errors.first())
        assertEquals(3, host.errors.size)
        assertTrue(posted.isEmpty())
    }

    @Test
    fun `host messages have the shapes of messages_ts`() {
        assertEquals(
            """{"type":"init","view":"app","host":"android-studio","pageSize":50,"theme":"dark","confirmCellEdits":true,"historyLimit":100}""",
            WebUiMessages.init("android-studio", 50, "dark", true, 100),
        )
        assertEquals(
            """{"type":"connection","state":"reconnecting","message":"App restarted"}""",
            WebUiMessages.connection(ConnectionSnapshot(ConnectionState.RECONNECTING, message = "App restarted")),
        )
        assertEquals("""{"type":"connection","state":"disconnected"}""", WebUiMessages.connection(ConnectionSnapshot(ConnectionState.DISCONNECTED)))
        assertEquals("""{"type":"event","name":"flutter_db_inspector.databasesChanged"}""", WebUiMessages.event("flutter_db_inspector.databasesChanged"))
        assertEquals("""{"type":"theme","theme":"light"}""", WebUiMessages.theme("light"))
        assertEquals("""{"type":"reload"}""", WebUiMessages.reload())
        assertEquals("""{"type":"open","target":{"view":"sql","databaseId":"app_db"}}""", WebUiMessages.openSql("app_db"))
    }

    @Test
    fun `savedQueries save, list and delete for the current app`() {
        host.app = "shop"
        host.store!!.save("crm", "Leads", "SELECT * FROM leads")
        val saved = request(1, "op" to "savedQueries.save", "name" to " Users ", "sql" to "SELECT * FROM users", "databaseType" to "sqlite")
        assertTrue(saved.get("ok").asBoolean)
        val result = saved.getAsJsonObject("result")
        assertEquals("shop", result.get("app").asString)
        val groups = result.getAsJsonArray("groups")
        assertEquals(listOf("shop", "crm"), groups.map { it.asJsonObject.get("app").asString })
        val query = groups[0].asJsonObject.getAsJsonArray("queries").single().asJsonObject
        assertEquals("Users", query.get("name").asString)
        assertEquals("SELECT * FROM users", query.get("sql").asString)
        assertEquals("sqlite", query.get("databaseType").asString)
        assertTrue(query.get("createdAt").asLong > 0)
        assertFalse(query.has("updatedAt"))

        // Saving the same name again updates it, keeping the id.
        val again = request(2, "op" to "savedQueries.save", "name" to "users", "sql" to "SELECT 1")
        val updated = again.getAsJsonObject("result").getAsJsonArray("groups")[0].asJsonObject.getAsJsonArray("queries").single().asJsonObject
        assertEquals(query.get("id"), updated.get("id"))
        assertTrue(updated.has("updatedAt"))

        val listed = request(3, "op" to "savedQueries.list").getAsJsonObject("result")
        assertEquals(result.getAsJsonArray("groups").size(), listed.getAsJsonArray("groups").size())

        val deleted = request(4, "op" to "savedQueries.delete", "app" to "shop", "id" to query.get("id").asString)
        assertEquals(listOf("crm"), deleted.getAsJsonObject("result").getAsJsonArray("groups").map { it.asJsonObject.get("app").asString })
        assertTrue(host.store!!.saved("shop").isEmpty())
    }

    @Test
    fun `savedQueries without a known app use the unknown app and omit app`() {
        val saved = request(1, "op" to "savedQueries.save", "name" to "q", "sql" to "SELECT 1").getAsJsonObject("result")
        assertFalse(saved.has("app"))
        assertEquals(SavedQueryStore.UNKNOWN_APP, saved.getAsJsonArray("groups")[0].asJsonObject.get("app").asString)
    }

    @Test
    fun `savedQueries validation and hosts without a store`() {
        for ((id, fields) in listOf(
            1 to arrayOf<Pair<String, Any?>>("op" to "savedQueries.save", "sql" to "SELECT 1"),
            2 to arrayOf<Pair<String, Any?>>("op" to "savedQueries.save", "name" to " ", "sql" to "SELECT 1"),
            3 to arrayOf<Pair<String, Any?>>("op" to "savedQueries.save", "name" to "q", "sql" to ""),
            4 to arrayOf<Pair<String, Any?>>("op" to "savedQueries.delete", "app" to "shop"),
        )) {
            val result = request(id, *fields)
            assertFalse(result.get("ok").asBoolean)
            assertEquals(ErrorCodes.INVALID_REQUEST, result.getAsJsonObject("error").get("code").asString)
        }
        host.store = null
        val unsupported = request(5, "op" to "savedQueries.list").getAsJsonObject("error")
        assertEquals(ErrorCodes.INVALID_REQUEST, unsupported.get("code").asString)
        // The web UI recognises this message and falls back to its own storage.
        assertTrue(unsupported.get("message").asString.contains("savedQueries"))
    }
}
