package com.manishdevan.flutterdb.service

import com.manishdevan.flutterdb.protocol.ResultColumn
import com.manishdevan.flutterdb.protocol.RowRecord
import com.manishdevan.flutterdb.protocol.RowsQuery
import com.manishdevan.flutterdb.protocol.TableSchema
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.protocol.WireValue
import java.util.Base64

enum class ExportFormat(val extension: String, val label: String) {
    JSON("json", "JSON"),
    CSV("csv", "CSV"),
    SQL("sql", "SQL (INSERT statements)"),
    ;

    companion object {
        /** SQL export only makes sense for relational databases. */
        fun available(relational: Boolean): List<ExportFormat> = if (relational) entries else listOf(JSON, CSV)
    }
}

data class ExportSummary(val rows: Long, val maskedColumns: Set<String>, val truncatedValues: Int, val cancelled: Boolean)

/**
 * Streams an entity to JSON, CSV or SQL by paging through `rows.query`.
 * Truncated values and blobs are completed with `value.read`; masked values
 * are exported as `null` and reported. A port of `exporter.ts`.
 */
class Exporter(private val client: InspectorClient) {
    suspend fun export(
        databaseId: String,
        table: String,
        format: ExportFormat,
        /** Receives output text incrementally (keeps memory bounded). */
        write: (String) -> Unit,
        onProgress: (rows: Long, total: Long?) -> Unit = { _, _ -> },
        isCancelled: () -> Boolean = { false },
        /** Full values above this size are exported as their preview. */
        maxValueBytes: Long = 16L * 1024 * 1024,
    ): ExportSummary {
        val schema: TableSchema? = if (format == ExportFormat.SQL) client.tableSchema(databaseId, table).schema else null
        val masked = linkedSetOf<String>()
        var truncatedValues = 0
        var rows = 0L
        var columns: List<ResultColumn> = emptyList()
        var first = true

        if (format == ExportFormat.JSON) write("[\n")
        if (format == ExportFormat.SQL && !schema?.sql.isNullOrBlank()) {
            write("${schema!!.sql!!.trim().removeSuffix(";")};\n\n")
        }

        var page = 0
        while (!isCancelled()) {
            val result = client.queryRows(RowsQuery(databaseId, table, page = page, pageSize = PAGE_SIZE))
            if (page == 0) {
                columns = result.columns
                if (format == ExportFormat.CSV) write("${columns.joinToString(",") { Values.csvField(WireValue.Str(it.name)) }}\r\n")
            }
            val names = columns.map { it.name }
            val out = StringBuilder()
            for (row in result.rows) {
                val values = completeValues(databaseId, table, names, row, maxValueBytes) { masked += it }
                truncatedValues += values.count(Values::isPartial)
                when (format) {
                    ExportFormat.JSON -> {
                        out.append(if (first) "" else ",\n").append("  ")
                            .append(Values.stringifyPlain(Values.rowToObject(names, values), pretty = false))
                    }
                    ExportFormat.CSV -> out.append(Values.csvRow(values)).append("\r\n")
                    ExportFormat.SQL -> {
                        val insertable = columns.indices.filter { i -> schema?.column(columns[i].name)?.generated != true }
                        out.append("INSERT INTO ${Values.sqlIdentifier(table)} (")
                            .append(insertable.joinToString(", ") { Values.sqlIdentifier(columns[it].name) })
                            .append(") VALUES (")
                            .append(insertable.joinToString(", ") { Values.sqlLiteral(values.getOrElse(it) { WireValue.Null }) })
                            .append(");\n")
                    }
                }
                first = false
                rows++
            }
            if (out.isNotEmpty()) write(out.toString())
            onProgress(rows, result.total)
            if (result.rows.size < PAGE_SIZE) break
            page++
        }
        if (format == ExportFormat.JSON) write("${if (first) "" else "\n"}]\n")
        return ExportSummary(rows, masked, truncatedValues, isCancelled())
    }

    private suspend fun completeValues(
        databaseId: String,
        table: String,
        names: List<String>,
        row: RowRecord,
        maxValueBytes: Long,
        onMasked: (String) -> Unit,
    ): List<WireValue> {
        val values = row.values.toMutableList()
        for (i in values.indices) {
            val value = values[i]
            if (Values.isMasked(value)) {
                onMasked(names.getOrElse(i) { "#$i" })
                values[i] = WireValue.Null
                continue
            }
            val key = row.key ?: continue
            if (Values.isPartial(value) || value is WireValue.Blob) {
                val size = when (value) {
                    is WireValue.Text -> value.size
                    is WireValue.Blob -> value.size
                    else -> 0
                }
                if (size > maxValueBytes) continue
                val full = client.readFullValue(databaseId, table, key, names[i])
                values[i] = if (full.isText) {
                    WireValue.Str(full.text)
                } else {
                    WireValue.Blob(full.bytes.size.toLong(), "", false, Base64.getEncoder().encodeToString(full.bytes))
                }
            }
        }
        return values
    }

    companion object {
        const val PAGE_SIZE = 100
    }
}
