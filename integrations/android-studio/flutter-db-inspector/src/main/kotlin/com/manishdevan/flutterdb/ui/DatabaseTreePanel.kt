package com.manishdevan.flutterdb.ui

import com.intellij.icons.AllIcons
import com.intellij.openapi.Disposable
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.actionSystem.Separator
import com.intellij.openapi.project.DumbAware
import com.intellij.openapi.project.Project
import com.intellij.ui.ColoredTreeCellRenderer
import com.intellij.ui.DoubleClickListener
import com.intellij.ui.PopupHandler
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.TreeSpeedSearch
import com.intellij.ui.DocumentAdapter
import com.intellij.ui.SearchTextField
import javax.swing.event.DocumentEvent
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.treeStructure.Tree
import com.intellij.util.ui.tree.TreeUtil
import com.manishdevan.flutterdb.FlutterDbIcons
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.protocol.Capabilities
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.EntitySummary
import com.manishdevan.flutterdb.protocol.IndexInfo
import com.manishdevan.flutterdb.protocol.Labels
import com.manishdevan.flutterdb.protocol.TriggerInfo
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.service.DatabasesModel
import com.manishdevan.flutterdb.service.InspectorService
import java.awt.BorderLayout
import java.awt.event.KeyAdapter
import java.awt.event.KeyEvent
import java.awt.event.MouseEvent
import javax.swing.JPanel
import javax.swing.JTree
import javax.swing.event.TreeExpansionEvent
import javax.swing.event.TreeExpansionListener
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeModel
import javax.swing.tree.TreePath

/** Tree node payloads. */
sealed interface DbTreeNode {
    /** Stable id used to keep collapsed state across reloads. */
    val id: String

    data object Root : DbTreeNode {
        override val id = "root"
    }

    data class Database(val db: DatabaseDescriptor) : DbTreeNode {
        override val id get() = "db:${db.id}"
    }

    data class Group(val db: DatabaseDescriptor, val label: String, val count: Int) : DbTreeNode {
        override val id get() = "group:${db.id}:$label"
    }

    data class Entity(val db: DatabaseDescriptor, val entity: EntitySummary) : DbTreeNode {
        override val id get() = "entity:${db.id}:${entity.kind}:${entity.name}"
    }

    data class Index(val db: DatabaseDescriptor, val index: IndexInfo) : DbTreeNode {
        override val id get() = "index:${db.id}:${index.name}"
    }

    data class Trigger(val db: DatabaseDescriptor, val trigger: TriggerInfo) : DbTreeNode {
        override val id get() = "trigger:${db.id}:${trigger.name}"
    }

    data class Message(val text: String, val error: Boolean = false) : DbTreeNode {
        override val id get() = "message:$text"
    }
}

/**
 * DATABASES ▸ database (engine, read-only) ▸ groups by entity kind ▸ entities
 * with row counts. Double-click opens an entity; the context menu follows
 * each database's capabilities.
 */
