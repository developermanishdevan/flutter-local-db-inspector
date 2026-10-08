package com.manishdevan.flutterdb.ui

import com.intellij.icons.AllIcons
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CustomShortcutSet
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.Messages
import com.intellij.openapi.ui.popup.JBPopupFactory
import com.intellij.ui.DocumentAdapter
import com.intellij.ui.DoubleClickListener
import com.intellij.ui.OnePixelSplitter
import com.intellij.ui.PopupHandler
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTextArea
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.InspectorException
import com.manishdevan.flutterdb.protocol.RowRecord
import com.manishdevan.flutterdb.protocol.SqlResult
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.protocol.WireValue
import com.manishdevan.flutterdb.service.InspectorService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import java.awt.BorderLayout
import java.awt.event.MouseEvent
import javax.swing.Icon
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.event.DocumentEvent

/**
 * SQL console for databases with the `sql` capability: editor, Run
 * (Ctrl/Cmd+Enter), Cancel, results grid with timing, row counts and
 * truncation, write confirmation, history and saved queries (kept by the IDE).
 */
class SqlConsolePanel(
    private val project: Project,
    private val service: InspectorService,
    db: DatabaseDescriptor,
) : InspectorTab {
    override val key: String = keyFor(db.id)
    override val title: String = "SQL — ${db.name}"
    override val icon: Icon = AllIcons.Debugger.Console
    override var database: DatabaseDescriptor = db
        private set

    private val tasks = UiTasks(service.scope, this)
    private val editor = JBTextArea(service.queries.draft(db.id) ?: "", 8, 60).apply {
        font = monospaceFont()
        margin = JBUI.insets(6)
        emptyText.text = "SELECT * FROM … LIMIT 50;   Ctrl/Cmd+Enter runs the query (or the selection)."
    }
    private val model = RowsTableModel()
    private val grid = ValueTable(model)
    private val status = StatusLine()
    private val banner = ConnectionBanner()
    private val inspector = ValueInspectorPanel(tasks) { hideInspector() }
    private val resultsSplitter = OnePixelSplitter(false, "FlutterDb.sqlValueInspector", 0.68f)
    private var last: SqlResult? = null
    private var job: Job? = null
    private var runSeq = 0
    private var running = false
    private var connected = service.isConnected

    override val component: JComponent = JPanel(BorderLayout())

    init {
        editor.document.addDocumentListener(object : DocumentAdapter() {
            override fun textChanged(e: DocumentEvent) = service.queries.setDraft(database.id, editor.text)
        })
        action("Run") { run() }.registerCustomShortcutSet(CustomShortcutSet.fromString("control ENTER", "meta ENTER"), editor, this)
        action("Save Query") { saveQuery() }.registerCustomShortcutSet(CustomShortcutSet.fromString("control S", "meta S"), editor, this)

        object : DoubleClickListener() {
            override fun onDoubleClick(event: MouseEvent): Boolean {
                val row = grid.rowAtPoint(event.point)
                val col = grid.columnAtPoint(event.point)
                if (row < 0 || col < 0) return false
                openValue(row, col)
                return true
            }
        }.installOn(grid)
        grid.addMouseListener(object : PopupHandler() {
            override fun invokePopup(comp: java.awt.Component, x: Int, y: Int) {
                val row = grid.rowAtPoint(java.awt.Point(x, y))
                val col = grid.columnAtPoint(java.awt.Point(x, y))
                if (row < 0 || col < 0) return
                grid.changeSelection(row, col, false, false)
                showPopupMenu("FlutterDbSqlResults", DefaultActionGroup(
                    action("Copy Cell", AllIcons.Actions.Copy) { copyCell(row, col) },
                    action("Copy Row as JSON") { copyRow(row) },
                    action("View Value", AllIcons.Actions.Preview) { openValue(row, col) },
                ), grid, x, y)
            }
        })
        grid.selectionModel.addListSelectionListener {
            if (!it.valueIsAdjusting && inspector.isOpen && grid.selectedRow >= 0 && grid.selectedColumn >= 0) openValue(grid.selectedRow, grid.selectedColumn)
        }
        action("Copy Cell", enabled = { grid.selectedRow >= 0 && grid.selectedColumn >= 0 }) { copyCell(grid.selectedRow, grid.selectedColumn) }
            .registerCustomShortcutSet(com.intellij.openapi.actionSystem.CommonShortcuts.getCopy(), grid, this)

        val toolbar = toolbar(
            "FlutterDbSqlToolbar", component,
            action("Run", AllIcons.Actions.Execute, "Run (Ctrl/Cmd+Enter)", enabled = { connected && !running }) { run() },
            action("Cancel", AllIcons.Actions.Suspend, "Stop waiting for the result", enabled = { running }) { cancel() },
            com.intellij.openapi.actionSystem.Separator.getInstance(),
            action("Save Query…", AllIcons.Actions.MenuSaveall, "Save query (Ctrl/Cmd+S)") { saveQuery() },
            action("History", AllIcons.Vcs.History, "Query history") { e -> showHistory(e) },
            action("Saved Queries", AllIcons.Nodes.Favorite, "Saved queries") { e -> showSaved(e) },
            action("Copy Results as JSON", AllIcons.Actions.Copy, enabled = { last?.isWrite == false }) { copyAll() },
        )
        val limits = service.snapshot.status?.limits
        val header = JPanel(BorderLayout()).apply {
            border = JBUI.Borders.customLineBottom(JBUI.CurrentTheme.ToolWindow.borderColor())
            add(toolbar.component, BorderLayout.WEST)
            add(JBLabel("Reads return at most ${limits?.maxSqlRows ?: 100} rows · writes ask for confirmation").apply {
                foreground = UIUtil.getContextHelpForeground()
                border = JBUI.Borders.emptyRight(8)
            }, BorderLayout.EAST)
            add(banner, BorderLayout.SOUTH)
        }
        resultsSplitter.firstComponent = JBScrollPane(grid)
        val results = JPanel(BorderLayout()).apply {
            add(JPanel(BorderLayout()).apply {
                border = JBUI.Borders.customLine(JBUI.CurrentTheme.ToolWindow.borderColor(), 1, 0, 1, 0)
                add(status, BorderLayout.CENTER)
            }, BorderLayout.NORTH)
            add(resultsSplitter, BorderLayout.CENTER)
        }
        val split = OnePixelSplitter(true, "FlutterDb.sqlSplitter", 0.35f).apply {
            firstComponent = JBScrollPane(editor)
            secondComponent = results
        }
        component.add(header, BorderLayout.NORTH)
        component.add(split, BorderLayout.CENTER)
        status.info("Ready")
        banner.update(service.snapshot)
    }

    /** Replaces the editor text and optionally runs it. */
    fun setSql(sql: String, run: Boolean) {
        editor.text = sql
        editor.requestFocusInWindow()
        if (run) run()
    }

    private fun selectedSql(): String = (editor.selectedText?.takeIf { it.isNotBlank() } ?: editor.text).trim()

    fun run() {
        val sql = selectedSql()
        if (sql.isEmpty() || running) return
        val seq = ++runSeq
        val db = database
        running = true
        status.loading("Executing query…")
        job = tasks.launchUi {
            try {
                val result = try {
                    io { service.client.executeSql(db.id, sql) }
                } catch (e: InspectorException) {
                    if (!e.requiresConfirmation) throw e
                    val statement = e.details.get("statement")?.takeIf { it.isJsonPrimitive }?.asString ?: "This statement"
                    val choice = Messages.showDialog(
                        project,
                        "This query may modify application data.\n\n$statement on \"${db.name}\":\n\n${if (sql.length > 500) "${sql.take(500)}…" else sql}",
                        "Confirm Write",
                        arrayOf("Cancel", "Execute"),
                        0,
                        Messages.getWarningIcon(),
                    )
                    if (choice != 1) {
                        if (seq == runSeq) status.show("Not executed.", AllIcons.Actions.Cancel)
                        return@launchUi
                    }
                    io { service.client.executeSql(db.id, sql, allowWrite = true) }.also { service.dataChanged() }
                }
                service.queries.record(sql, db.id, db.name, ok = true, elapsedMs = result.elapsedMs, rowCount = result.rowCount)
                if (seq == runSeq) show(result)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                service.queries.record(sql, db.id, db.name, ok = false)
                if (seq == runSeq) status.error(errorText(e))
            } finally {
                if (seq == runSeq) running = false
            }
        }
    }

    /** The app can't abort a running statement; cancel stops waiting for it. */
    private fun cancel() {
        runSeq++
        job?.cancel()
        running = false
        status.show("Cancelled (the statement may still finish in the app).", AllIcons.Actions.Suspend)
    }

    private fun show(result: SqlResult) {
        last = result
        val time = String.format(java.util.Locale.US, "%.1f ms", result.elapsedMs)
        if (result.isWrite) {
            grid.applyData(emptyList(), emptyList())
            val affected = result.affectedRows?.let { "${Values.formatCount(it)} rows affected" } ?: "Statement executed"
            val lastId = result.lastInsertId?.let { " · last insert id $it" } ?: ""
            status.success("$affected$lastId · $time")
            return
        }
        grid.applyData(RowsTableModel.fromResult(result.columns), result.rows.map { RowRecord(null, it) })
        val rows = "${Values.formatCount(result.rowCount)} rows · $time"
        if (result.truncated) {
            status.warning("$rows · showing the first ${result.rowCount} rows — add LIMIT/OFFSET to page.")
        } else {
            status.success(rows)
        }
    }

    private fun openValue(row: Int, col: Int) {
        val result = last ?: return
        val column = result.columns.getOrNull(col) ?: return
        val value = result.rows.getOrNull(row)?.getOrNull(col) ?: return
        inspector.showValue(ValueOptions(column.name, column.valueType, value, editable = false, nullable = true))
        if (resultsSplitter.secondComponent == null) {
            resultsSplitter.secondComponent = inspector
            resultsSplitter.revalidate()
        }
    }

    private fun hideInspector() {
        resultsSplitter.secondComponent = null
        resultsSplitter.revalidate()
    }

    private fun copyCell(row: Int, col: Int) {
        val value = model.value(row, col) ?: return
        copyToClipboard(Values.copyText(value))
    }

    private fun copyRow(row: Int) {
        val result = last ?: return
        val values = result.rows.getOrNull(row) ?: return
        copyToClipboard(Values.stringifyPlain(Values.rowToObject(result.columns.map { it.name }, values)))
    }

    private fun copyAll() {
        val result = last ?: return
        val names = result.columns.map { it.name }
        val array = com.google.gson.JsonArray().apply { result.rows.forEach { add(Values.rowToObject(names, it)) } }
        copyToClipboard(Values.stringifyPlain(array))
        status.info("Copied ${result.rows.size} rows as JSON")
    }

    private fun saveQuery() {
        val sql = selectedSql()
        if (sql.isEmpty()) return
        val name = Messages.showInputDialog(project, "Name for this query:", "Save Query", null, sql.replace(Regex("\\s+"), " ").take(40), null)
        if (!name.isNullOrBlank()) service.queries.save(name.trim(), sql, database.type)
    }

    private fun showHistory(e: AnActionEvent) {
        val group = DefaultActionGroup()
        val history = service.queries.history
        if (history.isEmpty()) group.add(action("No queries yet", enabled = { false }) {})
        for (entry in history.take(50)) {
            val text = "${Values.relativeTime(entry.at)} · ${entry.databaseName} · ${entry.sql.replace(Regex("\\s+"), " ").take(70)}"
            group.add(action(text, if (entry.ok) null else AllIcons.General.Error) { setSql(entry.sql, run = false) })
        }
        if (history.isNotEmpty()) {
            group.addSeparator()
            group.add(action("Clear History…", AllIcons.Actions.GC) {
                if (Messages.showYesNoDialog(project, "Clear query history?", "Clear History", null) == Messages.YES) service.queries.clearHistory()
            })
        }
        showGroupPopup("Query History", group, e)
    }

    private fun showSaved(e: AnActionEvent) {
        val group = DefaultActionGroup()
        val saved = service.queries.saved
        if (saved.isEmpty()) group.add(action("No saved queries (Ctrl/Cmd+S saves one)", enabled = { false }) {})
        for (query in saved) {
            val sub = DefaultActionGroup(query.name, true)
            sub.add(action("Open") { setSql(query.sql, run = false) })
            sub.add(action("Run", AllIcons.Actions.Execute, enabled = { connected }) { setSql(query.sql, run = true) })
            sub.add(action("Copy SQL", AllIcons.Actions.Copy) { copyToClipboard(query.sql) })
            sub.add(action("Delete", AllIcons.General.Remove) { service.queries.deleteSaved(query.id) })
            group.add(sub)
        }
        showGroupPopup("Saved Queries", group, e)
    }

    private fun showGroupPopup(title: String, group: DefaultActionGroup, e: AnActionEvent) {
        val popup = JBPopupFactory.getInstance().createActionGroupPopup(title, group, e.dataContext, JBPopupFactory.ActionSelectionAid.SPEEDSEARCH, true)
        val source = e.inputEvent?.component as? JComponent
        if (source != null) popup.showUnderneathOf(source) else popup.showInFocusCenter()
    }

    override fun refresh() = Unit

    override fun connectionChanged(snapshot: ConnectionSnapshot) {
        connected = snapshot.state == ConnectionState.CONNECTED
        banner.update(snapshot)
    }

    override fun databaseUpdated(db: DatabaseDescriptor) {
        database = db
    }

    override fun dispose() = Unit

    companion object {
        fun keyFor(databaseId: String) = "sql:$databaseId"
    }
}
