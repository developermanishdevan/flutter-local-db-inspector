package com.manishdevan.flutterdb.ui

import com.intellij.icons.AllIcons
import com.intellij.ui.DoubleClickListener
import com.intellij.ui.TitledSeparator
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.table.JBTable
import com.intellij.util.ui.JBFont
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.protocol.Capabilities
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.DatabaseStats
import com.manishdevan.flutterdb.protocol.EntitySummary
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.service.InspectorService
import java.awt.BorderLayout
import java.awt.Component
import java.awt.FlowLayout
import java.awt.event.MouseEvent
import javax.swing.Icon
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.JProgressBar
import javax.swing.JTable
import javax.swing.table.AbstractTableModel
import javax.swing.table.TableCellRenderer

/** Database statistics: size, entity/index counts and largest entities. */
class StatisticsPanel(
    service: InspectorService,
    db: DatabaseDescriptor,
    private val navigator: InspectorNavigator,
) : InspectorTab {
    override val key: String = keyFor(db.id)
    override val title: String = "Statistics — ${db.name}"
    override val icon: Icon = AllIcons.Actions.ListChanges
    override var database: DatabaseDescriptor = db
        private set

    private val service = service
    private val tasks = UiTasks(service.scope, this)
    private val tiles = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(12), JBUI.scale(4)))
    private val heading = TitledSeparator("Largest entities")
    private val model = EntityModel()
    private val table = JBTable(model)
    private val status = StatusLine()
    private val banner = ConnectionBanner()
    override val component: JComponent = JPanel(BorderLayout())

    init {
        table.setShowGrid(false)
        table.columnModel.getColumn(2).cellRenderer = ShareRenderer()
        table.columnModel.getColumn(0).preferredWidth = JBUI.scale(220)
        table.toolTipText = "Double-click to open"
        object : DoubleClickListener() {
            override fun onDoubleClick(event: MouseEvent): Boolean {
                val row = table.rowAtPoint(event.point).takeIf { it >= 0 } ?: return false
                val entity = model.entities[row]
                navigator.openEntity(database, entity.name, entity.kind)
                return true
            }
        }.installOn(table)
        val top = JPanel(BorderLayout()).apply {
            add(toolbar("FlutterDbStatsToolbar", component, action("Refresh", AllIcons.Actions.Refresh) { refresh() }).component, BorderLayout.WEST)
            add(banner, BorderLayout.SOUTH)
        }
        val body = JPanel(BorderLayout()).apply {
            border = JBUI.Borders.empty(8, 10)
            add(JPanel(BorderLayout()).apply {
                add(tiles, BorderLayout.NORTH)
                add(heading, BorderLayout.SOUTH)
            }, BorderLayout.NORTH)
            add(JBScrollPane(table), BorderLayout.CENTER)
            add(status, BorderLayout.SOUTH)
        }
        component.add(top, BorderLayout.NORTH)
        component.add(body, BorderLayout.CENTER)
        banner.update(service.snapshot)
        refresh()
    }

    override fun refresh() {
        status.loading("Loading…")
        tasks.launch({ service.client.stats(database.id) }, onError = { status.error(errorText(it)) }) { show(it) }
    }

    private fun show(stats: DatabaseStats) {
        val model = database.dataModel
        val entityLabel = when (model) {
            "relational" -> "Tables"
            "keyValue" -> "Boxes"
            else -> "Collections"
        }
        val recordLabel = when (model) {
            "relational" -> "Rows"
            "keyValue" -> "Entries"
            else -> "Objects"
        }
        tiles.removeAll()
        stats.sizeBytes?.let { tiles.add(tile("Size", Values.formatBytes(it))) }
        tiles.add(tile(entityLabel, Values.formatCount(stats.entityCount)))
        if (database.can(Capabilities.INDEXES)) tiles.add(tile("Indexes", Values.formatCount(stats.indexCount)))
        tiles.add(tile(recordLabel, Values.formatCount(stats.totalRows)))
        tiles.revalidate()
        tiles.repaint()
        heading.text = "Largest ${entityLabel.lowercase()}"
        this.model.update(stats.entities.sortedByDescending { it.rowCount ?: 0 }, entityLabel.dropLast(1), recordLabel)
        table.columnModel.getColumn(2).cellRenderer = ShareRenderer()
        table.columnModel.getColumn(0).preferredWidth = JBUI.scale(220)
        status.info("Double-click a row to open it")
    }

    private fun tile(label: String, value: String): JComponent = JPanel(BorderLayout()).apply {
        border = JBUI.Borders.compound(
            JBUI.Borders.customLine(JBUI.CurrentTheme.ToolWindow.borderColor()),
            JBUI.Borders.empty(6, 12),
        )
        add(JBLabel(value).apply { font = JBFont.h2().asBold() }, BorderLayout.CENTER)
        add(JBLabel(label).apply { foreground = UIUtil.getContextHelpForeground() }, BorderLayout.SOUTH)
    }

    override fun connectionChanged(snapshot: ConnectionSnapshot) {
        banner.update(snapshot)
        if (snapshot.state == ConnectionState.CONNECTED && model.entities.isEmpty()) refresh()
    }

    override fun databaseUpdated(db: DatabaseDescriptor) {
        database = db
    }

    override fun dispose() = Unit

    private class EntityModel : AbstractTableModel() {
        var entities: List<EntitySummary> = emptyList()
            private set
        private var headers = listOf("Table", "Rows", "Share")
        private var max = 1L

        fun update(entities: List<EntitySummary>, entityLabel: String, recordLabel: String) {
            this.entities = entities
            max = maxOf(1L, entities.maxOfOrNull { it.rowCount ?: 0 } ?: 1L)
            val changed = headers[0] != entityLabel || headers[1] != recordLabel
            headers = listOf(entityLabel, recordLabel, "Share")
            if (changed) fireTableStructureChanged() else fireTableDataChanged()
        }

        override fun getRowCount() = entities.size
        override fun getColumnCount() = 3
        override fun getColumnName(column: Int) = headers[column]

        override fun getValueAt(rowIndex: Int, columnIndex: Int): Any {
            val e = entities[rowIndex]
            return when (columnIndex) {
                0 -> if (e.kind == "view") "${e.name} (view)" else e.name
                1 -> e.rowCount?.let { Values.formatCount(it) } ?: "—"
                else -> (((e.rowCount ?: 0) * 100) / max).toInt()
            }
        }
    }

    private class ShareRenderer : TableCellRenderer {
        private val bar = JProgressBar(0, 100)

        override fun getTableCellRendererComponent(table: JTable, value: Any?, isSelected: Boolean, hasFocus: Boolean, row: Int, column: Int): Component {
            bar.value = value as? Int ?: 0
            return bar
        }
    }

    companion object {
        fun keyFor(databaseId: String) = "stats:$databaseId"
    }
}
