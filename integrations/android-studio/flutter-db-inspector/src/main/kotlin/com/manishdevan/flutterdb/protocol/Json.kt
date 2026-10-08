package com.manishdevan.flutterdb.protocol

import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParseException
import com.google.gson.JsonPrimitive
import com.google.gson.internal.LazilyParsedNumber
import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import java.io.StringReader

/** JSON helpers shared by the protocol, transport and value code. */
object Json {
    private val compact: Gson = GsonBuilder().serializeNulls().disableHtmlEscaping().create()
    private val pretty: Gson = GsonBuilder().serializeNulls().disableHtmlEscaping().setPrettyPrinting().create()
    private val elementAdapter = compact.getAdapter(JsonElement::class.java)

    /** Compact JSON (like `JSON.stringify(value)`). Numbers keep their exact text. */
    fun stringify(element: JsonElement): String = compact.toJson(element)

    /** Indented JSON (like `JSON.stringify(value, null, 2)`). */
    fun prettyPrint(element: JsonElement): String = pretty.toJson(element)

    /**
     * Parses [text] as standard JSON (no comments, unquoted strings or
     * trailing data). Numbers are kept as their exact text.
     */
    fun parseStrict(text: String): JsonElement {
        // A new JsonReader is strict (not lenient) by default.
        val reader = JsonReader(StringReader(text))
        val element = elementAdapter.read(reader) ?: JsonNull.INSTANCE
        if (reader.peek() != JsonToken.END_DOCUMENT) throw JsonParseException("Unexpected data after JSON value")
        return element
    }

    /** Like [parseStrict] but returns `null` instead of throwing. */
    fun parseOrNull(text: String): JsonElement? = try {
        parseStrict(text)
    } catch (_: Exception) {
        null
    }

    /** A JSON number written verbatim (exact 64-bit integers, decimals). */
    fun number(text: String): JsonPrimitive = JsonPrimitive(LazilyParsedNumber(text))

    fun obj(vararg pairs: Pair<String, Any?>): JsonObject = JsonObject().apply {
        for ((key, value) in pairs) add(key, toElement(value))
    }

    fun toElement(value: Any?): JsonElement = when (value) {
        null -> JsonNull.INSTANCE
        is JsonElement -> value
        is WireValue -> value.toJson()
        is String -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value)
        is Iterable<*> -> JsonArray().apply { value.forEach { add(toElement(it)) } }
        is Map<*, *> -> JsonObject().apply { value.forEach { (k, v) -> add(k.toString(), toElement(v)) } }
        else -> JsonPrimitive(value.toString())
    }
}

internal fun JsonObject.member(name: String): JsonElement? = get(name)?.takeUnless { it.isJsonNull }

internal fun JsonObject.str(name: String): String? =
    member(name)?.takeIf { it.isJsonPrimitive }?.asString

internal fun JsonObject.long(name: String): Long? =
    member(name)?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isNumber }?.let { runCatching { it.asLong }.getOrNull() }

internal fun JsonObject.int(name: String): Int? = long(name)?.toInt()

internal fun JsonObject.double(name: String): Double? =
    member(name)?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isNumber }?.asDouble

internal fun JsonObject.bool(name: String): Boolean? =
    member(name)?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean }?.asBoolean

internal fun JsonObject.obj(name: String): JsonObject? = member(name)?.takeIf { it.isJsonObject }?.asJsonObject

internal fun JsonObject.arr(name: String): JsonArray = member(name)?.takeIf { it.isJsonArray }?.asJsonArray ?: JsonArray()

internal fun JsonObject.objects(name: String): List<JsonObject> =
    arr(name).filter { it.isJsonObject }.map { it.asJsonObject }

internal fun JsonObject.strings(name: String): List<String> =
    arr(name).filter { it.isJsonPrimitive }.map { it.asString }
