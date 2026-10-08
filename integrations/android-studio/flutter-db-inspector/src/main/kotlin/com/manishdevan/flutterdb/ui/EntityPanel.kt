package com.manishdevan.flutterdb.ui

import com.intellij.icons.AllIcons
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Disposer
import com.intellij.ui.components.JBTabbedPane
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.service.InspectorService
import java.awt.BorderLayout
import javax.swing.Icon
import javax.swing.JComponent
import javax.swing.JPanel

/** Data / Schema tab for one table, view, collection, box or store. */
class EntityPanel(
    project: Project,
    service: InspectorService,
    db: DatabaseDescriptor,
    private val name: String,
    private val kind: String,
    entityReadOnly: Boolean,
    navigator: InspectorNavigator,
    initialTab: EntityTab,
) : InspectorTab {
    override val key: String = keyFor(db.id, name)
    override val title: String = name
    override val icon: Icon = iconFor(kind)
    override var database: DatabaseDescriptor = db
        private set

    private val schemaPanel = SchemaPanel { table -> navigator.openEntity(database, table) }
    private val dataPanel = DataTablePanel(project, service, db, name, kind, entityReadOnly) { result, error ->
        when {
            result != null -> schemaPanel.showSchema(database, result)
            error != null -> schemaPanel.showMessage(errorText(error))
        }
    }
    private val tabs = JBTabbedPane().apply {
        addTab("Data", AllIcons.Nodes.DataTables, dataPanel)
        addTab(if (db.isRelational) "Schema" else "Structure", AllIcons.Nodes.DataSchema, schemaPanel)
    }
    override val component: JComponent = JPanel(BorderLayout()).apply { add(tabs, BorderLayout.CENTER) }

    init {
        Disposer.register(this, dataPanel)
        showTab(initialTab)
    }

    fun showTab(tab: EntityTab) {
        tabs.selectedIndex = if (tab == EntityTab.DATA) 0 else 1
    }

    override fun refresh() = dataPanel.reload(withSchema = true)

    override fun connectionChanged(snapshot: ConnectionSnapshot) = dataPanel.connectionChanged(snapshot)

    override fun databaseUpdated(db: DatabaseDescriptor) {
        database = db
        dataPanel.databaseUpdated(db)
    }

    override fun dispose() = Unit

    companion object {
        fun keyFor(databaseId: String, name: String) = "table:$databaseId:$name"

        fun iconFor(kind: String): Icon = when (kind) {
            "view" -> AllIcons.Actions.Show
            "collection" -> AllIcons.Nodes.Class
            "box" -> AllIcons.Nodes.Package
            "store" -> AllIcons.Nodes.Property
            else -> AllIcons.Nodes.DataTables
        }
    }
}
