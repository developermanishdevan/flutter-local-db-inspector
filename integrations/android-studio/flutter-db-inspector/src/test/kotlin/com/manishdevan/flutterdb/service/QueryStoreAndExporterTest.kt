package com.manishdevan.flutterdb.service

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.manishdevan.flutterdb.protocol.Json
import com.manishdevan.flutterdb.protocol.Methods
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QueryStoreAndExporterTest {
    private fun store(limit: Int = 3) = QueryStore().apply { this.limit = { limit } }

    @Test
    fun `history is newest first, deduplicated per database and limited`() {
        val s = store()
        s.record("SELECT 1", "a", "A", ok = true, now = 1)
        s.record("SELECT 2", "a", "A", ok = true, now = 2)
        s.record(" SELECT 1 ", "a", "A", ok = false, now = 3)
        s.record("SELECT 1", "b", "B", ok = true, now = 4)
        s.record("SELECT 3", "a", "A", ok = true, now = 5)
        assertEquals(listOf("SELECT 3", "SELECT 1", "SELECT 1"), s.history.map { it.sql })
        assertEquals(listOf("a", "b", "a"), s.history.map { it.databaseId })
        s.deleteHistory(s.history.first().id)
        assertEquals(2, s.history.size)
        s.clearHistory()
        assertTrue(s.history.isEmpty())
    }

    @Test
    fun `history limit 0 disables history`() {
        val s = store(limit = 0)
        s.record("SELECT 1", "a", "A", ok = true)
        assertTrue(s.history.isEmpty())
    }

    @Test
    fun `saved queries are sorted by name and persisted in state`() {
        val s = store()
        var changes = 0
        s.addListener { changes++ }
        s.save("zeta", " SELECT z ", "sqlite")
        val alpha = s.save("Alpha", "SELECT a")
        assertEquals(listOf("Alpha", "zeta"), s.saved.map { it.name })
        assertEquals("SELECT z", s.saved[1].sql)
        s.deleteSaved(alpha.id)
        assertEquals(listOf("zeta"), s.state.saved.map { it.name })
        s.setDraft("a", "SELECT draft")
        assertEquals("SELECT draft", s.draft("a"))
        s.setDraft("a", " ")
        assertEquals(null, s.draft("a"))
        assertEquals(3, changes)

        val restored = store()
        restored.loadState(s.state)
        assertEquals(listOf("zeta"), restored.saved.map { it.name })
    }

    /** A fake app with 150 rows: exact big integers, a masked column and a truncated text. */
    private val fakeApp = RequestSender { method, params ->
        when (method) {
            Methods.SCHEMA_TABLE -> Json.parseStrict(
                """{"schema":{"name":"t","kind":"table","rowKey":"rowid","sql":"CREATE TABLE t (id INTEGER, secret TEXT, note TEXT, gen INTEGER GENERATED ALWAYS AS (id) VIRTUAL)","columns":[
                {"name":"id","valueType":"integer"},{"name":"secret","valueType":"text"},{"name":"note","valueType":"text"},{"name":"gen","valueType":"integer","generated":true}]},"sensitiveColumns":["secret"]}""",
            ).asJsonObject
            Methods.ROWS_QUERY -> {
                val page = params.get("page").asInt
                val size = params.get("pageSize").asInt
                val rows = JsonArray()
                for (i in page * size until minOf(150, (page + 1) * size)) {
                    val note = if (i == 0) Json.parseStrict("""{"${'$'}type":"text","preview":"lo","size":4,"truncated":true}""") else Json.toElement("n,$i")
                    rows.add(
                        Json.obj(
                            "key" to Json.obj("rowid" to i),
                            "values" to JsonArray().apply {
                                add(Json.number(if (i == 0) "9007199254740993" else "$i"))
                                add(Json.parseStrict("""{"${'$'}type":"masked"}"""))
                                add(note)
                                add(Json.number("$i"))
                            },
                        ),
                    )
                }
                Json.obj(
                    "columns" to Json.parseStrict("""[{"name":"id","valueType":"integer"},{"name":"secret","valueType":"text"},{"name":"note","valueType":"text"},{"name":"gen","valueType":"integer"}]"""),
                    "rows" to rows, "page" to page, "pageSize" to size, "total" to 150,
                )
            }
            Methods.VALUE_READ -> Json.obj("base64" to "bG9uZw==", "offset" to 0, "length" to 4, "totalBytes" to 4, "isText" to true, "done" to true)
            else -> JsonObject()
        }
    }

    @Test
    fun `export streams pages to JSON, CSV and SQL`() = runBlocking {
        val exporter = Exporter(InspectorClient(fakeApp))
        val json = StringBuilder()
        val summary = exporter.export("db", "t", ExportFormat.JSON, write = { json.append(it) })
        assertEquals(150L, summary.rows)
        assertEquals(setOf("secret"), summary.maskedColumns)
        val parsed = Json.parseStrict(json.toString()).asJsonArray
        assertEquals(150, parsed.size())
        assertTrue(json.toString().contains("""{"id":9007199254740993,"secret":null,"note":"long","gen":0}"""))

        val csv = StringBuilder()
        exporter.export("db", "t", ExportFormat.CSV, write = { csv.append(it) })
        val lines = csv.toString().trimEnd().split("\r\n")
        assertEquals(151, lines.size)
        assertEquals("id,secret,note,gen", lines[0])
        assertEquals("1,,\"n,1\",1", lines[2])

        val sql = StringBuilder()
        exporter.export("db", "t", ExportFormat.SQL, write = { sql.append(it) })
        assertTrue(sql.startsWith("CREATE TABLE t (id INTEGER, secret TEXT, note TEXT, gen INTEGER GENERATED ALWAYS AS (id) VIRTUAL);\n"))
        assertTrue(sql.contains("""INSERT INTO "t" ("id", "secret", "note") VALUES (9007199254740993, NULL, 'long');"""))

        var calls = 0
        val cancelled = exporter.export("db", "t", ExportFormat.CSV, write = {}, isCancelled = { calls++ > 0 })
        assertTrue(cancelled.cancelled)
        assertEquals(100L, cancelled.rows)
    }
}
