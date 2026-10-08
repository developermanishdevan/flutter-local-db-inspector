package com.manishdevan.flutterdb.protocol

import com.google.gson.JsonPrimitive
import com.manishdevan.flutterdb.connection.ConnectionManager
import com.manishdevan.flutterdb.ui.FilterBar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ProtocolParsingTest {
    private fun obj(json: String) = Json.parseStrict(json).asJsonObject

    @Test
    fun `status and databases tolerate unknown fields and values`() {
        val status = InspectorStatus.parse(
            obj("""{"protocolVersion":1,"supportedVersions":[1,2],"packageVersion":"0.1.0","mode":"readOnly","methods":["database.list"],"limits":{"maxPageSize":100,"newLimit":5},"extra":true}"""),
        )
        assertEquals(listOf(1, 2), status.supportedVersions)
        assertEquals("readOnly", status.mode)
        assertEquals(100, status.limits.maxPageSize)
        assertEquals(100, status.limits.maxSqlRows) // default when missing

        val db = DatabaseDescriptor.parse(obj("""{"id":"app","name":"App","type":"sqlite","dataModel":"relational","capabilities":["read","sql","teleport"],"readOnly":false}"""))
        assertTrue(db.can("sql"))
        assertTrue(db.can("teleport"))
        assertTrue(db.isRelational)
    }

    @Test
    fun `schema, rows and SQL results`() {
        val schema = TableSchemaResult.parse(
            obj(
                """{"schema":{"name":"users","kind":"table","rowKey":"rowid","columns":[
                {"name":"id","valueType":"integer","declaredType":"INTEGER","nullable":false,"primaryKeyPosition":1,"autoIncrement":true,"generated":false},
                {"name":"password","valueType":"text","declaredType":"TEXT","nullable":true,"primaryKeyPosition":0,"autoIncrement":false,"generated":false}],
                "foreignKeys":[{"columns":["user_id"],"referencedTable":"users","referencedColumns":["id"],"onUpdate":"NO ACTION","onDelete":"CASCADE"}],
                "indexes":[],"triggers":[],"sql":"CREATE TABLE users (...)"},"sensitiveColumns":["password"]}""",
            ),
        )
        assertEquals(2, schema.schema.columns.size)
        assertTrue(schema.schema.column("id")!!.isPrimaryKey)
        assertEquals(setOf("password"), schema.sensitiveColumns)
        assertEquals("CASCADE", schema.schema.foreignKeys.single().onDelete)

        val page = RowsPage.parse(
            obj("""{"columns":[{"name":"id","valueType":"integer"},{"name":"password","valueType":"text"}],"rows":[{"key":{"rowid":9007199254740993},"values":[9007199254740993,{"${'$'}type":"masked"}]}],"page":0,"pageSize":50,"total":1}"""),
        )
        val row = page.rows.single()
        assertEquals("""{"rowid":9007199254740993}""", Json.stringify(row.key!!))
        assertEquals(WireValue.Masked, row.values[1])
        assertEquals(1L, page.total)

        val sql = SqlResult.parse(obj("""{"kind":"write","columns":[],"rows":[],"rowCount":0,"truncated":false,"affectedRows":3,"lastInsertId":7,"elapsedMs":1.25}"""))
        assertTrue(sql.isWrite)
        assertEquals(3L, sql.affectedRows)
        assertEquals(1.25, sql.elapsedMs, 0.0)
    }

    @Test
    fun `rows query serializes filters, sort and search`() {
        val query = RowsQuery(
            "db", "users", page = 2, pageSize = 25,
            filters = listOf(RowFilter("name", FilterOperator.CONTAINS, WireValue.Str("man")), RowFilter("email", FilterOperator.IS_NULL, WireValue.Str("ignored"))),
            sort = listOf(RowSort("created_at", SortDirection.DESC)),
            search = "x",
        )
        assertEquals(
            """{"databaseId":"db","table":"users","page":2,"pageSize":25,"filters":[{"column":"name","operator":"contains","value":"man"},{"column":"email","operator":"isNull"}],"sort":[{"column":"created_at","direction":"desc"}],"search":"x"}""",
            Json.stringify(query.toJson()),
        )
        assertFalse(RowsQuery("db", "t", search = "").toJson().has("search"))
    }

    @Test
    fun `filter builder parses values by column type`() {
        val columns = listOf(ResultColumn("age", "integer", null), ResultColumn("name", "text", null))
        val filters = FilterBar.buildFilters(
            listOf(
                Triple("age", FilterOperator.GREATER_THAN, "30"),
                Triple("age", FilterOperator.CONTAINS, "3"),
                Triple("name", FilterOperator.IS_NOT_NULL, "x"),
                Triple("", FilterOperator.EQUALS, "dropped"),
            ),
            columns,
        )
        assertEquals(3, filters.size)
        assertEquals(WireValue.Num("30"), filters[0].value)
        assertEquals(WireValue.Str("3"), filters[1].value)
        assertNull(filters[2].value)
    }

    @Test
    fun `responses unwrap results and map errors`() {
        val ok = ConnectionManager.parseResponse(Json.parseStrict("""{"version":1,"requestId":"1","success":true,"result":{"databases":[]}}"""))
        assertTrue(ok.has("databases"))
        // Some VM service versions return the extension result as a JSON string.
        val fromString = ConnectionManager.parseResponse(JsonPrimitive("""{"success":true,"result":{"a":1}}"""))
        assertEquals(1, fromString.get("a").asInt)
        try {
            ConnectionManager.parseResponse(
                Json.parseStrict("""{"success":false,"error":{"code":"WRITE_NOT_ALLOWED","message":"confirm","details":{"requiresConfirmation":true,"statement":"DELETE"}}}"""),
            )
            fail("expected an error")
        } catch (e: InspectorException) {
            assertEquals(ErrorCodes.WRITE_NOT_ALLOWED, e.code)
            assertTrue(e.requiresConfirmation)
        }
        try {
            ConnectionManager.parseResponse(Json.parseStrict("""{"nope":1}"""))
            fail("expected an error")
        } catch (e: InspectorException) {
            assertEquals(ErrorCodes.INTERNAL_ERROR, e.code)
        }
        assertFalse(InspectorException(ErrorCodes.WRITE_NOT_ALLOWED, "read-only", Json.obj("requiresConfirmation" to false)).requiresConfirmation)
    }

    @Test
    fun `labels follow data models and kinds`() {
        assertEquals("SQLite", Labels.engineLabel("sqlite"))
        assertEquals("custom", Labels.engineLabel("custom"))
        assertEquals("Boxes", Labels.entityGroupLabel("box"))
        assertEquals("Widgets", Labels.entityGroupLabel("widget"))
        assertEquals("entries", Labels.recordNoun("box", plural = true))
        assertEquals("object", Labels.recordNoun("collection"))
        assertTrue(Labels.entityKindRank("table") < Labels.entityKindRank("view"))
        assertTrue(Labels.entityKindRank("view") < Labels.entityKindRank("unknown"))
    }
}
