package com.manishdevan.flutterdb

import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.IconLoader
import com.intellij.openapi.wm.ToolWindow
import com.intellij.openapi.wm.ToolWindowManager
import com.manishdevan.flutterdb.toolwindow.InspectorToolWindowPanel
import com.manishdevan.flutterdb.ui.web.WebInspectorPanel
import javax.swing.Icon

/**
 * Plugin-wide constants and wiring.
 *
 * - `service.InspectorService` (project service) owns the connection, typed
 *   client and query history.
 * - `connection.RunConsoleDiscovery` is registered as a project listener on
 *   `ExecutionManager.EXECUTION_TOPIC` and feeds VM service URIs announced in
 *   run consoles to the service.
 * - `toolwindow.FlutterDbToolWindowFactory` builds the "Flutter DB" tool window.
 */
object FlutterDbPlugin {
    const val TOOL_WINDOW_ID = "Flutter DB"
    const val NOTIFICATION_GROUP = "Flutter DB Inspector"

    fun toolWindow(project: Project): ToolWindow? = ToolWindowManager.getInstance(project).getToolWindow(TOOL_WINDOW_ID)

    /** The tool window's main panel, if the tool window has been created. */
    fun panel(project: Project): InspectorToolWindowPanel? =
        toolWindow(project)?.contentManagerIfCreated?.contents
            ?.firstNotNullOfOrNull { it.component as? InspectorToolWindowPanel }

    /** The tool window's web UI panel, if the tool window has been created and uses the web UI. */
    fun webPanel(project: Project): WebInspectorPanel? =
        toolWindow(project)?.contentManagerIfCreated?.contents
            ?.firstNotNullOfOrNull { it.component as? WebInspectorPanel }

    /** Shows the tool window, then runs [then] with its Swing panel or [onWeb] with its web UI panel. */
    fun activate(project: Project, onWeb: (WebInspectorPanel) -> Unit = {}, then: (InspectorToolWindowPanel) -> Unit = {}) {
        val window = toolWindow(project) ?: return
        window.activate({
            panel(project)?.let(then)
            webPanel(project)?.let(onWeb)
        }, true, true)
    }

    fun notify(project: Project?, content: String, type: NotificationType = NotificationType.INFORMATION) {
        NotificationGroupManager.getInstance().getNotificationGroup(NOTIFICATION_GROUP)
            .createNotification(content, type)
            .notify(project)
    }
}

object FlutterDbIcons {
    @JvmField
    val ToolWindow: Icon = IconLoader.getIcon("/icons/flutterDb.svg", FlutterDbIcons::class.java)

    @JvmField
    val Database: Icon = IconLoader.getIcon("/icons/database.svg", FlutterDbIcons::class.java)
}
