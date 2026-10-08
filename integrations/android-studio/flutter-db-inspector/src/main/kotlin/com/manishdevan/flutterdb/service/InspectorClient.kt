package com.manishdevan.flutterdb.service

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.DatabaseInfo
import com.manishdevan.flutterdb.protocol.DatabaseMetadata
import com.manishdevan.flutterdb.protocol.DatabaseStats
import com.manishdevan.flutterdb.protocol.InspectorStatus
import com.manishdevan.flutterdb.protocol.Json
import com.manishdevan.flutterdb.protocol.Methods
import com.manishdevan.flutterdb.protocol.MutationResult
import com.manishdevan.flutterdb.protocol.RowsPage
import com.manishdevan.flutterdb.protocol.RowsQuery
import com.manishdevan.flutterdb.protocol.SchemaOverview
import com.manishdevan.flutterdb.protocol.SqlResult
import com.manishdevan.flutterdb.protocol.TableSchemaResult
import com.manishdevan.flutterdb.protocol.ValueChunk
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.protocol.WireValue
import com.manishdevan.flutterdb.protocol.objects
import java.io.ByteArrayOutputStream

/** Anything that can send protocol requests (the connection manager). */
fun interface RequestSender {
    suspend fun request(method: String, params: JsonObject): JsonObject
}

/** A complete large value read with `value.read`. */
class FullValue(val bytes: ByteArray, val isText: Boolean, val totalBytes: Long, val complete: Boolean) {
    val text: String get() = bytes.toString(Charsets.UTF_8)
}

/**
 * Typed protocol client. Every UI surface talks to the app only through this
 * class — never through the VM service directly.
 */
class InspectorClient(private val sender: RequestSender) {
    private suspend fun call(method: String, params: JsonObject = JsonObject()): JsonObject = sender.request(method, params)

    suspend fun status(): InspectorStatus = InspectorStatus.parse(call(Methods.INSPECTOR_STATUS))

    suspend fun listDatabases(): List<DatabaseDescriptor> =
        call(Methods.DATABASE_LIST).objects("databases").map(DatabaseDescriptor::parse)

    suspend fun databaseInfo(databaseId: String): DatabaseInfo {
        val result = call(Methods.DATABASE_INFO, Json.obj("databaseId" to databaseId))
        return DatabaseInfo(
            DatabaseDescriptor.parse(result.getAsJsonObject("database") ?: JsonObject()),
            DatabaseMetadata.parse(result.getAsJsonObject("metadata") ?: JsonObject()),
        )
    }

    suspend fun stats(databaseId: String): DatabaseStats =
        DatabaseStats.parse(call(Methods.DATABASE_STATS, Json.obj("databaseId" to databaseId)))

    suspend fun schema(databaseId: String): SchemaOverview =
        SchemaOverview.parse(call(Methods.SCHEMA_LIST, Json.obj("databaseId" to databaseId)))

    suspend fun tableSchema(databaseId: String, table: String): TableSchemaResult =
        TableSchemaResult.parse(call(Methods.SCHEMA_TABLE, Json.obj("databaseId" to databaseId, "table" to table)))

    suspend fun queryRows(query: RowsQuery): RowsPage = RowsPage.parse(call(Methods.ROWS_QUERY, query.toJson()))

    suspend fun countRows(query: RowsQuery): Long {
        val params = query.toJson().apply {
            remove("page")
            remove("pageSize")
            remove("sort")
        }
        return call(Methods.ROWS_COUNT, params).get("count")?.asLong ?: 0
    }

    suspend fun insertRow(databaseId: String, table: String, values: Map<String, WireValue>): MutationResult =
        MutationResult.parse(call(Methods.ROW_INSERT, Json.obj("databaseId" to databaseId, "table" to table, "values" to values)))

    suspend fun updateRow(databaseId: String, table: String, key: JsonObject, values: Map<String, WireValue>): MutationResult =
        MutationResult.parse(
            call(Methods.ROW_UPDATE, Json.obj("databaseId" to databaseId, "table" to table, "key" to key, "values" to values)),
        )

    suspend fun deleteRow(databaseId: String, table: String, key: JsonObject): MutationResult =
        MutationResult.parse(call(Methods.ROW_DELETE, Json.obj("databaseId" to databaseId, "table" to table, "key" to key)))

    suspend fun clearTable(databaseId: String, table: String): MutationResult =
        MutationResult.parse(call(Methods.TABLE_CLEAR, Json.obj("databaseId" to databaseId, "table" to table)))

    suspend fun executeSql(
        databaseId: String,
        sql: String,
        allowWrite: Boolean = false,
        maxRows: Int? = null,
        arguments: List<WireValue> = emptyList(),
    ): SqlResult {
        val params = Json.obj("databaseId" to databaseId, "sql" to sql)
        if (allowWrite) params.addProperty("allowWrite", true)
        if (maxRows != null) params.addProperty("maxRows", maxRows)
        if (arguments.isNotEmpty()) params.add("arguments", JsonArray().apply { arguments.forEach { add(it.toJson()) } })
        return SqlResult.parse(call(Methods.QUERY_EXECUTE, params))
    }

    suspend fun readValue(
        databaseId: String,
        table: String,
        key: JsonObject,
        column: String,
        offset: Long = 0,
        length: Long? = null,
    ): ValueChunk {
        val params = Json.obj("databaseId" to databaseId, "table" to table, "key" to key, "column" to column, "offset" to offset)
        if (length != null) params.addProperty("length", length)
        return ValueChunk.parse(call(Methods.VALUE_READ, params))
    }

    /** Reads a complete large value by streaming `value.read` chunks. */
    suspend fun readFullValue(
        databaseId: String,
        table: String,
        key: JsonObject,
        column: String,
        maxBytes: Long = Long.MAX_VALUE,
        onProgress: (read: Long, total: Long) -> Unit = { _, _ -> },
        isCancelled: () -> Boolean = { false },
    ): FullValue {
        val out = ByteArrayOutputStream()
        var offset = 0L
        var total = 0L
        var isText = true
        while (true) {
            val chunk = readValue(databaseId, table, key, column, offset)
            total = chunk.totalBytes
            isText = chunk.isText
            val data = Values.decodeBase64(chunk.base64)
            out.write(data)
            offset += data.size
            onProgress(offset, total)
            if (chunk.done || data.isEmpty() || offset >= maxBytes || isCancelled()) break
        }
        return FullValue(out.toByteArray(), isText, total, offset >= total)
    }
}
