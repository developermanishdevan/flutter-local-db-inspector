package com.manishdevan.flutterdb.protocol

/** User-facing wording derived from engine ids, data models and entity kinds. */
object Labels {
    private val ENGINE_LABELS = mapOf(
        "sqlite" to "SQLite",
        "sqflite" to "sqflite",
        "drift" to "Drift",
        "floor" to "Floor",
        "isar" to "Isar",
        "hive" to "Hive",
        "objectbox" to "ObjectBox",
        "realm" to "Realm",
        "sembast" to "Sembast",
        "shared_preferences" to "SharedPreferences",
        "secure_storage" to "Secure Storage",
        "get_storage" to "GetStorage",
    )

    fun engineLabel(type: String): String = ENGINE_LABELS[type] ?: type

    fun dataModelLabel(model: String): String = when (model) {
        "relational" -> "relational"
        "document" -> "object / document"
        "keyValue" -> "key-value"
        else -> model
    }

    fun entityGroupLabel(kind: String): String = when (kind) {
        "table" -> "Tables"
        "view" -> "Views"
        "collection" -> "Collections"
        "box" -> "Boxes"
        "store" -> "Stores"
        else -> "${kind.replaceFirstChar { it.uppercase() }}s"
    }

    /** Primary data first (tables / collections / boxes / stores), derived views after. */
    fun entityKindRank(kind: String): Int {
        val order = listOf("table", "collection", "box", "store", "view")
        return order.indexOf(kind).takeIf { it >= 0 } ?: order.size
    }

    /** Word for one record in an entity of this kind. */
    fun recordNoun(kind: String, plural: Boolean = false): String {
        val noun = when (kind) {
            "collection" -> "object"
            "box", "store" -> "entry"
            else -> "row"
        }
        if (!plural) return noun
        return if (noun == "entry") "entries" else "${noun}s"
    }
}
