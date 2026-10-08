package com.manishdevan.flutterdb.actions

import com.intellij.icons.AllIcons
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.InputValidatorEx
import com.intellij.openapi.ui.Messages
import com.intellij.openapi.ui.popup.JBPopupFactory
import com.manishdevan.flutterdb.FlutterDbIcons
import com.manishdevan.flutterdb.FlutterDbPlugin
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.connection.UriConnectionTarget
import com.manishdevan.flutterdb.connection.VmServiceUri
import com.manishdevan.flutterdb.protocol.Capabilities
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.Labels
import com.manishdevan.flutterdb.service.InspectorService
import com.manishdevan.flutterdb.ui.action

/** Base: project actions that only read service state in `update`. */
abstract class InspectorAction(text: String, description: String, icon: javax.swing.Icon?) : DumbAwareAction(text, description, icon) {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    protected fun service(e: AnActionEvent): InspectorService? = e.project?.let(InspectorService::getInstance)

    override fun update(e: AnActionEvent) {
        val service = service(e)
        e.presentation.isEnabled = service != null && isEnabled(service)
    }

    protected open fun isEnabled(service: InspectorService): Boolean = true
}

/** Tools ▸ Flutter DB Inspector ▸ Open Inspector. */
class OpenInspectorAction : InspectorAction("Open Inspector", "Show the Flutter DB tool window", FlutterDbIcons.ToolWindow) {
    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val service = InspectorService.getInstance(project)
        FlutterDbPlugin.activate(project)
        val state = service.snapshot.state
        if (state == ConnectionState.DISCONNECTED || state == ConnectionState.ERROR) service.connectToLatest()
    }
}

class RefreshAction : InspectorAction("Refresh", "Reload databases and open views", AllIcons.Actions.Refresh) {
    override fun isEnabled(service: InspectorService) = service.isConnected

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        // The service's model drives the actions; the web UI keeps its own and reloads it here.
        InspectorService.getInstance(project).refresh()
        FlutterDbPlugin.webPanel(project)?.reload()
    }
}

class DisconnectAction : InspectorAction("Disconnect", "Disconnect from the app", AllIcons.Actions.Suspend) {
    override fun isEnabled(service: InspectorService) = service.snapshot.state != ConnectionState.DISCONNECTED

    override fun actionPerformed(e: AnActionEvent) {
        service(e)?.disconnect()
    }
}

/** Connect to a discovered run session or a pasted VM service URI. */
class ConnectAction : InspectorAction("Connect to VM Service URI…", "Attach to a running Flutter or Dart app", AllIcons.Actions.Execute) {
    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val service = InspectorService.getInstance(project)
        val apps = service.discoveredApps
        if (apps.isEmpty()) {
            askForUri(project, service)
            return
        }
        val group = DefaultActionGroup()
        for (app in apps) {
            group.add(action("${app.label}  ${VmServiceUri.label(app.uri)}", AllIcons.Actions.StartDebugger) {
                service.connect(UriConnectionTarget(app.uri, app.label))
            })
        }
        group.addSeparator()
        group.add(action("Enter VM Service URI…", AllIcons.General.Web) { askForUri(project, service) })
        JBPopupFactory.getInstance()
            .createActionGroupPopup("Connect Flutter DB Inspector", group, e.dataContext, JBPopupFactory.ActionSelectionAid.SPEEDSEARCH, true)
            .showInBestPositionFor(e.dataContext)
    }

    private fun askForUri(project: Project, service: InspectorService) {
        val validator = object : InputValidatorEx {
            override fun getErrorText(inputString: String): String? = try {
                VmServiceUri.toWebSocketUri(inputString)
                null
            } catch (e: IllegalArgumentException) {
                e.message
            }

            override fun checkInput(inputString: String) = getErrorText(inputString) == null

            override fun canClose(inputString: String) = checkInput(inputString)
        }
        val input = Messages.showInputDialog(
            project,
            "Paste the VM service URI (http://127.0.0.1:PORT/TOKEN=/, ws://…/ws or a DevTools link) from `flutter run` or `dart run --enable-vm-service`:",
            "Connect to VM Service",
            null,
            "",
            validator,
        ) ?: return
        service.connectUri(input)
        FlutterDbPlugin.activate(project)
    }
}

/** Opens a SQL console for the selected (or only) SQL database. */
class OpenSqlConsoleAction : InspectorAction("SQL Console", "Open a SQL console for a database", AllIcons.Debugger.Console) {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun isEnabled(service: InspectorService) =
        service.isConnected && service.model.databases.any { it.can(Capabilities.SQL) }

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val service = InspectorService.getInstance(project)
        val selected = FlutterDbPlugin.panel(project)?.currentDatabase()?.takeIf { it.can(Capabilities.SQL) }
        val candidates = service.model.databases.filter { it.can(Capabilities.SQL) }
        val open = { db: DatabaseDescriptor ->
            FlutterDbPlugin.activate(project, onWeb = { it.openSql(db.id) }) { it.openSql(db) }
        }
        when {
            selected != null -> open(selected)
            candidates.size == 1 -> open(candidates.single())
            candidates.isEmpty() -> Messages.showInfoMessage(project, "No connected database supports SQL.", "SQL Console")
            else -> {
                val group = DefaultActionGroup()
                candidates.forEach { db -> group.add(action("${db.name}  ${Labels.engineLabel(db.type)}", FlutterDbIcons.Database) { open(db) }) }
                JBPopupFactory.getInstance()
                    .createActionGroupPopup("Select Database", group, e.dataContext, JBPopupFactory.ActionSelectionAid.SPEEDSEARCH, true)
                    .showInBestPositionFor(e.dataContext)
            }
        }
    }
}
