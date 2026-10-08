package com.manishdevan.flutterdb.protocol

import com.google.gson.JsonArray
import com.google.gson.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ValuesTest {
    private fun wire(json: String) = WireValue.fromJson(Json.parseStrict(json))

    @Test
    fun `displayCell renders every wire type`() {
        assertEquals(CellDisplay("NULL", CellKind.NULL), Values.displayCell(WireValue.Null))
        assertEquals(CellKind.BOOL, Values.displayCell(WireValue.Bool(true)).kind)
        assertEquals("42", Values.displayCell(wire("42")).text)
        assertEquals("9007199254740993", Values.displayCell(wire("""{"${'$'}type":"bigint","value":"9007199254740993"}""")).text)
        assertEquals(CellKind.MASKED, Values.displayCell(wire("""{"${'$'}type":"masked"}""")).kind)
        assertEquals("BLOB 2.0 KB", Values.displayCell(WireValue.Blob(2048, "", true)).text)
        assertEquals("BLOB 2.0 MB", Values.displayCell(WireValue.Blob(2L * 1024 * 1024, "", true)).text)
        assertEquals("""{"a":1}""", Values.displayCell(wire("""{"${'$'}type":"json","value":{"a":1}}""")).text)
        assertEquals(CellKind.PARTIAL, Values.displayCell(WireValue.Text("abc", 50000, true)).kind)
        assertTrue(Values.displayCell(WireValue.Text("abc", 50000, true)).text.endsWith("…"))
        assertEquals(301, Values.displayCell(WireValue.Str("x".repeat(1000))).text.length)
        assertEquals(CellKind.UNKNOWN, Values.displayCell(wire("""{"${'$'}type":"unknown","display":"Instance of Foo"}""")).kind)
        assertEquals(CellKind.UNKNOWN, Values.displayCell(wire("""{"${'$'}type":"fromTheFuture","x":1}""")).kind)
    }

    @Test
    fun `numbers keep their exact text`() {
        assertEquals(WireValue.Num("12345678901234567890"), wire("12345678901234567890"))
        assertEquals("1.50", (wire("1.50") as WireValue.Num).text)
        assertEquals("12345678901234567890", Json.stringify(wire("12345678901234567890").toJson()))
    }

    @Test
    fun `parseInput follows the column type`() {
        assertEquals(WireValue.Num("42"), Values.parseInput("42", "integer"))
        assertEquals(WireValue.Num("7"), Values.parseInput("007", "integer"))
        assertEquals(WireValue.BigInt("9007199254740993"), Values.parseInput("9007199254740993", "integer"))
        assertEquals(WireValue.Str("abc"), Values.parseInput("abc", "integer"))
        assertEquals(WireValue.Num("3.5"), Values.parseInput("3.5", "real"))
        assertEquals(WireValue.Str("x"), Values.parseInput("x", "real"))
        assertEquals(WireValue.Bool(true), Values.parseInput("true", "boolean"))
        assertEquals(WireValue.Bool(false), Values.parseInput("0", "boolean"))
        assertEquals(WireValue.Str("007"), Values.parseInput("007", "text"))
        assertEquals(WireValue.Json(JsonArray().apply { add(1) }.let { a -> Json.obj("a" to a) }), Values.parseInput("""{"a":[1]}""", "json"))
        assertEquals(WireValue.Str("dark"), Values.parseInput("dark", "json"))
    }

    @Test
    fun `parseLoose keeps unparseable text and big integers`() {
        assertEquals(WireValue.Str("hello"), Values.parseLoose("hello"))
        assertEquals(WireValue.Num("12"), Values.parseLoose("12"))
        assertEquals(WireValue.Str("12"), Values.parseLoose("\"12\""))
        assertEquals(WireValue.Null, Values.parseLoose("null"))
        assertEquals(WireValue.BigInt("12345678901234567890"), Values.parseLoose("12345678901234567890"))
        assertEquals(WireValue.Str("{a:1}"), Values.parseLoose("{a:1}"))
        assertEquals(WireValue.Str("1 2"), Values.parseLoose("1 2"))
    }

    @Test
    fun `masked, truncated and blob values are not inline editable`() {
        assertTrue(Values.isInlineEditable(WireValue.Str("x")))
        assertTrue(Values.isInlineEditable(WireValue.BigInt("1")))
        assertFalse(Values.isInlineEditable(WireValue.Masked))
        assertFalse(Values.isInlineEditable(WireValue.Text("", 1, true)))
        assertFalse(Values.isInlineEditable(WireValue.Blob(1, "", false)))
        assertFalse(Values.isInlineEditable(WireValue.Real("NaN")))
    }

    @Test
    fun `JSON copy keeps 64-bit integers exact and masks as null`() {
        val row = Values.rowToObject(
            listOf("id", "big", "tags", "secret", "empty"),
            listOf(WireValue.Num("1"), WireValue.BigInt("9007199254740993"), WireValue.Json(JsonArray().apply { add("a") }), WireValue.Masked, WireValue.Null),
        )
        assertEquals("""{"id":1,"big":9007199254740993,"tags":["a"],"secret":null,"empty":null}""", Values.stringifyPlain(row, pretty = false))
        assertEquals("{\n  \"id\": 1\n}", Values.stringifyPlain(Json.obj("id" to WireValue.Num("1")), pretty = true))
        assertEquals("9007199254740993", Values.copyText(WireValue.BigInt("9007199254740993")))
        assertEquals("", Values.copyText(WireValue.Masked))
    }

    @Test
    fun `CSV and SQL literals escape correctly`() {
        assertEquals("\"a,b\"", Values.csvField(WireValue.Str("a,b")))
        assertEquals("\"say \"\"hi\"\"\"", Values.csvField(WireValue.Str("say \"hi\"")))
        assertEquals("\" padded\"", Values.csvField(WireValue.Str(" padded")))
        assertEquals("", Values.csvField(WireValue.Null))
        assertEquals("9007199254740993", Values.csvField(WireValue.BigInt("9007199254740993")))
        assertEquals("\"{\"\"a\"\":1}\"", Values.csvField(WireValue.Json(Json.obj("a" to 1))))
        assertEquals("'O''Brien'", Values.sqlLiteral(WireValue.Str("O'Brien")))
        assertEquals("1", Values.sqlLiteral(WireValue.Bool(true)))
        assertEquals("-5", Values.sqlLiteral(WireValue.BigInt("-5")))
        assertEquals("X'00FF'", Values.sqlLiteral(WireValue.Blob(2, "", false, "AP8=")))
        assertEquals("NULL", Values.sqlLiteral(WireValue.Blob(2, "", true)))
        assertEquals("NULL", Values.sqlLiteral(WireValue.Masked))
        assertEquals("\"we\"\"ird\"", Values.sqlIdentifier("we\"ird"))
    }

    @Test
    fun `editText and formatting helpers`() {
        assertEquals("", Values.editText(WireValue.Null))
        assertEquals("2024-05-01T10:30:00.000Z", Values.editText(WireValue.DateTime("2024-05-01T10:30:00.000Z")))
        assertEquals("{\n  \"a\": 1\n}", Values.editText(WireValue.Json(Json.obj("a" to 1))))
        assertEquals("512 B", Values.formatBytes(512))
        assertEquals("1.5 KB", Values.formatBytes(1536))
        assertEquals("10 KB", Values.formatBytes(10 * 1024))
        assertEquals("1,234,567", Values.formatCount(1234567))
        assertEquals("just now", Values.relativeTime(1_000, 2_000))
        assertEquals("2 min ago", Values.relativeTime(0, 120_000))
        assertTrue(Values.hexDump(byteArrayOf(0x41, 0x00)).startsWith("00000000  41 00"))
        assertTrue(Values.hexDump(byteArrayOf(0x41, 0x00)).endsWith("A."))
        assertEquals("id = 7, tenant = \"a\"", Values.describeKey(Json.obj("id" to WireValue.Num("7"), "tenant" to "a")))
    }

    @Test
    fun `wire values round-trip through JSON`() {
        val samples = listOf(
            """{"${'$'}type":"bigint","value":"-9007199254740993"}""",
            """{"${'$'}type":"real","value":"NaN"}""",
            """{"${'$'}type":"text","preview":"abc","size":50000,"truncated":true}""",
            """{"${'$'}type":"blob","size":3,"preview":"AAEC","truncated":false}""",
            """{"${'$'}type":"dateTime","value":"2024-05-01T10:30:00.000Z"}""",
            """{"${'$'}type":"json","value":{"a":[1,2]}}""",
            """{"${'$'}type":"masked"}""",
            """{"${'$'}type":"unknown","display":"x"}""",
        )
        for (sample in samples) assertEquals(sample, Json.stringify(wire(sample).toJson()))
        assertEquals("""{"${'$'}type":"blob","base64":"AP8="}""", Json.stringify(WireValue.Blob(2, "", false, "AP8=").toJson()))
        assertEquals(JsonPrimitive("x"), WireValue.Str("x").toJson())
    }
}
