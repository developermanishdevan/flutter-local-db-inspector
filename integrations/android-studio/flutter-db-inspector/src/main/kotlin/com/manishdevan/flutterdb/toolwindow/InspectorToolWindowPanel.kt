package com.manishdevan.flutterdb.toolwindow

import com.intellij.icons.AllIcons
import com.intellij.openapi.Disposable
import com.intellij.openapi.actionSystem.ActionGroup
import com.intellij.openapi.actionSystem.ActionManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.SimpleToolWindowPanel
import com.intellij.openapi.util.Disposer
import com.intellij.ui.AnimatedIcon
import com.intellij.ui.InplaceButton
import com.intellij.ui.OnePixelSplitter
import com.intellij.ui.SimpleColoredComponent
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBPanelWithEmptyText
import com.intellij.ui.components.JBTabbedPane
import com.intellij.util.ui.JBUI
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.service.DatabasesModel
import com.manishdevan.flutterdb.service.InspectorListener
import com.manishdevan.flutterdb.service.InspectorService
import com.manishdevan.flutterdb.ui.DatabaseTreePanel
import com.manishdevan.flutterdb.ui.EntityPanel
import com.manishdevan.flutterdb.ui.EntityTab
import com.manishdevan.flutterdb.ui.InspectorNavigator
import com.manishdevan.flutterdb.ui.InspectorTab
import com.manishdevan.flutterdb.ui.SqlConsolePanel
import com.manishdevan.flutterdb.ui.StatisticsPanel
import com.manishdevan.flutterdb.ui.TabRefresher
import java.awt.BorderLayout
import java.awt.CardLayout
import java.awt.FlowLayout
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import javax.swing.JPanel
import javax.swing.SwingUtilities

/**
 * The "Flutter DB" tool window: connection status and toolbar, the database
 * tree on the left and closeable views (entities, SQL consoles, statistics)
 * on the right.
 */
