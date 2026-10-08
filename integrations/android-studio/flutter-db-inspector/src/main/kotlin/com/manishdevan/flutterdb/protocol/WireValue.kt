package com.manishdevan.flutterdb.protocol

import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonPrimitive

/**
 * A value as produced by the runtime's value codec: lossless JSON values as
 * they are, everything else tagged with `$type` (see docs/protocol.md).
 */
sealed interface WireValue {
    fun toJson(): JsonElement

    data object Null : WireValue {
        override fun toJson(): JsonElement = JsonNull.INSTANCE
    }

    data class Bool(val value: Boolean) : WireValue {
        override fun toJson(): JsonElement = JsonPrimitive(value)
    }

    /** A JSON number, kept as its exact text so nothing is rounded. */
    data class Num(val text: String) : WireValue {
        val isInteger: Boolean get() = INTEGER.matches(text)
        override fun toJson(): JsonElement = com.manishdevan.flutterdb.protocol.Json.number(text)
    }

    data class Str(val value: String) : WireValue {
        override fun toJson(): JsonElement = JsonPrimitive(value)
    }

    /** Integers outside the JavaScript-safe range. */
    data class BigInt(val value: String) : WireValue {
        override fun toJson(): JsonElement = tagged("bigint", "value" to value)
    }

    /** Non-finite doubles (`NaN`, `Infinity`). */
    data class Real(val value: String) : WireValue {
        override fun toJson(): JsonElement = tagged("real", "value" to value)
    }

    /** Long text; only [preview] was sent. */
    data class Text(val preview: String, val size: Long, val truncated: Boolean) : WireValue {
        override fun toJson(): JsonElement = tagged("text", "preview" to preview, "size" to size, "truncated" to truncated)
    }

    /**
     * Binary data. Values from the app carry a short base64 [preview]; a
     * client-side complete value (export, writes) carries [base64].
     */
    data class Blob(val size: Long, val preview: String, val truncated: Boolean, val base64: String? = null) : WireValue {
        override fun toJson(): JsonElement =
            if (base64 != null) tagged("blob", "base64" to base64) else tagged("blob", "size" to size, "preview" to preview, "truncated" to truncated)
    }

    data class DateTime(val value: String) : WireValue {
        override fun toJson(): JsonElement = tagged("dateTime", "value" to value)
    }

    /** Maps and lists from document or key-value stores. */
    data class Json(val value: JsonElement) : WireValue {
        override fun toJson(): JsonElement = tagged("json", "value" to value)
    }

    /** Sensitive value; never sent by the app. */
    data object Masked : WireValue {
        override fun toJson(): JsonElement = tagged("masked")
    }

    data class Unknown(val display: String) : WireValue {
        override fun toJson(): JsonElement = tagged("unknown", "display" to display)
    }

    /** A tagged value of a type this client doesn't know (newer runtime). */
    data class Other(val raw: JsonObject) : WireValue {
        val type: String get() = raw.str(TYPE_KEY) ?: "?"
        override fun toJson(): JsonElement = raw
    }

    companion object {
        const val TYPE_KEY = "\$type"
        private val INTEGER = Regex("-?\\d+")

        fun fromJson(element: JsonElement?): WireValue {
            if (element == null || element.isJsonNull) return Null
            if (element.isJsonPrimitive) {
                val p = element.asJsonPrimitive
                return when {
                    p.isBoolean -> Bool(p.asBoolean)
                    p.isNumber -> Num(p.asNumber.toString())
                    else -> Str(p.asString)
                }
            }
            if (element.isJsonArray) return Json(element)
            val o = element.asJsonObject
            val type = o.str(TYPE_KEY) ?: return Json(o)
            return when (type) {
                "bigint" -> BigInt(o.str("value") ?: "0")
                "real" -> Real(o.str("value") ?: "NaN")
                "text" -> Text(o.str("preview") ?: "", o.long("size") ?: 0, o.bool("truncated") ?: true)
                "blob" -> Blob(o.long("size") ?: 0, o.str("preview") ?: "", o.bool("truncated") ?: false, o.str("base64"))
                "dateTime" -> DateTime(o.str("value") ?: "")
                "json" -> Json(o.get("value") ?: JsonNull.INSTANCE)
                "masked" -> Masked
                "unknown" -> Unknown(o.str("display") ?: "")
                else -> Other(o)
            }
        }

        private fun tagged(type: String, vararg pairs: Pair<String, Any?>): JsonObject =
            com.manishdevan.flutterdb.protocol.Json.obj(TYPE_KEY to type, *pairs)
    }
}