class DatabaseTreePanel(
    private val project: Project,
    private val service: InspectorService,
    private val navigator: InspectorNavigator,
    parent: Disposable,
) : JPanel(BorderLayout()) {
    private val rootNode = DefaultMutableTreeNode(DbTreeNode.Root)
    private val treeModel = DefaultTreeModel(rootNode)
    val tree = Tree(treeModel)
    private val tasks = UiTasks(service.scope, parent)
    private val collapsed = mutableSetOf<String>()
    private var rebuilding = false
    private var lastModel: DatabasesModel = service.model
    private var lastSnapshot: ConnectionSnapshot = service.snapshot

    /** Table-name filter; empty shows everything. */
    var filter: String = ""
        set(value) {
            val next = value.trim()
            if (next == field) return
            field = next
            update(lastModel, lastSnapshot)
        }

    private val filterField = SearchTextField(false).apply {
        textEditor.emptyText.text = "Filter tables…"
        textEditor.accessibleContext.accessibleName = "Filter tables"
        addDocumentListener(object : DocumentAdapter() {
            override fun textChanged(e: DocumentEvent) {
                filter = text
            }
        })
    }

    init {
        tree.isRootVisible = true
        tree.showsRootHandles = true
        tree.cellRenderer = Renderer()
        TreeSpeedSearch.installOn(tree, false) { path -> label(path.lastPathComponent) }
        tree.addTreeExpansionListener(object : TreeExpansionListener {
            override fun treeExpanded(event: TreeExpansionEvent) {
                if (!rebuilding) collapsed -= payload(event.path.lastPathComponent).id
            }

            override fun treeCollapsed(event: TreeExpansionEvent) {
                if (!rebuilding) collapsed += payload(event.path.lastPathComponent).id
            }
        })
        object : DoubleClickListener() {
            override fun onDoubleClick(event: MouseEvent): Boolean = openSelected()
        }.installOn(tree)
        tree.addKeyListener(object : KeyAdapter() {
            override fun keyPressed(e: KeyEvent) {
                if (e.keyCode == KeyEvent.VK_ENTER && openSelected()) e.consume()
            }
        })
        PopupHandler.installPopupMenu(tree, ContextMenu(), "FlutterDbTreePopup")
        add(filterField, BorderLayout.NORTH)
        add(JBScrollPane(tree), BorderLayout.CENTER)
        update(service.model, service.snapshot)
    }

    private fun payload(node: Any?): DbTreeNode =
        (node as? DefaultMutableTreeNode)?.userObject as? DbTreeNode ?: DbTreeNode.Root

    private fun label(node: Any?): String = when (val p = payload(node)) {
        DbTreeNode.Root -> "DATABASES"
        is DbTreeNode.Database -> p.db.name
        is DbTreeNode.Group -> p.label
        is DbTreeNode.Entity -> p.entity.name
        is DbTreeNode.Index -> p.index.name
        is DbTreeNode.Trigger -> p.trigger.name
        is DbTreeNode.Message -> p.text
    }

    val selected: DbTreeNode? get() = tree.selectionPath?.lastPathComponent?.let(::payload)

    /** Database of the selected node, if any. */
    val selectedDatabase: DatabaseDescriptor?
        get() = when (val node = selected) {
            is DbTreeNode.Database -> node.db
            is DbTreeNode.Group -> node.db
            is DbTreeNode.Entity -> node.db
            is DbTreeNode.Index -> node.db
            is DbTreeNode.Trigger -> node.db
            else -> null
        }

    private fun openSelected(): Boolean {
        val node = selected as? DbTreeNode.Entity ?: return false
        navigator.openEntity(node.db, node.entity.name, node.entity.kind, EntityTab.DATA)
        return true
    }

    /** Rebuilds the tree, keeping selection and collapsed nodes. */
    fun update(model: DatabasesModel, snapshot: ConnectionSnapshot) {
        lastModel = model
        lastSnapshot = snapshot
        val selectedId = selected?.id
        rebuilding = true
        try {
            rootNode.removeAllChildren()
            val message = when {
                snapshot.state == ConnectionState.DISCONNECTED -> DbTreeNode.Message("No app connected — run a Flutter app in debug mode or use Connect…")
                snapshot.state == ConnectionState.ERROR -> DbTreeNode.Message(snapshot.message ?: "Connection failed", error = true)
                snapshot.state == ConnectionState.CONNECTING -> DbTreeNode.Message(snapshot.message ?: "Connecting…")
                model.loadError != null -> DbTreeNode.Message(model.loadError, error = true)
                model.databases.isEmpty() && snapshot.state == ConnectionState.CONNECTED ->
                    DbTreeNode.Message("No databases registered — call DbInspector.registerDatabase()")
                model.databases.isEmpty() -> DbTreeNode.Message(snapshot.message ?: "Waiting for the app…")
                else -> null
            }
            if (message != null) rootNode.add(DefaultMutableTreeNode(message))
            for (db in model.databases) rootNode.add(databaseNode(db, model))
            treeModel.reload()
            TreeUtil.treeNodeTraverser(rootNode).forEach { node ->
                val treeNode = node as DefaultMutableTreeNode
                // While filtering every match is shown; the user's own
                // collapsed state comes back when the filter is cleared.
                if (treeNode.childCount > 0 && (filter.isNotEmpty() || payload(treeNode).id !in collapsed)) {
                    tree.expandPath(TreePath(treeNode.path))
                }
            }
            if (selectedId != null) {
                TreeUtil.treeNodeTraverser(rootNode).find { payload(it).id == selectedId }?.let {
                    tree.selectionPath = TreePath((it as DefaultMutableTreeNode).path)
                }
            }
        } finally {
            rebuilding = false
        }
    }

    private fun databaseNode(db: DatabaseDescriptor, model: DatabasesModel): DefaultMutableTreeNode {
        val node = DefaultMutableTreeNode(DbTreeNode.Database(db))
        model.errors[db.id]?.let {
            node.add(DefaultMutableTreeNode(DbTreeNode.Message(it, error = true)))
            return node
        }
        val overview = model.overviews[db.id] ?: return node
        if (overview.entities.isEmpty()) {
            node.add(DefaultMutableTreeNode(DbTreeNode.Message("Empty")))
            return node
        }
        fun matches(name: String) = filter.isEmpty() || name.contains(filter, ignoreCase = true)
        overview.entities.filter { matches(it.name) }.groupBy { it.kind }.entries
            .sortedBy { Labels.entityKindRank(it.key) }
            .forEach { (kind, entities) ->
                val group = DefaultMutableTreeNode(DbTreeNode.Group(db, Labels.entityGroupLabel(kind), entities.size))
                entities.forEach { group.add(DefaultMutableTreeNode(DbTreeNode.Entity(db, it))) }
                node.add(group)
            }
        if (db.can(Capabilities.INDEXES)) {
            val indexes = overview.indexes.filter { it.origin != "pk" && matches(it.name) }
            if (indexes.isNotEmpty()) {
                val group = DefaultMutableTreeNode(DbTreeNode.Group(db, "Indexes", indexes.size))
                indexes.forEach { group.add(DefaultMutableTreeNode(DbTreeNode.Index(db, it))) }
                node.add(group)
            }
        }
        val triggers = overview.triggers.filter { matches(it.name) }
        if (triggers.isNotEmpty()) {
            val group = DefaultMutableTreeNode(DbTreeNode.Group(db, "Triggers", triggers.size))
            triggers.forEach { group.add(DefaultMutableTreeNode(DbTreeNode.Trigger(db, it))) }
            node.add(group)
        }
        if (node.childCount == 0 && filter.isNotEmpty()) {
            node.add(DefaultMutableTreeNode(DbTreeNode.Message("No names match \"$filter\"")))
        }
        return node
    }

    private class Renderer : ColoredTreeCellRenderer() {
        override fun customizeCellRenderer(tree: JTree, value: Any?, selected: Boolean, expanded: Boolean, leaf: Boolean, row: Int, hasFocus: Boolean) {
            val grey = SimpleTextAttributes.GRAYED_ATTRIBUTES
            when (val p = (value as? DefaultMutableTreeNode)?.userObject as? DbTreeNode ?: return) {
                DbTreeNode.Root -> append("DATABASES", SimpleTextAttributes.GRAYED_BOLD_ATTRIBUTES)
                is DbTreeNode.Database -> {
                    icon = FlutterDbIcons.Database
                    append(p.db.name)
                    append("  ${Labels.engineLabel(p.db.type)}", grey)
                    if (p.db.readOnly) append("  read-only", SimpleTextAttributes.GRAYED_ITALIC_ATTRIBUTES)
                    toolTipText = "<html><b>${p.db.name}</b> (${p.db.id})<br>Engine: ${Labels.engineLabel(p.db.type)} " +
                        "(${Labels.dataModelLabel(p.db.dataModel)})<br>Access: ${if (p.db.readOnly) "read-only" else "read &amp; write"}" +
                        "<br>Capabilities: ${p.db.capabilities.sorted().joinToString(", ")}</html>"
                }
                is DbTreeNode.Group -> {
                    icon = AllIcons.Nodes.Folder
                    append(p.label)
                    append("  ${p.count}", grey)
                }
                is DbTreeNode.Entity -> {
                    icon = EntityPanel.iconFor(p.entity.kind)
                    append(p.entity.name)
                    p.entity.rowCount?.let { append("  ${Values.formatCount(it)}", grey) }
                    if (p.entity.readOnly) append("  read-only", SimpleTextAttributes.GRAYED_ITALIC_ATTRIBUTES)
                    toolTipText = "${p.entity.kind} ${p.entity.name}" +
                        (p.entity.rowCount?.let { " — ${Values.formatCount(it)} ${Labels.recordNoun(p.entity.kind, true)}" } ?: "")
                }
                is DbTreeNode.Index -> {
                    icon = AllIcons.Nodes.SortBySeverity
                    append(p.index.name)
                    append("  ${p.index.table}(${p.index.columns.joinToString(", ")})${if (p.index.unique) " unique" else ""}", grey)
                    toolTipText = p.index.sql
                }
                is DbTreeNode.Trigger -> {
                    icon = AllIcons.Actions.Lightning
                    append(p.trigger.name)
                    append("  ${p.trigger.table}", grey)
                    toolTipText = p.trigger.sql
                }
                is DbTreeNode.Message -> {
                    icon = if (p.error) AllIcons.General.Error else AllIcons.General.Information
                    append(p.text, if (p.error) SimpleTextAttributes.ERROR_ATTRIBUTES else grey)
                }
            }
        }
    }

    /** Context menu computed from the selected node and its database's capabilities. */
    private inner class ContextMenu : DefaultActionGroup(), DumbAware {
        override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

        override fun getChildren(e: AnActionEvent?): Array<AnAction> {
            val connected = { service.isConnected }
            return when (val node = selected) {
                is DbTreeNode.Entity -> {
                    val db = node.db
                    val entity = node.entity
                    val writable = !db.readOnly && !entity.readOnly && entity.kind != "view"
                    listOfNotNull(
                        action("Open Data", AllIcons.Nodes.DataTables) { navigator.openEntity(db, entity.name, entity.kind, EntityTab.DATA) },
                        action("Open Schema", AllIcons.Nodes.DataSchema) { navigator.openEntity(db, entity.name, entity.kind, EntityTab.SCHEMA) },
                        Separator.getInstance(),
                        action("Export…", AllIcons.ToolbarDecorator.Export, enabled = connected) {
                            EntityOperations.exportEntity(project, service, db, entity.name)
                        }.takeIf { db.can(Capabilities.EXPORT) },
                        action("Clear…", AllIcons.Actions.GC, enabled = connected) {
                            EntityOperations.clear(project, service, db, entity.name, entity.kind, tasks) {
                                navigatorRefresh(db, entity.name)
                            }
                        }.takeIf { writable && db.can(Capabilities.CLEAR) },
                        Separator.getInstance(),
                        action("Copy Name", AllIcons.Actions.Copy) { copyToClipboard(entity.name) },
                    ).toTypedArray()
                }
                is DbTreeNode.Database -> {
                    val db = node.db
                    listOfNotNull(
                        action("SQL Console", AllIcons.Debugger.Console) { navigator.openSql(db) }.takeIf { db.can(Capabilities.SQL) },
                        action("Statistics", AllIcons.Actions.ListChanges) { navigator.openStatistics(db) },
                        action("Export Database…", AllIcons.ToolbarDecorator.Export, enabled = connected) {
                            EntityOperations.exportDatabase(project, service, db)
                        }.takeIf { db.can(Capabilities.EXPORT) },
                        Separator.getInstance(),
                        action("Refresh", AllIcons.Actions.Refresh) { service.refresh() },
                        action("Copy Name", AllIcons.Actions.Copy) { copyToClipboard(db.name) },
                    ).toTypedArray()
                }
                is DbTreeNode.Index -> arrayOf(
                    action("Copy Name", AllIcons.Actions.Copy) { copyToClipboard(node.index.name) },
                    action("Copy SQL") { copyToClipboard(node.index.sql ?: "") }.takeIf { node.index.sql != null } ?: Separator.getInstance(),
                )
                is DbTreeNode.Trigger -> arrayOf(
                    action("Copy Name", AllIcons.Actions.Copy) { copyToClipboard(node.trigger.name) },
                    action("Copy SQL") { copyToClipboard(node.trigger.sql ?: "") }.takeIf { node.trigger.sql != null } ?: Separator.getInstance(),
                )
                else -> emptyArray()
            }
        }
    }

    /** After clearing from the tree, open views of that entity reload. */
    private fun navigatorRefresh(db: DatabaseDescriptor, name: String) {
        (navigator as? TabRefresher)?.refreshTab(EntityPanel.keyFor(db.id, name))
    }
}

/** Lets the tree ask the tool window to reload one open view. */
interface TabRefresher {
    fun refreshTab(key: String)
}
