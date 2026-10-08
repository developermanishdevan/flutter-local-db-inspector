package com.manishdevan.flutterdb.ui

import com.google.gson.JsonObject
import com.intellij.icons.AllIcons
import com.intellij.openapi.Disposable
import com.intellij.openapi.actionSystem.CommonShortcuts
import com.intellij.openapi.actionSystem.CustomShortcutSet
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.actionSystem.Separator
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.ComboBox
import com.intellij.openapi.ui.Messages
import com.intellij.openapi.util.Disposer
import com.intellij.ui.DoubleClickListener
import com.intellij.ui.OnePixelSplitter
import com.intellij.ui.PopupHandler
import com.intellij.ui.SearchTextField
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.util.ui.JBUI
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.protocol.Capabilities
import com.manishdevan.flutterdb.protocol.ColumnInfo
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.Labels
import com.manishdevan.flutterdb.protocol.RowFilter
import com.manishdevan.flutterdb.protocol.RowSort
import com.manishdevan.flutterdb.protocol.RowsPage
import com.manishdevan.flutterdb.protocol.RowsQuery
import com.manishdevan.flutterdb.protocol.SortDirection
import com.manishdevan.flutterdb.protocol.TableSchemaResult
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.protocol.WireValue
import com.manishdevan.flutterdb.service.InspectorService
import com.manishdevan.flutterdb.service.InspectorSettings
import java.awt.BorderLayout
import java.awt.FlowLayout
import java.awt.event.KeyEvent
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.KeyStroke
import javax.swing.SwingUtilities
import javax.swing.Timer
import javax.swing.event.DocumentEvent
import kotlin.math.ceil

/**
 * Data view of one entity: server-side paging, search, filters, sorting,
 * typed cells, inline editing, row actions, value inspector and export. A
 * port of the VS Code `TableView` data pane; all rules follow the database's
 * capabilities.
 */