class InspectorToolWindowPanel(
    private val project: Project,
    parent: Disposable,
) : SimpleToolWindowPanel(true, true), Disposable, InspectorNavigator, TabRefresher {
    private val service = InspectorService.getInstance(project)
    private val status = SimpleColoredComponent().apply { ipad = JBUI.insets(4, 8) }
    val treePanel: DatabaseTreePanel
    private val tabs = JBTabbedPane()
    private val openTabs = linkedMapOf<String, InspectorTab>()
    private val cards = CardLayout()
    private val right = JPanel(cards)

    init {
        Disposer.register(parent, this)
        treePanel = DatabaseTreePanel(project, service, this, this)

        val group = ActionManager.getInstance().getAction(TOOLBAR_GROUP) as ActionGroup
        val actionToolbar = ActionManager.getInstance().createActionToolbar("FlutterDbToolWindow", group, true)
        actionToolbar.targetComponent = this
        toolbar = JPanel(BorderLayout()).apply {
            add(actionToolbar.component, BorderLayout.WEST)
            add(status, BorderLayout.CENTER)
            border = JBUI.Borders.customLineBottom(JBUI.CurrentTheme.ToolWindow.borderColor())
        }

        val empty = JBPanelWithEmptyText().withEmptyText("Double-click a table, collection or box to open it")
        right.add(empty, EMPTY)
        right.add(tabs, TABS)
        val splitter = OnePixelSplitter(false, "FlutterDb.mainSplitter", 0.25f).apply {
            firstComponent = treePanel
            secondComponent = right
        }
        setContent(splitter)

        service.addListener(object : InspectorListener {
            override fun connectionChanged(snapshot: ConnectionSnapshot) {
                showStatus(snapshot)
                treePanel.update(service.model, snapshot)
                openTabs.values.forEach { it.connectionChanged(snapshot) }
            }

            override fun databasesChanged(model: DatabasesModel, reloadViews: Boolean) {
                treePanel.update(model, service.snapshot)
                for (tab in openTabs.values) {
                    model.database(tab.database.id)?.let(tab::databaseUpdated)
                    if (reloadViews && model.database(tab.database.id) != null) tab.refresh()
                }
            }
        }, this)
        showStatus(service.snapshot)
    }

    private fun showStatus(snapshot: ConnectionSnapshot) {
        status.clear()
        val label = snapshot.targetLabel ?: "app"
        when (snapshot.state) {
            ConnectionState.CONNECTED -> {
                status.icon = AllIcons.RunConfigurations.TestPassed
                status.append("● Connected · $label")
                snapshot.status?.mode?.takeIf { it != "fullAccess" }?.let { status.append("  $it", SimpleTextAttributes.GRAYED_ATTRIBUTES) }
            }
            ConnectionState.CONNECTING -> {
                status.icon = AnimatedIcon.Default.INSTANCE
                status.append(snapshot.message ?: "Connecting…", SimpleTextAttributes.GRAYED_ATTRIBUTES)
            }
            ConnectionState.RECONNECTING -> {
                status.icon = AnimatedIcon.Default.INSTANCE
                status.append(snapshot.message ?: "Reconnecting…", SimpleTextAttributes.GRAYED_ATTRIBUTES)
            }
            ConnectionState.ERROR -> {
                status.icon = AllIcons.General.Error
                status.append(snapshot.message ?: "Connection failed", SimpleTextAttributes.ERROR_ATTRIBUTES)
            }
            ConnectionState.DISCONNECTED -> {
                status.icon = AllIcons.General.BalloonInformation
                status.append(snapshot.message ?: "Not connected", SimpleTextAttributes.GRAYED_ATTRIBUTES)
            }
        }
        status.toolTipText = snapshot.targetId
        status.repaint()
    }

    /** Database of the tree selection or the selected view. */
    fun currentDatabase(): DatabaseDescriptor? =
        treePanel.selectedDatabase ?: (tabs.selectedComponent?.let { c -> openTabs.values.firstOrNull { it.component === c } })?.database

    // InspectorNavigator ------------------------------------------------------

    override fun openEntity(db: DatabaseDescriptor, name: String, kind: String?, tab: EntityTab) {
        val key = EntityPanel.keyFor(db.id, name)
        val existing = openTabs[key] as? EntityPanel
        if (existing != null) {
            existing.showTab(tab)
            select(existing)
            return
        }
        val summary = service.model.overviews[db.id]?.entities?.firstOrNull { it.name == name }
        add(EntityPanel(project, service, db, name, kind ?: summary?.kind ?: "table", summary?.readOnly ?: false, this, tab))
    }

    override fun openSql(db: DatabaseDescriptor, sql: String?, run: Boolean) {
        val existing = openTabs[SqlConsolePanel.keyFor(db.id)] as? SqlConsolePanel
        val panel = existing ?: SqlConsolePanel(project, service, db).also(::add)
        select(panel)
        if (sql != null) panel.setSql(sql, run)
    }

    override fun openStatistics(db: DatabaseDescriptor) {
        val existing = openTabs[StatisticsPanel.keyFor(db.id)]
        if (existing != null) {
            existing.refresh()
            select(existing)
        } else {
            add(StatisticsPanel(service, db, this))
        }
    }

    override fun refreshTab(key: String) {
        openTabs[key]?.refresh()
    }

    // Tabs ---------------------------------------------------------------------

    private fun add(tab: InspectorTab) {
        Disposer.register(this, tab)
        openTabs[tab.key] = tab
        tabs.addTab(tab.title, tab.icon, tab.component)
        val index = tabs.indexOfComponent(tab.component)
        tabs.setTabComponentAt(index, tabHeader(tab))
        tabs.setToolTipTextAt(index, "${tab.title} — ${tab.database.name}")
        cards.show(right, TABS)
        select(tab)
    }

    private fun tabHeader(tab: InspectorTab) = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(4), 0)).apply {
        isOpaque = false
        add(JBLabel(tab.title, tab.icon, JBLabel.LEFT))
        add(InplaceButton("Close", AllIcons.Actions.Close) { close(tab) })
        addMouseListener(object : MouseAdapter() {
            override fun mouseReleased(e: MouseEvent) {
                if (SwingUtilities.isMiddleMouseButton(e)) close(tab) else select(tab)
            }
        })
    }

    private fun select(tab: InspectorTab) {
        tabs.selectedComponent = tab.component
    }

    fun close(tab: InspectorTab) {
        tabs.remove(tab.component)
        openTabs.remove(tab.key)
        Disposer.dispose(tab)
        if (openTabs.isEmpty()) cards.show(right, EMPTY)
    }

    override fun dispose() {
        openTabs.clear()
    }

    companion object {
        const val TOOLBAR_GROUP = "FlutterDbInspector.Toolbar"
        private const val EMPTY = "empty"
        private const val TABS = "tabs"
    }
}
