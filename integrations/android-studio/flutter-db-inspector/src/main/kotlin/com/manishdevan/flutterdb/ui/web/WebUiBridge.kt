package com.manishdevan.flutterdb.ui.web

import com.google.gson.JsonObject
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.protocol.ErrorCodes
import com.manishdevan.flutterdb.protocol.InspectorException
import com.manishdevan.flutterdb.protocol.Json
import com.manishdevan.flutterdb.protocol.long
import com.manishdevan.flutterdb.protocol.obj
import com.manishdevan.flutterdb.protocol.str
import com.manishdevan.flutterdb.service.SavedQuery
import com.manishdevan.flutterdb.service.SavedQueryStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.Base64

/** What the web UI asks of the IDE (see the "App mode" host contract in `shared/web-ui/README.md`). */
interface WebUiHost {
    /** Sends a protocol request to the app; throws [InspectorException] for protocol errors. */
    suspend fun call(method: String, params: JsonObject): JsonObject

    suspend fun copy(text: String, label: String?)

    /** Asks where to save [name] and writes [bytes]. Returns false if the user cancelled. */
    suspend fun saveFile(name: String, bytes: ByteArray): Boolean

    fun notify(message: String, level: String?)

    /** The page is ready (again, after a reload): send `init`, then the current connection state. */
    fun onReady()

    fun logError(message: String)

    /** The connected (or last connected) app's Dart package name; null when unknown. */
    fun currentApp(): String? = null

    /** Where saved queries are kept per app; null leaves the `savedQueries.*` requests unsupported. */
    val savedQueries: SavedQueryStore? get() = null
}

/**
 * Host side of the web UI protocol, independent of JCEF: parses messages
 * from the page, runs requests on [scope] and posts answers with [post]
 * (JSON text of a host message).
 */