class DataTablePanel(
    private val project: Project,
    private val service: InspectorService,
    db: DatabaseDescriptor,
    private val table: String,
    private val kind: String,
    private val entityReadOnly: Boolean,
    private val onSchema: (TableSchemaResult?, Throwable?) -> Unit,
) : JPanel(BorderLayout()), Disposable {
    var db: DatabaseDescriptor = db
        private set

    private val tasks = UiTasks(service.scope, this)
    private var schema: TableSchemaResult? = null
    private var page: RowsPage? = null
    private var pageIndex = 0
    private var pageSize = initialPageSize()
    private var search = ""
    private var filters: List<RowFilter> = emptyList()
    private var sort: List<RowSort> = emptyList()
    private var loadSeq = 0
    private var connected = service.isConnected

    private val model = RowsTableModel()
    private val grid = ValueTable(model)
    private val status = StatusLine()
    private val banner = ConnectionBanner()
    private val filterBar = FilterBar { applied ->
        filters = applied
        pageIndex = 0
        reload()
    }
    private val inspector = ValueInspectorPanel(tasks) { hideInspector() }
    private val splitter = OnePixelSplitter(false, "FlutterDb.valueInspector", 0.68f)
    private val pageLabel = JBLabel()
    private val pageSizeBox = ComboBox(pageSizes().toTypedArray())
    private val searchField = SearchTextField(false)
    private val searchTimer = Timer(300) {
        search = searchField.text.trim()
        pageIndex = 0
        reload()
    }.apply { isRepeats = false }

    init {
        model.canEdit = ::canEditCell
        model.onEdit = { row, col, text ->
            val column = model.columns.getOrNull(col)
            if (column != null) {
                SwingUtilities.invokeLater { update(row, column.name, Values.parseInput(text, column.valueType)) }
            }
        }
        grid.tableHeader.defaultRenderer = GridHeaderRenderer(grid.tableHeader.defaultRenderer, model) { sort }
        grid.tableHeader.addMouseListener(object : MouseAdapter() {
            override fun mouseClicked(e: MouseEvent) {
                if (!SwingUtilities.isLeftMouseButton(e) || !db.can(Capabilities.SORT)) return
                val col = grid.convertColumnIndexToModel(grid.columnAtPoint(e.point))
                model.columns.getOrNull(col)?.let { toggleSort(it.name) }
            }
        })
        grid.selectionModel.addListSelectionListener { if (!it.valueIsAdjusting) onSelection() }
        grid.columnModel.selectionModel.addListSelectionListener { if (!it.valueIsAdjusting) onSelection() }
        object : DoubleClickListener() {
            override fun onDoubleClick(event: MouseEvent): Boolean {
                val row = grid.rowAtPoint(event.point)
                val col = grid.columnAtPoint(event.point)
                if (row < 0 || col < 0 || canEditCell(row, col)) return false
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
                showPopupMenu("FlutterDbDataTable", cellMenu(row, col), grid, x, y)
            }
        })

        searchField.textEditor.emptyText.text = "Search"
        searchField.addDocumentListener(object : com.intellij.ui.DocumentAdapter() {
            override fun textChanged(e: DocumentEvent) = searchTimer.restart()
        })
        pageSizeBox.selectedItem = pageSize
        pageSizeBox.addActionListener {
            val size = pageSizeBox.selectedItem as? Int ?: return@addActionListener
            if (size != pageSize) {
                pageSize = size
                pageIndex = 0
                reload()
            }
        }

        add(JPanel(BorderLayout()).apply {
            add(buildToolbar(), BorderLayout.NORTH)
            add(JPanel(BorderLayout()).apply {
                add(banner, BorderLayout.NORTH)
                add(filterBar, BorderLayout.SOUTH)
            }, BorderLayout.SOUTH)
        }, BorderLayout.NORTH)
        splitter.firstComponent = JBScrollPane(grid)
        add(splitter, BorderLayout.CENTER)
        add(JPanel(BorderLayout()).apply {
            border = JBUI.Borders.customLineTop(JBUI.CurrentTheme.ToolWindow.borderColor())
            add(status, BorderLayout.CENTER)
        }, BorderLayout.SOUTH)
        registerShortcuts()
        banner.update(service.snapshot)
        Disposer.register(this) { searchTimer.stop() }
        reload(withSchema = true)
    }

    private fun initialPageSize(): Int {
        val preferred = InspectorSettings.getInstance().state.defaultPageSize
        return if (preferred in pageSizes()) preferred else pageSizes().lastOrNull { it <= 50 } ?: 25
    }

    private fun pageSizes(): List<Int> {
        val max = service.snapshot.status?.limits?.maxPageSize ?: 100
        return listOf(25, 50, 100).filter { it <= max }.ifEmpty { listOf(max) }
    }

    private fun noun(plural: Boolean = false) = Labels.recordNoun(kind, plural)

    private fun buildToolbar(): JComponent {
        val actions = mutableListOf(
            toggleAction("Filter", AllIcons.General.Filter, selected = { filterBar.isVisible }, enabled = { page != null }) { on ->
                if (on) filterBar.open(page?.columns.orEmpty().filter { it.name !in schema?.sensitiveColumns.orEmpty() }, filters) else filterBar.close()
                revalidate()
            }.takeIf { db.can(Capabilities.FILTER) },
            action("Refresh", AllIcons.Actions.Refresh, "Reload (Ctrl/Cmd+R, F5)") { reload(withSchema = true) },
            Separator.getInstance(),
            action("Add ${noun().replaceFirstChar { it.uppercase() }}…", AllIcons.General.Add, enabled = ::canInsert, visible = { db.can(Capabilities.INSERT) && staticWritable() }) { addRow() },
            action("View Value", AllIcons.Actions.Preview, enabled = { grid.selectedRow >= 0 && grid.selectedColumn >= 0 }) {
                openValue(grid.selectedRow, grid.selectedColumn)
            },
            action("Export…", AllIcons.ToolbarDecorator.Export, visible = { db.can(Capabilities.EXPORT) }, enabled = { connected }) {
                EntityOperations.exportEntity(project, service, db, table)
            },
            action("Clear…", AllIcons.Actions.GC, "Delete all records…", visible = { db.can(Capabilities.CLEAR) && staticWritable() }, enabled = { writable() }) {
                EntityOperations.clear(project, service, db, table, kind, tasks) { reload(withSchema = true) }
            },
        ).filterNotNull()
        val left = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(2), 0))
        if (db.can(Capabilities.SEARCH)) {
            searchField.preferredSize = JBUI.size(220, searchField.preferredSize.height)
            left.add(searchField)
        }
        left.add(toolbar("FlutterDbDataToolbar", this, *actions.toTypedArray()).component)

        val pager = JPanel(FlowLayout(FlowLayout.RIGHT, JBUI.scale(2), 0))
        pager.add(JBLabel("Rows per page:"))
        pager.add(pageSizeBox)
        pager.add(toolbar(
            "FlutterDbPager", this,
            action("First Page", AllIcons.Actions.Play_first, enabled = { pageIndex > 0 }) { go(0) },
            action("Previous Page", AllIcons.Actions.Play_back, enabled = { pageIndex > 0 }) { go(pageIndex - 1) },
        ).component)
        pager.add(pageLabel)
        pager.add(toolbar(
            "FlutterDbPager", this,
            action("Next Page", AllIcons.Actions.Play_forward, enabled = ::hasNext) { go(pageIndex + 1) },
            action("Last Page", AllIcons.Actions.Play_last, enabled = { pageCount()?.let { pageIndex < it - 1 } ?: false }) {
                go((pageCount() ?: 1) - 1)
            },
        ).component)
        return JPanel(BorderLayout()).apply {
            border = JBUI.Borders.customLineBottom(JBUI.CurrentTheme.ToolWindow.borderColor())
            add(left, BorderLayout.CENTER)
            add(pager, BorderLayout.EAST)
        }
    }

    private fun registerShortcuts() {
        // Disabled while a cell editor is active, so its own keys (Delete, Enter, copy) keep working.
        val idle = { !grid.isEditing && grid.selectedRow >= 0 && grid.selectedColumn >= 0 }
        action("Copy Cell", enabled = idle) { copyCell(grid.selectedRow, grid.selectedColumn) }
            .registerCustomShortcutSet(CommonShortcuts.getCopy(), grid, this)
        action("Copy Row as JSON", enabled = idle) { copyRowJson(grid.selectedRow) }
            .registerCustomShortcutSet(CustomShortcutSet.fromString("control shift C", "meta shift C"), grid, this)
        action("Delete Row", enabled = { idle() && writable() && db.can(Capabilities.DELETE) }) { deleteRow(grid.selectedRow) }
            .registerCustomShortcutSet(CommonShortcuts.getDelete(), grid, this)
        action("Open Cell", enabled = idle) {
            val row = grid.selectedRow
            val col = grid.selectedColumn
            if (canEditCell(row, col)) grid.editCellAt(row, col) else openValue(row, col)
        }.registerCustomShortcutSet(CustomShortcutSet(KeyStroke.getKeyStroke(KeyEvent.VK_ENTER, 0)), grid, this)
        action("Search", enabled = { db.can(Capabilities.SEARCH) }) {
            searchField.requestFocusInWindow()
            searchField.selectText()
        }.registerCustomShortcutSet(CommonShortcuts.getFind(), this, this)
        action("Refresh") { reload(withSchema = true) }
            .registerCustomShortcutSet(CustomShortcutSet.fromString("control R", "meta R", "F5"), this, this)
    }

    // -------------------------------------------------------------------------
    // Loading

    fun columnInfo(name: String): ColumnInfo? = schema?.schema?.column(name)

    fun reload(withSchema: Boolean = false) {
        val seq = ++loadSeq
        status.loading("Loading…")
        grid.setPaintBusy(true)
        val query = RowsQuery(db.id, table, pageIndex, pageSize, filters, sort, search.ifEmpty { null })
        val needSchema = withSchema || schema == null
        tasks.launch({
            val newSchema = if (needSchema) {
                try {
                    service.client.tableSchema(db.id, table)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (seq == loadSeq) javax.swing.SwingUtilities.invokeLater { onSchema(null, e) }
                    throw e
                }
            } else {
                null
            }
            val started = System.nanoTime()
            val result = service.client.queryRows(query)
            Triple(newSchema, result, (System.nanoTime() - started) / 1_000_000)
        }, onError = { e ->
            if (seq == loadSeq) {
                grid.setPaintBusy(false)
                status.error(errorText(e))
            }
        }) { (newSchema, result, elapsed) ->
            if (seq != loadSeq) return@launch
            grid.setPaintBusy(false)
            if (newSchema != null) {
                schema = newSchema
                onSchema(newSchema, null)
            }
            // Page fell off the end (rows were deleted): go back to the last page.
            val total = result.total
            if (result.rows.isEmpty() && pageIndex > 0 && total != null) {
                pageIndex = maxOf(0, ceil(total.toDouble() / pageSize).toInt() - 1)
                reload()
                return@launch
            }
            showPage(result, elapsed)
        }
    }

    private fun showPage(result: RowsPage, elapsed: Long) {
        val selectedRow = grid.selectedRow
        val selectedCol = grid.selectedColumn
        page = result
        val sensitive = schema?.sensitiveColumns.orEmpty()
        val columns = result.columns.map {
            GridColumn(it.name, it.valueType, it.declaredType, primaryKey = columnInfo(it.name)?.isPrimaryKey == true, masked = it.name in sensitive)
        }
        grid.applyData(columns, result.rows)
        grid.tableHeader.repaint()
        if (selectedRow in 0 until grid.rowCount && selectedCol in 0 until grid.columnCount) {
            grid.changeSelection(selectedRow, selectedCol, false, false)
        }
        val total = result.total
        val first = if (result.rows.isNotEmpty()) pageIndex.toLong() * pageSize + 1 else 0
        val last = pageIndex.toLong() * pageSize + result.rows.size
        val n = noun(total != 1L)
        val filtered = if (filters.isNotEmpty() || search.isNotEmpty()) " (filtered)" else ""
        status.info(
            if (total == null) {
                "${Values.formatCount(result.rows.size.toLong())} $n · $elapsed ms"
            } else {
                "${Values.formatCount(first)}–${Values.formatCount(last)} of ${Values.formatCount(total)} $n$filtered · $elapsed ms"
            },
        )
        pageLabel.text = "${Values.formatCount(pageIndex + 1L)}${pageCount()?.let { " / ${Values.formatCount(it.toLong())}" } ?: ""}"
        if (inspector.isOpen) onSelection()
    }

    private fun pageCount(): Int? = page?.total?.let { maxOf(1, ceil(it.toDouble() / pageSize).toInt()) }

    private fun hasNext(): Boolean {
        val pages = pageCount() ?: return (page?.rows?.size ?: 0) == pageSize
        return pageIndex < pages - 1
    }

    private fun go(index: Int) {
        pageIndex = index
        reload()
    }

    private fun toggleSort(column: String) {
        val current = sort.firstOrNull { it.column == column }
        // asc → desc → none
        sort = when (current?.direction) {
            null -> listOf(RowSort(column, SortDirection.ASC))
            SortDirection.ASC -> listOf(RowSort(column, SortDirection.DESC))
            SortDirection.DESC -> emptyList()
        }
        pageIndex = 0
        grid.tableHeader.repaint()
        reload()
    }

    // -------------------------------------------------------------------------
    // Connection / database

    fun connectionChanged(snapshot: ConnectionSnapshot) {
        connected = snapshot.state == ConnectionState.CONNECTED
        banner.update(snapshot)
        if (!connected && grid.isEditing) grid.cellEditor?.cancelCellEditing()
    }

    fun databaseUpdated(db: DatabaseDescriptor) {
        this.db = db
    }

    // -------------------------------------------------------------------------
    // Editing (same rules as the VS Code extension)

    /** Writes allowed by the database and entity, regardless of the connection. */
    private fun staticWritable(): Boolean = !db.readOnly && kind != "view" && !entityReadOnly

    private fun writable(): Boolean = connected && staticWritable()

    private fun canInsert(): Boolean = writable() && db.can(Capabilities.INSERT) && schema != null

    fun canEditCell(row: Int, col: Int): Boolean {
        val page = page ?: return false
        if (!writable() || !db.can(Capabilities.UPDATE)) return false
        val record = page.rows.getOrNull(row) ?: return false
        val column = page.columns.getOrNull(col) ?: return false
        val info = columnInfo(column.name) ?: return false
        if (record.key == null || info.generated) return false
        if (schema?.schema?.rowKey == "key" && info.isPrimaryKey) return false
        val value = record.values.getOrElse(col) { WireValue.Null }
        return Values.isInlineEditable(value) && !Values.isMasked(value) && !Values.isPartial(value)
    }

    private fun update(row: Int, column: String, value: WireValue, onSaved: () -> Unit = {}) {
        val key = page?.rows?.getOrNull(row)?.key ?: return
        tasks.launchUi {
            if (InspectorSettings.getInstance().state.confirmCellEdits) {
                val ok = Messages.showYesNoDialog(project, "Save changes to this ${noun()} in $table?\n\n$column", "Save Changes", "Save", Messages.getCancelButton(), null)
                if (ok != Messages.YES) return@launchUi
            }
            try {
                io { service.client.updateRow(db.id, table, key, mapOf(column to value)) }
                onSaved()
                service.dataChanged()
                reload()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                status.error(errorText(e))
            }
        }
    }

    private fun deleteRow(row: Int) {
        val record = page?.rows?.getOrNull(row) ?: return
        val key = record.key ?: return
        if (!writable() || !db.can(Capabilities.DELETE)) return
        val choice = Messages.showOkCancelDialog(
            project,
            "Delete this ${noun()}?\n\n$table: ${Values.describeKey(key)}\n\nThis changes the running app's ${Labels.engineLabel(db.type)} data.",
            "Delete ${noun().replaceFirstChar { it.uppercase() }}",
            "Delete",
            Messages.getCancelButton(),
            Messages.getWarningIcon(),
        )
        if (choice != Messages.OK) return
        tasks.launch({ service.client.deleteRow(db.id, table, key) }, onError = { status.error(errorText(it)) }) {
            service.dataChanged()
            reload()
        }
    }

    private fun addRow(initial: Map<String, WireValue> = emptyMap()) {
        val schema = schema ?: return
        val title = if (initial.isEmpty()) "Add ${noun()} to $table" else "Duplicate ${noun()}"
        val dialog = AddRowDialog(project, title, schema.schema.columns, initial) { values ->
            service.client.insertRow(db.id, table, values)
        }
        if (dialog.showAndGet()) {
            service.dataChanged()
            reload(withSchema = true)
        }
    }

    private fun duplicateRow(row: Int) {
        val page = page ?: return
        val record = page.rows.getOrNull(row) ?: return
        val initial = linkedMapOf<String, WireValue>()
        page.columns.forEachIndexed { i, c ->
            val info = columnInfo(c.name) ?: return@forEachIndexed
            val value = record.values.getOrElse(i) { WireValue.Null }
            // Keys and auto-assigned ids must be new; masked/truncated data can't be copied.
            if (info.autoIncrement || (schema?.schema?.rowKey == "key" && info.isPrimaryKey)) return@forEachIndexed
            if (Values.isMasked(value) || Values.isPartial(value) || value is WireValue.Blob) return@forEachIndexed
            initial[c.name] = value
        }
        addRow(initial)
    }

    // -------------------------------------------------------------------------
    // Values, copy, menus

    private fun onSelection() {
        if (inspector.isOpen && grid.selectedRow >= 0 && grid.selectedColumn >= 0) openValue(grid.selectedRow, grid.selectedColumn)
    }

    private fun openValue(row: Int, col: Int) {
        val page = page ?: return
        val record = page.rows.getOrNull(row) ?: return
        val column = page.columns.getOrNull(col) ?: return
        val value = record.values.getOrElse(col) { WireValue.Null }
        val info = columnInfo(column.name)
        val key: JsonObject? = record.key
        val editable = writable() && db.can(Capabilities.UPDATE) && key != null && info != null && !info.generated &&
            !Values.isMasked(value) && !(schema?.schema?.rowKey == "key" && info.isPrimaryKey)
        inspector.showValue(
            ValueOptions(
                column = column.name,
                valueType = column.valueType,
                value = value,
                editable = editable,
                nullable = info?.nullable ?: true,
                loadFull = key?.let { k -> { max: Long -> service.client.readFullValue(db.id, table, k, column.name, maxBytes = max) } },
                saveToFile = key?.let { k -> { EntityOperations.saveValueToFile(project, service, db, table, k, column.name) } },
                save = { v -> update(row, column.name, v) { inspector.saved(v) } },
            ),
        )
        if (splitter.secondComponent == null) {
            splitter.secondComponent = inspector
            splitter.revalidate()
        }
    }

    private fun hideInspector() {
        splitter.secondComponent = null
        splitter.revalidate()
        grid.requestFocusInWindow()
    }

    private fun copyCell(row: Int, col: Int) {
        val value = model.value(row, col) ?: return
        copyToClipboard(Values.copyText(value))
        status.info("Copied cell")
    }

    private fun copyRowJson(row: Int) {
        val record = page?.rows?.getOrNull(row) ?: return
        val names = page?.columns.orEmpty().map { it.name }
        copyToClipboard(Values.stringifyPlain(Values.rowToObject(names, record.values)))
        status.info("Copied row as JSON")
    }

    private fun copyRowCsv(row: Int) {
        val record = page?.rows?.getOrNull(row) ?: return
        copyToClipboard(Values.csvRow(record.values))
        status.info("Copied row as CSV")
    }

    private fun cellMenu(row: Int, col: Int): DefaultActionGroup {
        val group = DefaultActionGroup()
        val record = page?.rows?.getOrNull(row) ?: return group
        val column = page?.columns?.getOrNull(col) ?: return group
        val info = columnInfo(column.name)
        val rowWritable = writable() && record.key != null
        val noun = noun().replaceFirstChar { it.uppercase() }
        group.add(action("Copy Cell", AllIcons.Actions.Copy) { copyCell(row, col) })
        group.add(action("Copy Row as JSON") { copyRowJson(row) })
        group.add(action("Copy Row as CSV") { copyRowCsv(row) })
        group.addSeparator()
        group.add(action("View Value", AllIcons.Actions.Preview) { openValue(row, col) })
        if (rowWritable && db.can(Capabilities.UPDATE)) {
            group.add(action("Edit Cell", AllIcons.Actions.Edit, enabled = { canEditCell(row, col) }) { grid.editCellAt(row, col) })
            group.add(action("Set NULL", enabled = {
                canEditCell(row, col) && info?.nullable != false && record.values.getOrNull(col) != WireValue.Null
            }) { update(row, column.name, WireValue.Null) })
        }
        if (writable() && db.can(Capabilities.INSERT)) {
            group.addSeparator()
            group.add(action("Duplicate $noun…", AllIcons.Actions.Copy) { duplicateRow(row) })
        }
        if (rowWritable && db.can(Capabilities.DELETE)) {
            group.add(action("Delete $noun…", AllIcons.General.Remove) { deleteRow(row) })
        }
        return group
    }

    override fun dispose() = Unit
}
