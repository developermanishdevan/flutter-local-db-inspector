package com.manishdevan.flutterdb.platform

import com.intellij.openapi.actionSystem.impl.ActionToolbarImpl
import com.intellij.testFramework.PlatformTestUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.intellij.ui.table.JBTable
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.service.InspectorService
import com.manishdevan.flutterdb.toolwindow.InspectorToolWindowPanel
import com.manishdevan.flutterdb.ui.EntityTab
import java.awt.Component
import java.awt.Container
import java.awt.image.BufferedImage
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import javax.imageio.ImageIO
import javax.swing.JTable

/**
 * Renders the real tool window against the live demo app in a headless IDE:
 * connects, opens a table, a SQL console and statistics, checks that data
 * arrived in the Swing components and paints each state to
 * `build/ui-snapshots/` for visual review.
 */
class ToolWindowRenderTest : BasePlatformTestCase() {
    private val repoRoot = File(System.getProperty("fdi.repoRoot") ?: "../../..").canonicalFile
    private var process: Process? = null

    override fun tearDown() {
        try {
            process?.let {
                ProcessBuilder("kill", "-INT", it.pid().toString()).start().waitFor()
                if (!it.waitFor(20, TimeUnit.SECONDS)) it.destroyForcibly()
            }
        } finally {
            super.tearDown()
        }
    }

    private fun dartAvailable(): Boolean = try {
        ProcessBuilder("dart", "--version").redirectErrorStream(true).start().run {
            inputStream.readBytes()
            waitFor(60, TimeUnit.SECONDS) && exitValue() == 0
        }
    } catch (_: Exception) {
        false
    }

    private fun startDemoServer(): String {
        val lines = LinkedBlockingQueue<String>()
        val p = ProcessBuilder("dart", "run", "--enable-vm-service=0", "example/inspector_server.dart")
            .directory(File(repoRoot, "packages/flutter_db_inspector_sqlite"))
            .redirectError(ProcessBuilder.Redirect.INHERIT)
            .start()
        process = p
        Thread({ p.inputStream.bufferedReader().forEachLine { lines.add(it) } }, "demo-stdout").apply { isDaemon = true }.start()
        val deadline = System.currentTimeMillis() + 180_000
        while (System.currentTimeMillis() < deadline) {
            val line = lines.poll(1, TimeUnit.SECONDS) ?: continue
            Regex("VM service is listening on (\\S+)").find(line)?.let { return it.groupValues[1] }
        }
        error("demo server did not start")
    }

