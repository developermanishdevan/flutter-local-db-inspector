package com.manishdevan.flutterdb.protocol

import com.google.gson.JsonArray
import com.google.gson.JsonObject

/*
 * Wire types of protocol v1 with tolerant parsers: missing optional fields get
 * defaults, unknown fields are ignored.
 */

data class InspectorLimits(
    val defaultPageSize: Int = 50,
    val maxPageSize: Int = 100,
    val maxSqlRows: Int = 100,
    val maxResponseBytes: Long = 5L * 1024 * 1024,
    val queryTimeoutMs: Long = 5_000,
    val textPreviewBytes: Long = 10L * 1024,
    val blobChunkBytes: Long = 1024L * 1024,
) {
    companion object {
        fun parse(o: JsonObject?): InspectorLimits {
            val d = InspectorLimits()
            if (o == null) return d
            return InspectorLimits(
                defaultPageSize = o.int("defaultPageSize") ?: d.defaultPageSize,
                maxPageSize = o.int("maxPageSize") ?: d.maxPageSize,
                maxSqlRows = o.int("maxSqlRows") ?: d.maxSqlRows,
                maxResponseBytes = o.long("maxResponseBytes") ?: d.maxResponseBytes,
                queryTimeoutMs = o.long("queryTimeoutMs") ?: d.queryTimeoutMs,
                textPreviewBytes = o.long("textPreviewBytes") ?: d.textPreviewBytes,
                blobChunkBytes = o.long("blobChunkBytes") ?: d.blobChunkBytes,
            )
        }
    }
}

data class InspectorStatus(
    val protocolVersion: Int,
    val supportedVersions: List<Int>,
    val packageVersion: String,
    /** `disabled`, `readOnly` or `fullAccess` (or a newer mode). */
    val mode: String,
    val methods: List<String>,
    val limits: InspectorLimits,
) {
    companion object {
        fun parse(o: JsonObject): InspectorStatus = InspectorStatus(
            protocolVersion = o.int("protocolVersion") ?: 0,
            supportedVersions = o.arr("supportedVersions").mapNotNull { runCatching { it.asInt }.getOrNull() },
            packageVersion = o.str("packageVersion") ?: "",
            mode = o.str("mode") ?: "",
            methods = o.strings("methods"),
            limits = InspectorLimits.parse(o.obj("limits")),
        )
    }
}

data class DatabaseDescriptor(
    val id: String,
    val name: String,
    /** Engine id such as `sqlite`, `drift`, `hive`. */
    val type: String,
    val capabilities: Set<String>,
    /** `relational`, `document` or `keyValue`. */
    val dataModel: String,
    val readOnly: Boolean,
) {
    fun can(capability: String): Boolean = capability in capabilities

    val isRelational: Boolean get() = dataModel == "relational"

    companion object {
        fun parse(o: JsonObject): DatabaseDescriptor = DatabaseDescriptor(
            id = o.str("id") ?: "",
            name = o.str("name") ?: o.str("id") ?: "",
            type = o.str("type") ?: "",
            capabilities = o.strings("capabilities").toSet(),
            dataModel = o.str("dataModel") ?: "",
            readOnly = o.bool("readOnly") ?: false,
        )
    }
}

data class DatabaseMetadata(
    val engine: String,
    val engineVersion: String?,
    val path: String?,
    val sizeBytes: Long?,
    val extra: JsonObject,
) {
    companion object {
        fun parse(o: JsonObject): DatabaseMetadata = DatabaseMetadata(
            engine = o.str("engine") ?: "",
            engineVersion = o.str("engineVersion"),
            path = o.str("path"),
            sizeBytes = o.long("sizeBytes"),
            extra = o.obj("extra") ?: JsonObject(),
        )
    }
}

data class DatabaseInfo(val database: DatabaseDescriptor, val metadata: DatabaseMetadata)

data class EntitySummary(
    val name: String,
    /** `table`, `view`, `collection`, `box` or `store` (or a newer kind). */
    val kind: String,
    val rowCount: Long?,
    val readOnly: Boolean,
) {
    companion object {
        fun parse(o: JsonObject): EntitySummary = EntitySummary(
            name = o.str("name") ?: "",
            kind = o.str("kind") ?: "table",
            rowCount = o.long("rowCount"),
            readOnly = o.bool("readOnly") ?: false,
        )
    }
}

