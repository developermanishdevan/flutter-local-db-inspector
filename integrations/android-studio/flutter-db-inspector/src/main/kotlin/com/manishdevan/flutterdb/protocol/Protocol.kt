package com.manishdevan.flutterdb.protocol

import com.google.gson.JsonObject

/**
 * Constants of the Flutter DB Inspector protocol (v1).
 *
 * Mirrors `flutter_db_inspector_protocol` (Dart) and `src/protocol/types.ts`
 * of the VS Code extension. Unknown enum values, capability names, error
 * codes and extra fields from newer runtimes are tolerated, never rejected.
 */
object Protocol {
    const val VERSION = 1
    val SUPPORTED_VERSIONS: List<Int> = listOf(1)
    const val SERVICE_EXTENSION = "ext.flutter_db_inspector.request"
    const val SERVICE_EXTENSION_PARAM = "request"
    const val EVENT_DATABASES_CHANGED = "flutter_db_inspector.databasesChanged"
}

object Methods {
    const val INSPECTOR_STATUS = "inspector.status"
    const val DATABASE_LIST = "database.list"
    const val DATABASE_INFO = "database.info"
    const val DATABASE_STATS = "database.stats"
    const val SCHEMA_LIST = "schema.list"
    const val SCHEMA_TABLE = "schema.table"
    const val ROWS_QUERY = "rows.query"
    const val ROWS_COUNT = "rows.count"
    const val ROW_INSERT = "row.insert"
    const val ROW_UPDATE = "row.update"
    const val ROW_DELETE = "row.delete"
    const val TABLE_CLEAR = "table.clear"
    const val QUERY_EXECUTE = "query.execute"
    const val VALUE_READ = "value.read"
}

object ErrorCodes {
    const val INVALID_REQUEST = "INVALID_REQUEST"
    const val UNSUPPORTED_PROTOCOL_VERSION = "UNSUPPORTED_PROTOCOL_VERSION"
    const val INSPECTOR_DISABLED = "INSPECTOR_DISABLED"
    const val DATABASE_NOT_FOUND = "DATABASE_NOT_FOUND"
    const val TABLE_NOT_FOUND = "TABLE_NOT_FOUND"
    const val COLUMN_NOT_FOUND = "COLUMN_NOT_FOUND"
    const val ROW_NOT_FOUND = "ROW_NOT_FOUND"
    const val QUERY_FAILED = "QUERY_FAILED"
    const val PERMISSION_DENIED = "PERMISSION_DENIED"
    const val WRITE_NOT_ALLOWED = "WRITE_NOT_ALLOWED"
    const val UNSUPPORTED_OPERATION = "UNSUPPORTED_OPERATION"
    const val QUERY_TIMEOUT = "QUERY_TIMEOUT"
    const val RESULT_TOO_LARGE = "RESULT_TOO_LARGE"
    const val DATABASE_BUSY = "DATABASE_BUSY"
    const val INTERNAL_ERROR = "INTERNAL_ERROR"

    // Client-side codes (never sent by the runtime).
    const val NOT_CONNECTED = "NOT_CONNECTED"
    const val CONNECTION_LOST = "CONNECTION_LOST"
    const val CLIENT_TIMEOUT = "CLIENT_TIMEOUT"
}

object Capabilities {
    const val READ = "read"
    const val FILTER = "filter"
    const val SORT = "sort"
    const val SEARCH = "search"
    const val INSERT = "insert"
    const val UPDATE = "update"
    const val DELETE = "delete"
    const val CLEAR = "clear"
    const val SQL = "sql"
    const val SCHEMA = "schema"
    const val INDEXES = "indexes"
    const val EXPORT = "export"
}

/** Filter operators in the order the filter builder offers them. */
enum class FilterOperator(val id: String, val label: String, val unary: Boolean = false) {
    EQUALS("equals", "="),
    NOT_EQUALS("notEquals", "≠"),
    CONTAINS("contains", "contains"),
    STARTS_WITH("startsWith", "starts with"),
    ENDS_WITH("endsWith", "ends with"),
    GREATER_THAN("greaterThan", ">"),
    LESS_THAN("lessThan", "<"),
    GREATER_OR_EQUAL("greaterOrEqual", "≥"),
    LESS_OR_EQUAL("lessOrEqual", "≤"),
    IS_NULL("isNull", "is null", unary = true),
    IS_NOT_NULL("isNotNull", "is not null", unary = true),
    ;

    /** Operators that compare text and therefore never parse their operand. */
    val textual: Boolean get() = this == CONTAINS || this == STARTS_WITH || this == ENDS_WITH

    override fun toString(): String = label
}

/** Error thrown by the client for protocol failures and connection issues. */
class InspectorException(
    val code: String,
    message: String,
    val details: JsonObject = JsonObject(),
    cause: Throwable? = null,
) : Exception(message, cause) {
    /** True when a write was refused only because it was not yet confirmed. */
    val requiresConfirmation: Boolean
        get() = code == ErrorCodes.WRITE_NOT_ALLOWED && details.bool("requiresConfirmation") == true
}
