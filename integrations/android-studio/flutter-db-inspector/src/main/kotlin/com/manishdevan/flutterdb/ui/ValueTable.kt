package com.manishdevan.flutterdb.ui

import com.intellij.icons.AllIcons
import com.intellij.ui.ColoredTableCellRenderer
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.components.JBTextField
import com.intellij.ui.table.JBTable
import com.intellij.util.ui.JBUI
import com.manishdevan.flutterdb.protocol.CellKind
import com.manishdevan.flutterdb.protocol.ResultColumn
import com.manishdevan.flutterdb.protocol.RowRecord
import com.manishdevan.flutterdb.protocol.RowSort
import com.manishdevan.flutterdb.protocol.SortDirection
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.protocol.WireValue
import java.awt.Component
import javax.swing.DefaultCellEditor
import javax.swing.JLabel
import javax.swing.JTable
import javax.swing.SwingConstants
import javax.swing.table.AbstractTableModel
import javax.swing.table.TableCellRenderer

/** Column metadata used for headers. */
data class GridColumn(
    val name: String,
    val valueType: String,
    val declaredType: String? = null,
    val primaryKey: Boolean = false,
    val masked: Boolean = false,
)

/** Rows of [WireValue]s; editing is delegated to the owning panel. */
class RowsTableModel : AbstractTableModel() {
    var columns: List<GridColumn> = emptyList()
        private set
    var rows: List<RowRecord> = emptyList()
        private set

    var canEdit: (row: Int, col: Int) -> Boolean = { _, _ -> false }
    var onEdit: (row: Int, col: Int, text: String) -> Unit = { _, _, _ -> }

    fun setData(columns: List<GridColumn>, rows: List<RowRecord>) {
        val structureChanged = columns != this.columns
        this.columns = columns
        this.rows = rows
        if (structureChanged) fireTableStructureChanged() else fireTableDataChanged()
    }

    fun value(row: Int, col: Int): WireValue? = rows.getOrNull(row)?.values?.getOrNull(col)

    override fun getRowCount(): Int = rows.size

    override fun getColumnCount(): Int = columns.size

    override fun getColumnName(column: Int): String = columns[column].name

    override fun getColumnClass(columnIndex: Int): Class<*> = WireValue::class.java

    override fun getValueAt(rowIndex: Int, columnIndex: Int): Any = value(rowIndex, columnIndex) ?: WireValue.Null

    override fun isCellEditable(rowIndex: Int, columnIndex: Int): Boolean = canEdit(rowIndex, columnIndex)

    override fun setValueAt(aValue: Any?, rowIndex: Int, columnIndex: Int) {
        if (aValue is String) onEdit(rowIndex, columnIndex, aValue)
    }

    companion object {
        fun fromResult(columns: List<ResultColumn>): List<GridColumn> =
            columns.map { GridColumn(it.name, it.valueType, it.declaredType) }
    }
}

/**
 * Renders protocol values with theme colors: NULL italic grey, masked
 * bullets, BLOB sizes, truncated previews with an ellipsis, compact JSON and
 * exact big integers.
 */
class WireValueRenderer : ColoredTableCellRenderer() {
    override fun customizeCellRenderer(table: JTable, value: Any?, selected: Boolean, hasFocus: Boolean, row: Int, column: Int) {
        val wire = value as? WireValue ?: WireValue.Null
        val display = Values.displayCell(wire)
        val text = display.text.replace("\r\n", "⏎").replace('\n', '⏎').replace('\r', '⏎').replace('\t', ' ')
        val attributes = when (display.kind) {
            CellKind.NULL -> SimpleTextAttributes.GRAYED_ITALIC_ATTRIBUTES
            CellKind.MASKED, CellKind.BLOB, CellKind.UNKNOWN -> SimpleTextAttributes.GRAYED_ATTRIBUTES
            CellKind.PARTIAL -> SimpleTextAttributes.REGULAR_ITALIC_ATTRIBUTES
            else -> SimpleTextAttributes.REGULAR_ATTRIBUTES
        }
        setTextAlign(if (display.kind == CellKind.NUMBER) SwingConstants.RIGHT else SwingConstants.LEFT)
        icon = when (display.kind) {
            CellKind.MASKED -> AllIcons.Nodes.Padlock
            else -> null
        }
        append(text, attributes)
        toolTipText = display.tooltip
    }
}