data class IndexInfo(
    val name: String,
    val table: String,
    val columns: List<String>,
    val unique: Boolean,
    val origin: String?,
    val partial: Boolean,
    val sql: String?,
) {
    companion object {
        fun parse(o: JsonObject): IndexInfo = IndexInfo(
            name = o.str("name") ?: "",
            table = o.str("table") ?: "",
            columns = o.strings("columns"),
            unique = o.bool("unique") ?: false,
            origin = o.str("origin"),
            partial = o.bool("partial") ?: false,
            sql = o.str("sql"),
        )
    }
}

data class TriggerInfo(val name: String, val table: String, val sql: String?) {
    companion object {
        fun parse(o: JsonObject): TriggerInfo = TriggerInfo(o.str("name") ?: "", o.str("table") ?: "", o.str("sql"))
    }
}

data class SchemaOverview(
    val entities: List<EntitySummary>,
    val indexes: List<IndexInfo>,
    val triggers: List<TriggerInfo>,
) {
    companion object {
        fun parse(o: JsonObject): SchemaOverview = SchemaOverview(
            entities = o.objects("entities").map(EntitySummary::parse),
            indexes = o.objects("indexes").map(IndexInfo::parse),
            triggers = o.objects("triggers").map(TriggerInfo::parse),
        )
    }
}

data class ColumnInfo(
    val name: String,
    /** `null`, `integer`, `real`, `text`, `boolean`, `blob`, `dateTime`, `json`, `unknown`. */
    val valueType: String,
    val declaredType: String,
    val nullable: Boolean,
    val primaryKeyPosition: Int,
    val defaultValue: String?,
    val autoIncrement: Boolean,
    val generated: Boolean,
) {
    val isPrimaryKey: Boolean get() = primaryKeyPosition > 0

    companion object {
        fun parse(o: JsonObject): ColumnInfo = ColumnInfo(
            name = o.str("name") ?: "",
            valueType = o.str("valueType") ?: "unknown",
            declaredType = o.str("declaredType") ?: "",
            nullable = o.bool("nullable") ?: true,
            primaryKeyPosition = o.int("primaryKeyPosition") ?: 0,
            defaultValue = o.str("defaultValue"),
            autoIncrement = o.bool("autoIncrement") ?: false,
            generated = o.bool("generated") ?: false,
        )
    }
}

data class ForeignKeyInfo(
    val columns: List<String>,
    val referencedTable: String,
    val referencedColumns: List<String>,
    val onUpdate: String,
    val onDelete: String,
) {
    companion object {
        fun parse(o: JsonObject): ForeignKeyInfo = ForeignKeyInfo(
            columns = o.strings("columns"),
            referencedTable = o.str("referencedTable") ?: "",
            referencedColumns = o.strings("referencedColumns"),
            onUpdate = o.str("onUpdate") ?: "",
            onDelete = o.str("onDelete") ?: "",
        )
    }
}

data class TableSchema(
    val name: String,
    val kind: String,
    val columns: List<ColumnInfo>,
    /** `rowid`, `primaryKey`, `key` or `none`. */
    val rowKey: String,
    val foreignKeys: List<ForeignKeyInfo>,
    val indexes: List<IndexInfo>,
    val triggers: List<TriggerInfo>,
    val sql: String?,
) {
    fun column(name: String): ColumnInfo? = columns.firstOrNull { it.name == name }

    companion object {
        fun parse(o: JsonObject): TableSchema = TableSchema(
            name = o.str("name") ?: "",
            kind = o.str("kind") ?: "table",
            columns = o.objects("columns").map(ColumnInfo::parse),
            rowKey = o.str("rowKey") ?: "none",
            foreignKeys = o.objects("foreignKeys").map(ForeignKeyInfo::parse),
            indexes = o.objects("indexes").map(IndexInfo::parse),
            triggers = o.objects("triggers").map(TriggerInfo::parse),
            sql = o.str("sql"),
        )
    }
}

data class TableSchemaResult(val schema: TableSchema, val sensitiveColumns: Set<String>) {
    companion object {
        fun parse(o: JsonObject): TableSchemaResult = TableSchemaResult(
            schema = TableSchema.parse(o.obj("schema") ?: JsonObject()),
            sensitiveColumns = o.strings("sensitiveColumns").toSet(),
        )
    }
}

data class RowFilter(val column: String, val operator: FilterOperator, val value: WireValue? = null) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("column", column)
        addProperty("operator", operator.id)
        if (!operator.unary && value != null) add("value", value.toJson())
    }
}

enum class SortDirection(val id: String) { ASC("asc"), DESC("desc") }

