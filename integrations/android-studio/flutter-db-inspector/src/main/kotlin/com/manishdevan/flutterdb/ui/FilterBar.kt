package com.manishdevan.flutterdb.ui

import com.intellij.icons.AllIcons
import com.intellij.openapi.ui.ComboBox
import com.intellij.ui.InplaceButton
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import com.manishdevan.flutterdb.protocol.FilterOperator
import com.manishdevan.flutterdb.protocol.ResultColumn
import com.manishdevan.flutterdb.protocol.RowFilter
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.protocol.WireValue
import java.awt.FlowLayout
import javax.swing.BoxLayout
import javax.swing.JButton
import javax.swing.JPanel

/**
 * Filter row builder: `Where <column> <operator> <value>`, `and …`.
 * Values are parsed by column type except for text operators.
 */
class FilterBar(private val onApply: (List<RowFilter>) -> Unit) : JPanel() {
    private class Draft(var column: String, var operator: FilterOperator, var text: String)

    private val drafts = mutableListOf<Draft>()
    private var columns: List<ResultColumn> = emptyList()

    init {
        layout = BoxLayout(this, BoxLayout.Y_AXIS)
        border = JBUI.Borders.compound(
            JBUI.Borders.customLineBottom(JBUI.CurrentTheme.ToolWindow.borderColor()),
            JBUI.Borders.empty(4, 6),
        )
        isVisible = false
    }

    /** Opens the bar with the [current] filters (or one empty condition). */
    fun open(columns: List<ResultColumn>, current: List<RowFilter>) {
        this.columns = columns
        drafts.clear()
        if (current.isEmpty()) {
            drafts += newDraft()
        } else {
            current.forEach { f ->
                drafts += Draft(f.column, f.operator, f.value?.let { (it as? WireValue.Str)?.value ?: Values.editText(it) } ?: "")
            }
        }
        isVisible = true
        render()
    }

    fun close() {
        isVisible = false
    }

    private fun newDraft() = Draft(columns.firstOrNull()?.name ?: "", FilterOperator.CONTAINS, "")

    private fun render() {
        removeAll()
        drafts.forEachIndexed { index, draft ->
            val row = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(4), JBUI.scale(1)))
            row.add(JBLabel(if (index == 0) "Where" else "and").apply {
                foreground = UIUtil.getContextHelpForeground()
                preferredSize = JBUI.size(44, preferredSize.height)
            })
            val column = ComboBox(columns.map { it.name }.toTypedArray()).apply {
                selectedItem = draft.column
                addActionListener { draft.column = selectedItem as? String ?: draft.column }
            }
            val operator = ComboBox(FilterOperator.entries.toTypedArray()).apply { selectedItem = draft.operator }
            val value = JBTextField(draft.text, 18).apply {
                emptyText.text = "value"
                isVisible = !draft.operator.unary
                addActionListener { apply() }
                document.addDocumentListener(object : com.intellij.ui.DocumentAdapter() {
                    override fun textChanged(e: javax.swing.event.DocumentEvent) {
                        draft.text = text
                    }
                })
            }
            operator.addActionListener {
                draft.operator = operator.selectedItem as? FilterOperator ?: draft.operator
                value.isVisible = !draft.operator.unary
                row.revalidate()
            }
            row.add(column)
            row.add(operator)
            row.add(value)
            row.add(InplaceButton("Remove condition", AllIcons.Actions.Close) {
                drafts.removeAt(index)
                render()
            })
            add(row)
        }
        val buttons = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(4), JBUI.scale(2))).apply {
            add(JButton("Add Condition", AllIcons.General.Add).apply {
                addActionListener {
                    drafts += newDraft()
                    render()
                }
            })
            add(JButton("Apply").apply { addActionListener { apply() } })
            add(JButton("Clear Filters").apply {
                addActionListener {
                    drafts.clear()
                    apply()
                    close()
                }
            })
        }
        add(buttons)
        revalidate()
        repaint()
    }

    private fun apply() {
        onApply(buildFilters(drafts.map { Triple(it.column, it.operator, it.text) }, columns))
    }

    companion object {
        /** Turns drafts into protocol filters (a port of `applyFilters` in the VS Code table view). */
        fun buildFilters(drafts: List<Triple<String, FilterOperator, String>>, columns: List<ResultColumn>): List<RowFilter> =
            drafts.filter { it.first.isNotEmpty() }.map { (column, operator, text) ->
                when {
                    operator.unary -> RowFilter(column, operator)
                    operator.textual -> RowFilter(column, operator, WireValue.Str(text))
                    else -> {
                        val type = columns.firstOrNull { it.name == column }?.valueType ?: "text"
                        RowFilter(column, operator, Values.parseInput(text, type))
                    }
                }
            }
    }
}
