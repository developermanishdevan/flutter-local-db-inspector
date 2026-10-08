package com.manishdevan.flutterdb.protocol

import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive
import java.math.BigDecimal
import java.math.BigInteger
import java.text.NumberFormat
import java.util.Base64
import java.util.Locale

/** How a cell is styled. */
enum class CellKind { NULL, BOOL, NUMBER, TEXT, DATE, MASKED, PARTIAL, BLOB, JSON, UNKNOWN }

data class CellDisplay(val text: String, val kind: CellKind, val tooltip: String? = null)

/**
 * Display, copy, CSV/SQL and input rules for protocol values. A faithful port
 * of `src/protocol/values.ts` of the VS Code extension, so every client shows
 * and exports values the same way.
 */
object Values {
    const val MAX_CELL_CHARS = 300
    private val MAX_SAFE_INTEGER = BigInteger.valueOf(9007199254740991L)
    private val INTEGER = Regex("-?\\d+")
    private val JSON_NUMBER = Regex("-?(0|[1-9]\\d*)(\\.\\d+)?([eE][+-]?\\d+)?")
    private val TRUE = Regex("true|1", RegexOption.IGNORE_CASE)
    private val FALSE = Regex("false|0", RegexOption.IGNORE_CASE)

    fun isMasked(value: WireValue): Boolean = value is WireValue.Masked

    /** Value is a preview only (truncated text/blob); the full value needs `value.read`. */
    fun isPartial(value: WireValue): Boolean =
        (value is WireValue.Text && value.truncated) || (value is WireValue.Blob && value.truncated)

    /** Whether a cell can be edited inline without loss. */
    fun isInlineEditable(value: WireValue): Boolean = when (value) {
        WireValue.Null, is WireValue.Bool, is WireValue.Num, is WireValue.Str -> true
        is WireValue.BigInt, is WireValue.DateTime, is WireValue.Json -> true
        else -> false
    }

    fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = listOf("KB", "MB", "GB")
        var value = bytes / 1024.0
        var unit = 0
        while (value >= 1024 && unit < units.size - 1) {
            value /= 1024
            unit++
        }
        val text = if (value >= 10) String.format(Locale.US, "%.0f", value) else String.format(Locale.US, "%.1f", value)
        return "$text ${units[unit]}"
    }

    fun formatCount(n: Long?): String = if (n == null) "" else NumberFormat.getIntegerInstance(Locale.US).format(n)

    /** How a value is rendered in a grid cell. */
    fun displayCell(value: WireValue): CellDisplay = when (value) {
        WireValue.Null -> CellDisplay("NULL", CellKind.NULL)
        is WireValue.Bool -> CellDisplay(value.value.toString(), CellKind.BOOL)
        is WireValue.Num -> CellDisplay(value.text, CellKind.NUMBER)
        is WireValue.Str ->
            if (value.value.length > MAX_CELL_CHARS) {
                CellDisplay("${value.value.take(MAX_CELL_CHARS)}…", CellKind.TEXT, "${value.value.length} characters")
            } else {
                CellDisplay(value.value, CellKind.TEXT)
            }
        is WireValue.BigInt -> CellDisplay(value.value, CellKind.NUMBER)
        is WireValue.Real -> CellDisplay(value.value, CellKind.NUMBER)
        is WireValue.DateTime -> CellDisplay(value.value, CellKind.DATE)
        WireValue.Masked -> CellDisplay("••••••••", CellKind.MASKED, "Sensitive value (masked by the app)")
        is WireValue.Text -> CellDisplay("${value.preview.take(MAX_CELL_CHARS)}…", CellKind.PARTIAL, "Text, ${formatBytes(value.size)} (preview)")
        is WireValue.Blob -> CellDisplay("BLOB ${formatBytes(value.size)}", CellKind.BLOB)
        is WireValue.Json -> {
            val text = Json.stringify(value.value)
            CellDisplay(if (text.length > MAX_CELL_CHARS) "${text.take(MAX_CELL_CHARS)}…" else text, CellKind.JSON)
        }
        is WireValue.Unknown -> CellDisplay(value.display, CellKind.UNKNOWN, "Value has no JSON representation")
        is WireValue.Other -> CellDisplay(Json.stringify(value.raw), CellKind.UNKNOWN)
    }

    /**
     * Converts a wire value into plain JSON for copy/export. Large integers
     * stay exact numbers (never rounded or quoted); masked values become null.
     */
    fun toPlain(value: WireValue): JsonElement = when (value) {
        WireValue.Null -> JsonNull.INSTANCE
        is WireValue.Bool -> JsonPrimitive(value.value)
        is WireValue.Num -> Json.number(value.text)
        is WireValue.Str -> JsonPrimitive(value.value)
        is WireValue.BigInt -> Json.number(value.value)
        is WireValue.Real -> JsonPrimitive(value.value) // NaN / Infinity have no JSON form
        is WireValue.DateTime -> JsonPrimitive(value.value)
        is WireValue.Json -> value.value
        is WireValue.Text -> JsonPrimitive(value.preview)
        is WireValue.Blob -> value.base64?.let(::JsonPrimitive) ?: JsonNull.INSTANCE
        WireValue.Masked -> JsonNull.INSTANCE
        is WireValue.Unknown -> JsonPrimitive(value.display)
        is WireValue.Other -> JsonNull.INSTANCE
    }

    /** JSON text; [pretty] indents with two spaces like `JSON.stringify(v, null, 2)`. */
    fun stringifyPlain(value: JsonElement, pretty: Boolean = true): String =
        if (pretty) Json.prettyPrint(value) else Json.stringify(value)

    /** Builds a JSON object for a row. */
    fun rowToObject(columns: List<String>, values: List<WireValue>): JsonObject = JsonObject().apply {
        columns.forEachIndexed { i, c -> add(c, toPlain(values.getOrElse(i) { WireValue.Null })) }
    }

    /** Text copied for a single cell. */
    fun copyText(value: WireValue): String {
        val plain = toPlain(value)
        return when {
            plain.isJsonNull -> ""
            plain.isJsonPrimitive -> plain.asString
            else -> stringifyPlain(plain)
        }
    }

    fun csvField(value: WireValue): String {
        val plain = toPlain(value)
        if (plain.isJsonNull) return ""
        val text = if (plain.isJsonPrimitive) plain.asString else stringifyPlain(plain, pretty = false)
        val needsQuotes = text.any { it == '"' || it == ',' || it == '\r' || it == '\n' } ||
            (text.isNotEmpty() && (text.first().isWhitespace() || text.last().isWhitespace()))
        return if (needsQuotes) "\"${text.replace("\"", "\"\"")}\"" else text
    }

    fun csvRow(values: List<WireValue>): String = values.joinToString(",") { csvField(it) }

    fun sqlIdentifier(name: String): String = "\"${name.replace("\"", "\"\"")}\""

    private fun sqlString(text: String) = "'${text.replace("'", "''")}'"

    /** SQL literal for a wire value (blobs need `base64` filled in). */
    fun sqlLiteral(value: WireValue): String = when (value) {
        WireValue.Null -> "NULL"
        is WireValue.Bool -> if (value.value) "1" else "0"
        is WireValue.Num -> value.text
        is WireValue.Str -> sqlString(value.value)
        is WireValue.BigInt -> value.value
        is WireValue.Blob -> value.base64?.let { "X'${base64ToHex(it)}'" } ?: "NULL"
        is WireValue.Json -> sqlString(Json.stringify(value.value))
        is WireValue.DateTime -> "'${value.value}'"
        is WireValue.Real -> "'${value.value}'"
        is WireValue.Text -> sqlString(value.preview)
        else -> "NULL"
    }

    fun base64ToHex(base64: String): String =
        decodeBase64(base64).joinToString("") { "%02X".format(it.toInt() and 0xFF) }

    fun decodeBase64(base64: String): ByteArray = try {
        Base64.getDecoder().decode(base64)
    } catch (_: IllegalArgumentException) {
        ByteArray(0)
    }

    /** Text shown when editing a cell. */
    fun editText(value: WireValue): String = when (value) {
        WireValue.Null -> ""
        is WireValue.Bool -> value.value.toString()
        is WireValue.Num -> value.text
        is WireValue.Str -> value.value
        is WireValue.BigInt -> value.value
        is WireValue.Real -> value.value
        is WireValue.DateTime -> value.value
        is WireValue.Json -> Json.prettyPrint(value.value)
        else -> ""
    }

    /**
     * Converts user input into a wire value according to the column's type.
     * Input that doesn't fit the type is kept as text (SQLite and most
     * document stores accept it; the engine reports a clear error otherwise).
     */
    fun parseInput(text: String, valueType: String): WireValue {
        val trimmed = text.trim()
        return when (valueType) {
            "integer" ->
                if (INTEGER.matches(trimmed)) {
                    val n = BigInteger(trimmed)
                    if (n.abs() <= MAX_SAFE_INTEGER) WireValue.Num(n.toString()) else WireValue.BigInt(trimmed)
                } else {
                    WireValue.Str(text)
                }
            "real" -> parseReal(trimmed) ?: WireValue.Str(text)
            "boolean" -> when {
                TRUE.matches(trimmed) -> WireValue.Bool(true)
                FALSE.matches(trimmed) -> WireValue.Bool(false)
                else -> WireValue.Str(text)
            }
            "text", "dateTime" -> WireValue.Str(text)
            else -> parseLoose(text)
        }
    }

    private fun parseReal(trimmed: String): WireValue? {
        if (trimmed.isEmpty()) return null
        if (JSON_NUMBER.matches(trimmed)) return WireValue.Num(trimmed)
        val d = trimmed.toDoubleOrNull() ?: return null
        if (!d.isFinite()) return null
        return WireValue.Num(BigDecimal.valueOf(d).stripTrailingZeros().toPlainString())
    }

    /** For untyped/JSON columns: JSON when it parses, otherwise plain text. */
    fun parseLoose(text: String): WireValue {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return WireValue.Str(text)
        val parsed = Json.parseOrNull(trimmed) ?: return WireValue.Str(text)
        return when {
            parsed.isJsonNull -> WireValue.Null
            parsed.isJsonPrimitive && parsed.asJsonPrimitive.isBoolean -> WireValue.Bool(parsed.asBoolean)
            parsed.isJsonPrimitive && parsed.asJsonPrimitive.isString -> WireValue.Str(parsed.asString)
            parsed.isJsonPrimitive -> {
                val number = BigDecimal(trimmed)
                val integral = number.signum() == 0 || number.stripTrailingZeros().scale() <= 0
                if (integral && number.abs() > BigDecimal(MAX_SAFE_INTEGER)) WireValue.BigInt(trimmed) else WireValue.Num(trimmed)
            }
            else -> WireValue.Json(parsed)
        }
    }

    fun relativeTime(at: Long, now: Long = System.currentTimeMillis()): String {
        val seconds = Math.round((now - at) / 1000.0)
        if (seconds < 45) return "just now"
        val minutes = Math.round(seconds / 60.0)
        if (minutes < 60) return "$minutes min ago"
        val hours = Math.round(minutes / 60.0)
        if (hours < 24) return "$hours h ago"
        return "${Math.round(hours / 24.0)} d ago"
    }

    /** Classic 16-bytes-per-line hex dump with an ASCII column. */
    fun hexDump(bytes: ByteArray): String {
        if (bytes.isEmpty()) return "(no preview)"
        val out = StringBuilder()
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + 16, bytes.size)
            val hex = (offset until end).joinToString(" ") { "%02x".format(bytes[it].toInt() and 0xFF) }
            val ascii = (offset until end).map {
                val b = bytes[it].toInt() and 0xFF
                if (b in 32..126) b.toChar() else '.'
            }.joinToString("")
            if (out.isNotEmpty()) out.append('\n')
            out.append("%08x".format(offset)).append("  ").append(hex.padEnd(47)).append("  ").append(ascii)
            offset = end
        }
        return out.toString()
    }

    /** Key description for confirmations, e.g. `id = 7, tenant = "a"`. */
    fun describeKey(key: JsonObject): String =
        key.entrySet().joinToString(", ") { (k, v) -> "$k = ${Json.stringify(toPlain(WireValue.fromJson(v)))}" }
}