/** Inline editor: shows [Values.editText] and returns the edited text. */
class WireValueCellEditor : DefaultCellEditor(JBTextField()) {
    init {
        clickCountToStart = 2
    }

    override fun getTableCellEditorComponent(table: JTable, value: Any?, isSelected: Boolean, row: Int, column: Int): Component {
        val component = super.getTableCellEditorComponent(table, value, isSelected, row, column) as JBTextField
        component.text = Values.editText(value as? WireValue ?: WireValue.Null)
        component.font = table.font
        return component
    }

    override fun getCellEditorValue(): Any = (component as JBTextField).text
}

/** Header renderer adding sort arrows, key and lock icons, and type tooltips. */
class GridHeaderRenderer(
    private val delegate: TableCellRenderer,
    private val model: RowsTableModel,
    private val sort: () -> List<RowSort>,
) : TableCellRenderer {
    override fun getTableCellRendererComponent(table: JTable, value: Any?, isSelected: Boolean, hasFocus: Boolean, row: Int, column: Int): Component {
        val component = delegate.getTableCellRendererComponent(table, value, isSelected, hasFocus, row, column)
        val label = component as? JLabel ?: return component
        val meta = model.columns.getOrNull(table.convertColumnIndexToModel(column)) ?: return component
        val direction = sort().firstOrNull { it.column == meta.name }?.direction
        label.text = meta.name + when (direction) {
            SortDirection.ASC -> " ▲"
            SortDirection.DESC -> " ▼"
            null -> ""
        }
        label.icon = when {
            meta.primaryKey -> AllIcons.Nodes.DataColumn
            meta.masked -> AllIcons.Nodes.Padlock
            else -> null
        }
        label.horizontalAlignment = SwingConstants.LEFT
        label.toolTipText = listOfNotNull(
            meta.name,
            meta.declaredType?.takeIf { it.isNotBlank() },
            meta.valueType,
            "primary key".takeIf { meta.primaryKey },
            "masked by the app".takeIf { meta.masked },
        ).joinToString(" · ")
        return label
    }
}

/** A read/write grid of protocol values. */
class ValueTable(val rowsModel: RowsTableModel) : JBTable(rowsModel) {
    private val userWidths = mutableMapOf<String, Int>()

    init {
        setDefaultRenderer(WireValue::class.java, WireValueRenderer())
        setDefaultEditor(WireValue::class.java, WireValueCellEditor())
        autoResizeMode = AUTO_RESIZE_OFF
        tableHeader.reorderingAllowed = false
        setShowGrid(true)
        cellSelectionEnabled = true
        setSelectionMode(javax.swing.ListSelectionModel.SINGLE_SELECTION)
        putClientProperty("terminateEditOnFocusLost", true)
        emptyText.text = "No rows"
    }

    /** Remembers widths the user set, then sizes the new columns. */
    fun applyData(columns: List<GridColumn>, rows: List<RowRecord>) {
        for (i in 0 until columnModel.columnCount) {
            val name = rowsModel.columns.getOrNull(convertColumnIndexToModel(i))?.name ?: continue
            userWidths[name] = columnModel.getColumn(i).width
        }
        val structureChanged = columns != rowsModel.columns
        rowsModel.setData(columns, rows)
        if (structureChanged) sizeColumns()
    }

    private fun sizeColumns() {
        val metrics = getFontMetrics(font)
        val headerMetrics = tableHeader.getFontMetrics(tableHeader.font)
        for (i in 0 until columnModel.columnCount) {
            val meta = rowsModel.columns[convertColumnIndexToModel(i)]
            val remembered = userWidths[meta.name]
            val width = remembered ?: run {
                var w = headerMetrics.stringWidth("${meta.name} ▲") + JBUI.scale(36)
                for (r in 0 until minOf(rowCount, 30)) {
                    val text = Values.displayCell(rowsModel.value(r, i) ?: WireValue.Null).text.take(60)
                    w = maxOf(w, metrics.stringWidth(text) + JBUI.scale(16))
                }
                w.coerceIn(JBUI.scale(60), JBUI.scale(320))
            }
            columnModel.getColumn(i).preferredWidth = width
            columnModel.getColumn(i).width = width
        }
    }
}
