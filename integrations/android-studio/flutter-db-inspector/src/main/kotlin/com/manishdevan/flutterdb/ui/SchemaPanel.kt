package com.manishdevan.flutterdb.ui

import com.intellij.icons.AllIcons
import com.intellij.ui.DoubleClickListener
import com.intellij.ui.TitledSeparator
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTextArea
import com.intellij.ui.components.panels.VerticalLayout
import com.intellij.ui.table.JBTable
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.TableSchemaResult
import java.awt.BorderLayout
import java.awt.FlowLayout
import java.awt.event.MouseEvent
import javax.swing.JButton
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.table.DefaultTableModel

/** Columns, keys, foreign keys, indexes, triggers and the DDL of one entity. */
class SchemaPanel(private val onOpenTable: (String) -> Unit) : JPanel(BorderLayout()) {
    private val content = JPanel(VerticalLayout(JBUI.scale(6))).apply { border = JBUI.Borders.empty(8, 10) }

    init {
        add(JBScrollPane(content).apply { border = JBUI.Borders.empty() }, BorderLayout.CENTER)
        showMessage("Loading…")
    }

    fun showMessage(text: String) {
        content.removeAll()
        content.add(JBLabel(text).apply { foreground = UIUtil.getContextHelpForeground() })
        content.revalidate()
        content.repaint()
    }

    fun showSchema(db: DatabaseDescriptor, result: TableSchemaResult) {
        val schema = result.schema
        content.removeAll()

        val columns = readOnlyTable(listOf("Column", "Type", "Value type", "PK", "Nullable", "Default", "Notes"))
        for (c in schema.columns) {
            val notes = listOfNotNull(
                "auto".takeIf { c.autoIncrement },
                "generated".takeIf { c.generated },
                "masked".takeIf { c.name in result.sensitiveColumns },
            ).joinToString(", ")
            columns.model().addRow(
                arrayOf(
                    c.name,
                    c.declaredType,
                    c.valueType,
                    if (c.isPrimaryKey) c.primaryKeyPosition.toString() else "",
                    if (c.nullable) "Yes" else "No",
                    c.defaultValue ?: "",
                    notes,
                ),
            )
        }
        val fieldsWord = if (db.dataModel == "keyValue") "fields" else "columns"
        content.add(TitledSeparator("${schema.columns.size} $fieldsWord"))
        content.add(wrap(columns))
        val rowKey = when (schema.rowKey) {
            "rowid" -> "Rows are addressed by rowid."
            "primaryKey" -> "Rows are addressed by the primary key."
            "key" -> "Records are addressed by their key."
            else -> "Records cannot be addressed individually (read-only)."
        }
        content.add(JBLabel(rowKey, AllIcons.General.Information, JBLabel.LEFT).apply { foreground = UIUtil.getContextHelpForeground() })

        if (schema.foreignKeys.isNotEmpty()) {
            val fks = readOnlyTable(listOf("Columns", "References", "On update", "On delete"))
            for (f in schema.foreignKeys) {
                fks.model().addRow(arrayOf(f.columns.joinToString(", "), "${f.referencedTable}(${f.referencedColumns.joinToString(", ")})", f.onUpdate, f.onDelete))
            }
            fks.toolTipText = "Double-click to open the referenced table"
            object : DoubleClickListener() {
                override fun onDoubleClick(event: MouseEvent): Boolean {
                    val row = fks.rowAtPoint(event.point).takeIf { it >= 0 } ?: return false
                    onOpenTable(schema.foreignKeys[row].referencedTable)
                    return true
                }
            }.installOn(fks)
            content.add(TitledSeparator("Foreign keys"))
            content.add(wrap(fks))
        }

        if (schema.indexes.isNotEmpty()) {
            val indexes = readOnlyTable(listOf("Index", "Columns", "Unique", "Origin"))
            for (i in schema.indexes) {
                val origin = when (i.origin) {
                    "pk" -> "primary key"
                    "u" -> "UNIQUE constraint"
                    "c" -> "CREATE INDEX"
                    else -> i.origin ?: ""
                }
                indexes.model().addRow(arrayOf(i.name, i.columns.joinToString(", "), if (i.unique) "✓" else "", origin))
            }
            content.add(TitledSeparator("Indexes"))
            content.add(wrap(indexes))
        }

        if (schema.triggers.isNotEmpty()) {
            content.add(TitledSeparator("Triggers"))
            for (t in schema.triggers) {
                content.add(JBLabel(t.name, AllIcons.Actions.Lightning, JBLabel.LEFT))
                content.add(code(t.sql ?: ""))
            }
        }

        val sql = schema.sql
        if (!sql.isNullOrBlank()) {
            content.add(TitledSeparator("Definition"))
            content.add(JPanel(FlowLayout(FlowLayout.LEFT, 0, 0)).apply {
                add(JButton("Copy", AllIcons.Actions.Copy).apply { addActionListener { copyToClipboard(sql) } })
            })
            content.add(code(sql))
        }
        content.revalidate()
        content.repaint()
    }

    private fun readOnlyTable(headers: List<String>): JBTable {
        val model = object : DefaultTableModel(headers.toTypedArray(), 0) {
            override fun isCellEditable(row: Int, column: Int) = false
        }
        return JBTable(model).apply {
            setShowGrid(true)
            tableHeader.reorderingAllowed = false
        }
    }

    private fun JBTable.model(): DefaultTableModel = model as DefaultTableModel

    private fun wrap(table: JBTable): JComponent = JPanel(BorderLayout()).apply {
        border = JBUI.Borders.customLine(JBUI.CurrentTheme.ToolWindow.borderColor())
        add(table.tableHeader, BorderLayout.NORTH)
        add(table, BorderLayout.CENTER)
    }

    private fun code(text: String): JComponent = JBTextArea(text).apply {
        font = monospaceFont()
        isEditable = false
        margin = JBUI.insets(6)
        border = JBUI.Borders.customLine(JBUI.CurrentTheme.ToolWindow.borderColor())
    }
}