    /** Pumps the EDT until [condition] holds. */
    private fun waitUntil(what: String, timeoutMs: Long = 60_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) fail("timed out waiting for $what")
            PlatformTestUtil.dispatchAllEventsInIdeEventQueue()
            Thread.sleep(50)
        }
    }

    private fun <T : Component> find(root: Component, type: Class<T>, predicate: (T) -> Boolean = { true }): T? {
        if (type.isInstance(root) && root.isShowingInHierarchy() && predicate(type.cast(root))) return type.cast(root)
        if (root is Container) for (child in root.components) find(child, type, predicate)?.let { return it }
        return null
    }

    private fun Component.isShowingInHierarchy(): Boolean {
        var c: Component? = this
        while (c != null) {
            if (!c.isVisible) return false
            c = c.parent
        }
        return true
    }

    private fun layout(c: Component) {
        c.doLayout()
        if (c is Container) c.components.forEach(::layout)
    }

    private fun <T : Component> findAll(root: Component, type: Class<T>, out: MutableList<T> = mutableListOf()): List<T> {
        if (type.isInstance(root)) out += type.cast(root)
        if (root is Container) root.components.forEach { findAll(it, type, out) }
        return out
    }

    private fun snapshot(panel: InspectorToolWindowPanel, name: String) {
        // Offscreen components never get addNotify() (which attaches JTable
        // headers to their scroll panes) or async toolbar updates; do both.
        for (table in findAll(panel, JTable::class.java)) {
            val scroll = javax.swing.SwingUtilities.getAncestorOfClass(javax.swing.JScrollPane::class.java, table) as? javax.swing.JScrollPane
            if (scroll != null && scroll.viewport.view === table && scroll.columnHeader?.view !== table.tableHeader) {
                scroll.setColumnHeaderView(table.tableHeader)
            }
        }
        panel.setSize(1500, 800)
        layout(panel)
        findAll(panel, ActionToolbarImpl::class.java).forEach { it.updateActionsAsync() }
        repeat(10) {
            PlatformTestUtil.dispatchAllEventsInIdeEventQueue()
            Thread.sleep(50)
        }
        repeat(3) {
            layout(panel)
            PlatformTestUtil.dispatchAllEventsInIdeEventQueue()
        }
        val image = BufferedImage(panel.width, panel.height, BufferedImage.TYPE_INT_RGB)
        val g = image.createGraphics()
        try {
            panel.paint(g)
        } finally {
            g.dispose()
        }
        val dir = File("build/ui-snapshots").apply { mkdirs() }
        ImageIO.write(image, "png", File(dir, "$name.png"))
    }

    fun testRendersLiveDataFromTheApp() {
        if (!dartAvailable()) return // same opt-out as the integration test
        val uri = startDemoServer()
        val service = InspectorService.getInstance(project)
        val panel = InspectorToolWindowPanel(project, testRootDisposable)

        service.connectUri(uri, "demo")
        waitUntil("connected") { service.snapshot.state == ConnectionState.CONNECTED }
        waitUntil("databases") { service.model.overviews.isNotEmpty() }
        val db = service.model.databases.single()
        assertEquals("app_database", db.id)
        snapshot(panel, "1-connected-tree")

        // Table-name filter narrows the tree to matches (indexes included).
        fun rows() = (0 until panel.treePanel.tree.rowCount).map { panel.treePanel.tree.getPathForRow(it).lastPathComponent.toString() }
        panel.treePanel.filter = "ORD"
        PlatformTestUtil.dispatchAllEventsInIdeEventQueue()
        val filtered = rows()
        assertTrue("filtered rows: $filtered", filtered.any { "name=orders" in it })
        assertTrue("filtered rows: $filtered", filtered.any { "name=idx_orders_user" in it })
        assertFalse("filtered rows: $filtered", filtered.any { "name=users," in it || "name=products" in it })
        snapshot(panel, "1b-filtered-tree")
        panel.treePanel.filter = "no-such-table"
        PlatformTestUtil.dispatchAllEventsInIdeEventQueue()
        assertTrue(rows().any { "No names match" in it })
        panel.treePanel.filter = ""
        PlatformTestUtil.dispatchAllEventsInIdeEventQueue()
        assertTrue(rows().any { "name=users," in it })

        panel.openEntity(db, "users", "table", EntityTab.DATA)
        waitUntil("users rows") {
            find(panel, JBTable::class.java) { it.rowCount >= 50 } != null
        }
        val grid = find(panel, JBTable::class.java) { it.rowCount >= 50 }!!
        assertEquals(50, grid.rowCount)
        val headers = (0 until grid.columnCount).map { grid.getColumnName(it) }
        assertTrue("columns: $headers", headers.any { it.contains("email") })
        snapshot(panel, "2-users-data")

        panel.openEntity(db, "users", "table", EntityTab.SCHEMA)
        snapshot(panel, "3-users-schema")

        panel.openSql(db, "SELECT status, COUNT(*) AS n FROM orders GROUP BY status ORDER BY n DESC", run = true)
        waitUntil("sql results") {
            find(panel, JTable::class.java) { t -> (0 until t.columnCount).any { t.getColumnName(it).contains("status") } && t.rowCount == 5 } != null
        }
        snapshot(panel, "4-sql-console")

        panel.openStatistics(db)
        Thread.sleep(1000)
        PlatformTestUtil.dispatchAllEventsInIdeEventQueue()
        snapshot(panel, "5-statistics")

        service.disconnect()
        waitUntil("disconnected") { service.snapshot.state == ConnectionState.DISCONNECTED }
    }
}
