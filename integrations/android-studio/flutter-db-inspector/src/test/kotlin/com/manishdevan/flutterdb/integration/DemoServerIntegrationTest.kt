package com.manishdevan.flutterdb.integration

import com.manishdevan.flutterdb.connection.ConnectionManager
import com.manishdevan.flutterdb.connection.ConnectionOptions
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.connection.UriConnectionTarget
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.ErrorCodes
import com.manishdevan.flutterdb.protocol.InspectorException
import com.manishdevan.flutterdb.protocol.Json
import com.manishdevan.flutterdb.protocol.RowSort
import com.manishdevan.flutterdb.protocol.RowsQuery
import com.manishdevan.flutterdb.protocol.SortDirection
import com.manishdevan.flutterdb.protocol.WireValue
import com.manishdevan.flutterdb.service.ExportFormat
import com.manishdevan.flutterdb.service.Exporter
import com.manishdevan.flutterdb.service.InspectorClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Runs the real `VmServiceClient` + `ConnectionManager` against the Dart demo
 * server (a real Dart VM with the inspector and a seeded SQLite database),
 * including a simulated hot restart. Skipped when `dart` isn't on PATH.
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class DemoServerIntegrationTest {
    companion object {
        private val repoRoot = File(System.getProperty("fdi.repoRoot") ?: "../../..").canonicalFile
        private lateinit var process: Process
        private val lines = LinkedBlockingQueue<String>()
        private lateinit var scope: CoroutineScope
        private lateinit var manager: ConnectionManager
        private lateinit var client: InspectorClient
        private lateinit var uri: String

        private fun dartAvailable(): Boolean = try {
            ProcessBuilder("dart", "--version").redirectErrorStream(true).start().run {
                inputStream.readBytes()
                waitFor(60, TimeUnit.SECONDS) && exitValue() == 0
            }
        } catch (_: Exception) {
            false
        }

        @BeforeClass
        @JvmStatic
        fun startServer() {
            assumeTrue("dart is not on PATH — skipping the demo server integration test", dartAvailable())
            val demoPackage = File(repoRoot, "packages/flutter_db_inspector_sqlite")
            if (!File(demoPackage, ".dart_tool/package_config.json").exists()) {
                val pubGet = ProcessBuilder("dart", "pub", "get").directory(demoPackage).inheritIO().start()
                assumeTrue("dart pub get failed", pubGet.waitFor(300, TimeUnit.SECONDS) && pubGet.exitValue() == 0)
            }
            process = ProcessBuilder("dart", "run", "--enable-vm-service=0", "example/inspector_server.dart", "--restartable")
                .directory(File(repoRoot, "packages/flutter_db_inspector_sqlite"))
                .redirectError(ProcessBuilder.Redirect.INHERIT)
                .start()
            // Keep stdout drained, otherwise the demo server dies with EPIPE.
            Thread({
                process.inputStream.bufferedReader().forEachLine { lines.add(it) }
            }, "demo-server-stdout").apply { isDaemon = true }.start()
            val deadline = System.currentTimeMillis() + 180_000
            var found: String? = null
            while (found == null && System.currentTimeMillis() < deadline) {
                val line = lines.poll(1, TimeUnit.SECONDS) ?: continue
                found = Regex("VM service is listening on (\\S+)").find(line)?.groupValues?.get(1)
            }
            uri = found ?: error("demo server did not print its VM service URI")
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            manager = ConnectionManager(scope, ConnectionOptions(rescanIntervalMs = 250))
            client = InspectorClient { method, params -> manager.request(method, params) }
            runBlocking {
                manager.connect(UriConnectionTarget(uri, "demo"))
                waitFor { it.state == ConnectionState.CONNECTED }
            }
        }

        @AfterClass
        @JvmStatic
        fun stopServer() {
            if (::manager.isInitialized) manager.dispose()
            if (::scope.isInitialized) scope.cancel()
            if (::process.isInitialized && process.isAlive) {
                ProcessBuilder("kill", "-INT", process.pid().toString()).start().waitFor()
                if (!process.waitFor(20, TimeUnit.SECONDS)) process.destroyForcibly()
            }
        }

        suspend fun waitFor(timeoutMs: Long = 60_000, predicate: (ConnectionSnapshot) -> Boolean): ConnectionSnapshot =
            withTimeout(timeoutMs) {
                while (!predicate(manager.snapshot)) delay(20)
                manager.snapshot
            }

        suspend fun databases(timeoutMs: Long = 60_000): List<DatabaseDescriptor> = withTimeout(timeoutMs) {
            var dbs = client.listDatabases()
            while (dbs.isEmpty()) {
                delay(250)
                dbs = client.listDatabases()
            }
            dbs
        }
    }

    @Test
    fun t01_handshakeReportsProtocolAndLimits() {
        val status = manager.snapshot.status!!
        assertEquals(1, status.protocolVersion)
        assertEquals("fullAccess", status.mode)
        assertEquals(100, status.limits.maxPageSize)
    }

    @Test
    fun t02_listSchemaAndRowsWithSearchSortAndMasking() = runBlocking<Unit> {
        val db = databases().single()
        assertEquals("app_database", db.id)
        assertEquals("relational", db.dataModel)
        assertTrue(db.can("sql"))

        val overview = client.schema(db.id)
        val counts = overview.entities.associate { it.name to it.rowCount }
        assertEquals(1000L, counts["users"])
        assertEquals(10000L, counts["orders"])
        assertTrue(overview.entities.any { it.name == "active_users" && it.kind == "view" })

        val schema = client.tableSchema(db.id, "users")
        assertTrue("password" in schema.sensitiveColumns)
        assertTrue(schema.schema.column("id")!!.isPrimaryKey)

        val page = client.queryRows(RowsQuery(db.id, "users", pageSize = 5, search = "User 99", sort = listOf(RowSort("id", SortDirection.DESC))))
        assertEquals(11L, page.total)
        assertEquals(5, page.rows.size)
        assertEquals("""{"rowid":999}""", Json.stringify(page.rows[0].key!!))
        val pw = page.columns.indexOfFirst { it.name == "password" }
        assertEquals(WireValue.Masked, page.rows[0].values[pw])
    }

    @Test
    fun t03_exactBigIntegers() = runBlocking<Unit> {
        val page = client.queryRows(RowsQuery("app_database", "edge_cases"))
        val big = page.columns.indexOfFirst { it.name == "big_int" }
        val value = page.rows[0].values[big]
        val text = when (value) {
            is WireValue.BigInt -> value.value
            is WireValue.Num -> value.text
            else -> fail("unexpected $value").let { "" }
        }
        assertEquals("9007199254740993", text)
    }

    @Test
    fun t04_editACellAndSeeItInTheAppDatabase() = runBlocking<Unit> {
        client.updateRow("app_database", "users", Json.obj("rowid" to 1), mapOf("name" to WireValue.Str("Edited from IntelliJ")))
        val result = client.executeSql("app_database", "SELECT name FROM users WHERE id = 1")
        assertEquals(listOf(listOf(WireValue.Str("Edited from IntelliJ"))), result.rows)
    }

    @Test
    fun t05_writeSqlNeedsConfirmation() = runBlocking<Unit> {
        try {
            client.executeSql("app_database", "DELETE FROM orders WHERE id = 1")
            fail("expected WRITE_NOT_ALLOWED")
        } catch (e: InspectorException) {
            assertTrue(e.requiresConfirmation)
        }
        val done = client.executeSql("app_database", "DELETE FROM orders WHERE id = 1", allowWrite = true)
        assertEquals(1L, done.affectedRows)
    }

    @Test
    fun t06_largeBlobIsStreamedWithValueRead() = runBlocking<Unit> {
        val page = client.queryRows(RowsQuery("app_database", "edge_cases"))
        val blobIndex = page.columns.indexOfFirst { it.name == "data" }
        val cell = page.rows[0].values[blobIndex] as WireValue.Blob
        assertEquals(2L * 1024 * 1024, cell.size)
        val full = client.readFullValue("app_database", "edge_cases", page.rows[0].key!!, "data")
        assertEquals(2 * 1024 * 1024, full.bytes.size)
        assertEquals((1000 % 251).toByte(), full.bytes[1000])
        assertTrue(full.complete)
    }

    @Test
    fun t07_exportStreamsATableToCsv() = runBlocking<Unit> {
        val csv = StringBuilder()
        val summary = Exporter(client).export("app_database", "products", ExportFormat.CSV, write = { csv.append(it) })
        assertEquals(5000L, summary.rows)
        assertEquals(5001, csv.toString().trim().split("\r\n").size)
    }

    @Test
    fun t08_hotRestartReconnectsAutomatically() = runBlocking<Unit> {
        val before = manager.snapshot.isolateId
        // Record transitions: the restart can complete faster than a poll interval.
        val seen = java.util.concurrent.CopyOnWriteArrayList<ConnectionSnapshot>()
        val remove = manager.addStateListener { seen += it }
        process.outputStream.write("restart\n".toByteArray())
        process.outputStream.flush()
        withTimeout(60_000) {
            while (seen.none { it.state == ConnectionState.RECONNECTING } ||
                seen.lastOrNull()?.state != ConnectionState.CONNECTED
            ) {
                delay(20)
            }
        }
        remove()
        val after = manager.snapshot
        assertEquals(ConnectionState.CONNECTED, after.state)
        assertNotEquals(before, after.isolateId)
        assertEquals("app_database", databases().single().id)
        // Fresh isolate, fresh in-memory database: the earlier edit is gone.
        val result = client.executeSql("app_database", "SELECT name FROM users WHERE id = 1")
        assertEquals(listOf(listOf(WireValue.Str("User 1"))), result.rows)
    }

    @Test
    fun t09_requestsDuringARestartWaitForTheApp() = runBlocking<Unit> {
        process.outputStream.write("restart\n".toByteArray())
        process.outputStream.flush()
        // Fire a request immediately: it either waits for the restart or runs before it.
        val pending = async { client.listDatabases() }
        assertTrue(pending.await().size <= 1)
        waitFor { it.state == ConnectionState.CONNECTED }
    }

    @Test
    fun t10_stoppingTheAppDisconnects() = runBlocking<Unit> {
        ProcessBuilder("kill", "-INT", process.pid().toString()).start().waitFor()
        waitFor { it.state == ConnectionState.DISCONNECTED }
        try {
            client.listDatabases()
            fail("expected NOT_CONNECTED")
        } catch (e: InspectorException) {
            assertEquals(ErrorCodes.NOT_CONNECTED, e.code)
        }
        assertTrue(process.waitFor(20, TimeUnit.SECONDS))
    }
}
