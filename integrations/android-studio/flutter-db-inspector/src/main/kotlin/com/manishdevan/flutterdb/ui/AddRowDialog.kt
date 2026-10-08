package com.manishdevan.flutterdb.ui

import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.openapi.util.ThrowableComputable
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTextArea
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import com.manishdevan.flutterdb.protocol.ColumnInfo
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.protocol.WireValue
import java.awt.GridBagConstraints
import java.awt.GridBagLayout
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.text.JTextComponent

/**
 * Form to add (or duplicate) a record. Generated columns are skipped;
 * auto-assigned keys and columns with defaults may be left empty. The insert
 * runs when OK is pressed; errors keep the dialog open.
 */
class AddRowDialog(
    private val project: Project,
    title: String,
    columns: List<ColumnInfo>,
    private val initial: Map<String, WireValue> = emptyMap(),
    private val submit: suspend (Map<String, WireValue>) -> Unit,
) : DialogWrapper(project, true) {
    private class Field(val column: ColumnInfo, val input: JTextComponent, val isNull: JBCheckBox)

    private val fields = columns.filter { !it.generated }.map { column ->
        val value = initial[column.name]
        val multiline = column.valueType == "json" || column.valueType == "unknown"
        val input: JTextComponent = if (multiline) {
            JBTextArea(3, 30).apply { font = monospaceFont() }
        } else {
            JBTextField(30).apply {
                emptyText.text = when {
                    column.autoIncrement -> "auto"
                    column.defaultValue != null -> "default: ${column.defaultValue}"
                    else -> ""
                }
            }
        }
        input.text = value?.let(Values::editText) ?: ""
        val isNull = JBCheckBox("NULL").apply {
            isSelected = value == WireValue.Null && !column.autoIncrement
            isEnabled = column.nullable
            toolTipText = if (column.nullable) "Store NULL" else "Not nullable"
        }
        input.isEnabled = !isNull.isSelected
        isNull.addActionListener { input.isEnabled = !isNull.isSelected }
        Field(column, input, isNull)
    }

    init {
        this.title = title
        setOKButtonText("Insert")
        init()
    }

    override fun createCenterPanel(): JComponent {
        val panel = JPanel(GridBagLayout())
        val c = GridBagConstraints().apply {
            insets = JBUI.insets(3)
            anchor = GridBagConstraints.NORTHWEST
        }
        fields.forEachIndexed { row, field ->
            val column = field.column
            c.gridy = row
            c.gridx = 0
            c.weightx = 0.0
            c.fill = GridBagConstraints.NONE
            val info = listOfNotNull(
                column.declaredType.ifBlank { column.valueType },
                "required".takeIf { !column.nullable },
                "key".takeIf { column.isPrimaryKey },
            ).joinToString(" · ")
            panel.add(JPanel(java.awt.BorderLayout()).apply {
                add(JBLabel(column.name), java.awt.BorderLayout.NORTH)
                add(JBLabel(info).apply {
                    foreground = UIUtil.getContextHelpForeground()
                    font = JBUI.Fonts.smallFont()
                }, java.awt.BorderLayout.SOUTH)
            }, c)
            c.gridx = 1
            c.weightx = 1.0
            c.fill = GridBagConstraints.HORIZONTAL
            panel.add(if (field.input is JBTextArea) JBScrollPane(field.input) else field.input, c)
            c.gridx = 2
            c.weightx = 0.0
            c.fill = GridBagConstraints.NONE
            panel.add(field.isNull, c)
        }
        return JBScrollPane(panel).apply {
            border = JBUI.Borders.empty()
            preferredSize = JBUI.size(520, minOf(80 + fields.size * 44, 520))
        }
    }

    override fun getPreferredFocusedComponent(): JComponent? =
        fields.firstOrNull { it.input.isEnabled && !it.column.autoIncrement }?.input

    /** Values to insert, following the VS Code row form rules. */
    fun values(): Map<String, WireValue> {
        val values = linkedMapOf<String, WireValue>()
        for (field in fields) {
            val column = field.column
            if (field.isNull.isSelected) {
                values[column.name] = WireValue.Null
                continue
            }
            val text = field.input.text
            if (text.isEmpty() && (column.autoIncrement || column.defaultValue != null)) continue
            values[column.name] = Values.parseInput(text, column.valueType)
        }
        return values
    }

    override fun doOKAction() {
        val values = values()
        val error = try {
            ProgressManager.getInstance().runProcessWithProgressSynchronously(
                ThrowableComputable<Unit, Exception> { runWithIndicator(ProgressManager.getInstance().progressIndicator) { submit(values) } },
                "Inserting…",
                true,
                project,
            )
            null
        } catch (e: Exception) {
            errorText(e)
        }
        if (error != null) setErrorText(error) else super.doOKAction()
    }
}