data class RowSort(val column: String, val direction: SortDirection) {
    fun toJson(): JsonObject = Json.obj("column" to column, "direction" to direction.id)
}

data class RowsQuery(
    val databaseId: String,
    val table: String,
    val page: Int = 0,
    val pageSize: Int = 50,
    val filters: List<RowFilter> = emptyList(),
    val sort: List<RowSort> = emptyList(),
    val search: String? = null,
) {
    fun toJson(): JsonObject = JsonObject().apply {
        addProperty("databaseId", databaseId)
        addProperty("table", table)
        addProperty("page", page)
        addProperty("pageSize", pageSize)
        add("filters", JsonArray().apply { filters.forEach { add(it.toJson()) } })
        add("sort", JsonArray().apply { sort.forEach { add(it.toJson()) } })
        if (!search.isNullOrEmpty()) addProperty("search", search)
    }
}

data class ResultColumn(val name: String, val valueType: String, val declaredType: String?) {
    companion object {
        fun parse(o: JsonObject): ResultColumn =
            ResultColumn(o.str("name") ?: "", o.str("valueType") ?: "unknown", o.str("declaredType"))
    }
}

/** A row; [key] is opaque and is sent back to the app unchanged. */
data class RowRecord(val key: JsonObject?, val values: List<WireValue>) {
    companion object {
        fun parse(o: JsonObject): RowRecord =
            RowRecord(o.obj("key"), o.arr("values").map(WireValue::fromJson))
    }
}

data class RowsPage(
    val columns: List<ResultColumn>,
    val rows: List<RowRecord>,
    val page: Int,
    val pageSize: Int,
    val total: Long?,
) {
    companion object {
        fun parse(o: JsonObject): RowsPage = RowsPage(
            columns = o.objects("columns").map(ResultColumn::parse),
            rows = o.objects("rows").map(RowRecord::parse),
            page = o.int("page") ?: 0,
            pageSize = o.int("pageSize") ?: 0,
            total = o.long("total"),
        )
    }
}

data class MutationResult(val affectedRows: Long, val insertedKey: JsonObject?) {
    companion object {
        fun parse(o: JsonObject): MutationResult = MutationResult(o.long("affectedRows") ?: 0, o.obj("insertedKey"))
    }
}

data class SqlResult(
    /** `read` or `write`. */
    val kind: String,
    val columns: List<ResultColumn>,
    val rows: List<List<WireValue>>,
    val rowCount: Long,
    val truncated: Boolean,
    val affectedRows: Long?,
    val lastInsertId: Long?,
    val elapsedMs: Double,
) {
    val isWrite: Boolean get() = kind == "write"

    companion object {
        fun parse(o: JsonObject): SqlResult {
            val rows = o.arr("rows").filter { it.isJsonArray }.map { row -> row.asJsonArray.map(WireValue::fromJson) }
            return SqlResult(
                kind = o.str("kind") ?: "read",
                columns = o.objects("columns").map(ResultColumn::parse),
                rows = rows,
                rowCount = o.long("rowCount") ?: rows.size.toLong(),
                truncated = o.bool("truncated") ?: false,
                affectedRows = o.long("affectedRows"),
                lastInsertId = o.long("lastInsertId"),
                elapsedMs = o.double("elapsedMs") ?: 0.0,
            )
        }
    }
}

data class DatabaseStats(
    val sizeBytes: Long?,
    val entityCount: Long,
    val indexCount: Long,
    val triggerCount: Long,
    val totalRows: Long,
    val entities: List<EntitySummary>,
) {
    companion object {
        fun parse(o: JsonObject): DatabaseStats = DatabaseStats(
            sizeBytes = o.long("sizeBytes"),
            entityCount = o.long("entityCount") ?: 0,
            indexCount = o.long("indexCount") ?: 0,
            triggerCount = o.long("triggerCount") ?: 0,
            totalRows = o.long("totalRows") ?: 0,
            entities = o.objects("entities").map(EntitySummary::parse),
        )
    }
}

data class ValueChunk(
    val base64: String,
    val offset: Long,
    val length: Long,
    val totalBytes: Long,
    val isText: Boolean,
    val done: Boolean,
) {
    companion object {
        fun parse(o: JsonObject): ValueChunk = ValueChunk(
            base64 = o.str("base64") ?: "",
            offset = o.long("offset") ?: 0,
            length = o.long("length") ?: 0,
            totalBytes = o.long("totalBytes") ?: 0,
            isText = o.bool("isText") ?: false,
            done = o.bool("done") ?: true,
        )
    }
}