class WebUiBridge(
    private val scope: CoroutineScope,
    private val host: WebUiHost,
    private val post: (String) -> Unit,
) {
    /** Handles one message posted by the page (`window.fdiHost.postMessage(json)`). */
    fun onMessage(json: String) {
        val message = Json.parseOrNull(json)?.takeIf { it.isJsonObject }?.asJsonObject
        if (message == null) {
            host.logError("malformed message from the web UI: ${json.take(200)}")
            return
        }
        when (message.str("type")) {
            "ready" -> host.onReady()
            "error" -> host.logError(message.str("message") ?: "unknown error")
            "request" -> {
                val id = message.long("id")
                val request = message.obj("request")
                if (id == null) {
                    host.logError("request without id: ${json.take(200)}")
                    return
                }
                if (request == null) {
                    post(WebUiMessages.error(id, ErrorCodes.INVALID_REQUEST, "Missing request"))
                    return
                }
                scope.launch { post(handle(id, request)) }
            }
            else -> host.logError("unknown message from the web UI: ${message.str("type")}")
        }
    }

    /** Runs [request] and returns the `result` message. */
    suspend fun handle(id: Long, request: JsonObject): String = try {
        when (val op = request.str("op")) {
            "call" -> {
                val method = request.str("method") ?: throw invalid("call: missing method")
                WebUiMessages.ok(id, host.call(method, request.obj("params") ?: JsonObject()))
            }
            "copy" -> {
                host.copy(request.str("text") ?: throw invalid("copy: missing text"), request.str("label"))
                WebUiMessages.ok(id, JsonObject())
            }
            "saveFile" -> {
                val name = request.str("name") ?: throw invalid("saveFile: missing name")
                val bytes = request.str("text")?.toByteArray(Charsets.UTF_8)
                    ?: request.str("base64")?.let(::decodeBase64)
                    ?: throw invalid("saveFile: missing text or base64")
                val saved = host.saveFile(name, bytes)
                WebUiMessages.ok(id, if (saved) JsonObject() else Json.obj("cancelled" to true))
            }
            "notify" -> {
                host.notify(request.str("message") ?: throw invalid("notify: missing message"), request.str("level"))
                WebUiMessages.ok(id, JsonObject())
            }
            "savedQueries.list" -> WebUiMessages.ok(id, savedQueries(savedQueryStore(op)))
            "savedQueries.save" -> {
                val store = savedQueryStore(op)
                val name = request.str("name")?.takeIf { it.isNotBlank() } ?: throw invalid("savedQueries.save: missing name")
                val sql = request.str("sql")?.takeIf { it.isNotBlank() } ?: throw invalid("savedQueries.save: missing sql")
                store.save(host.currentApp() ?: SavedQueryStore.UNKNOWN_APP, name, sql, request.str("databaseType"))
                WebUiMessages.ok(id, savedQueries(store))
            }
            "savedQueries.delete" -> {
                val store = savedQueryStore(op)
                val app = request.str("app") ?: throw invalid("savedQueries.delete: missing app")
                store.deleteSaved(app, request.str("id") ?: throw invalid("savedQueries.delete: missing id"))
                WebUiMessages.ok(id, savedQueries(store))
            }
            else -> throw invalid("Unsupported request: $op")
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: InspectorException) {
        WebUiMessages.error(id, e.code, e.message ?: e.code, e.details)
    } catch (e: Exception) {
        WebUiMessages.error(id, ErrorCodes.INTERNAL_ERROR, e.message ?: e.javaClass.simpleName)
    }

    private fun savedQueryStore(op: String): SavedQueryStore = host.savedQueries ?: throw invalid("Unsupported request: $op")

    /** `SavedQueriesResult`: the current app (omitted when unknown) and every app's queries, the current app first. */
    private fun savedQueries(store: SavedQueryStore): JsonObject {
        val app = host.currentApp()
        val groups = store.savedGroups(app ?: SavedQueryStore.UNKNOWN_APP)
            .map { Json.obj("app" to it.app, "queries" to it.queries.map(::savedQueryJson)) }
        return Json.obj("groups" to groups).apply { app?.let { addProperty("app", it) } }
    }

    private fun savedQueryJson(q: SavedQuery): JsonObject {
        val json = Json.obj("id" to q.id, "name" to q.name, "sql" to q.sql, "createdAt" to q.createdAt)
        q.databaseType?.let { json.addProperty("databaseType", it) }
        q.updatedAt?.let { json.addProperty("updatedAt", it) }
        return json
    }

    private fun invalid(message: String) = InspectorException(ErrorCodes.INVALID_REQUEST, message)

    private fun decodeBase64(text: String): ByteArray = try {
        Base64.getDecoder().decode(text)
    } catch (e: IllegalArgumentException) {
        throw InspectorException(ErrorCodes.INVALID_REQUEST, "saveFile: invalid base64", cause = e)
    }
}

/** Host → UI messages (`HostMessage` in the VS Code extension's `messages.ts`), as JSON text. */
object WebUiMessages {
    fun init(host: String, pageSize: Int, theme: String, confirmCellEdits: Boolean, historyLimit: Int): String = Json.stringify(
        Json.obj(
            "type" to "init",
            "view" to "app",
            "host" to host,
            "pageSize" to pageSize,
            "theme" to theme,
            "confirmCellEdits" to confirmCellEdits,
            "historyLimit" to historyLimit,
        ),
    )

    fun connection(snapshot: ConnectionSnapshot): String {
        val message = Json.obj("type" to "connection", "state" to snapshot.state.name.lowercase())
        snapshot.message?.let { message.addProperty("message", it) }
        return Json.stringify(message)
    }

    fun event(name: String): String = Json.stringify(Json.obj("type" to "event", "name" to name))

    fun theme(theme: String): String = Json.stringify(Json.obj("type" to "theme", "theme" to theme))

    fun reload(): String = Json.stringify(Json.obj("type" to "reload"))

    fun openSql(databaseId: String): String =
        Json.stringify(Json.obj("type" to "open", "target" to Json.obj("view" to "sql", "databaseId" to databaseId)))

    fun ok(id: Long, result: JsonObject): String =
        Json.stringify(Json.obj("type" to "result", "id" to id, "ok" to true, "result" to result))

    fun error(id: Long, code: String, message: String, details: JsonObject? = null): String {
        val error = Json.obj("code" to code, "message" to message)
        if (details != null && details.size() > 0) error.add("details", details)
        return Json.stringify(Json.obj("type" to "result", "id" to id, "ok" to false, "error" to error))
    }
}
