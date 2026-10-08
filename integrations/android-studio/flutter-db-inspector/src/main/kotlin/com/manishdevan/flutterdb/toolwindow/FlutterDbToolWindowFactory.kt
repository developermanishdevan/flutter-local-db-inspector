package com.manishdevan.flutterdb.toolwindow

import com.intellij.openapi.Disposable
import com.intellij.openapi.project.DumbAware
import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.ToolWindow
import com.intellij.openapi.wm.ToolWindowFactory
import com.intellij.ui.content.ContentFactory
import com.manishdevan.flutterdb.FlutterDbPlugin
import com.manishdevan.flutterdb.service.InspectorSettings
import com.manishdevan.flutterdb.ui.web.WebInspectorPanel
import javax.swing.JComponent

/**
 * Creates the "Flutter DB" tool window: the shared web UI when JCEF is
 * available and the "Use the web UI" setting is on, the Swing UI otherwise.
 */
class FlutterDbToolWindowFactory : ToolWindowFactory, DumbAware {
    override fun createToolWindowContent(project: Project, toolWindow: ToolWindow) {
        populate(project, toolWindow)
    }

    companion object {
        fun useWebUi(): Boolean = InspectorSettings.getInstance().state.useWebUi && WebInspectorPanel.isSupported()

        /** Replaces the tool window content after the UI setting changed (no-op before it is first shown). */
        fun rebuild(project: Project) {
            val toolWindow = FlutterDbPlugin.toolWindow(project) ?: return
            if (toolWindow.contentManagerIfCreated?.contentCount.let { it == null || it == 0 }) return
            toolWindow.contentManager.removeAllContents(true)
            populate(project, toolWindow)
        }

        private fun populate(project: Project, toolWindow: ToolWindow) {
            // Each panel registers itself with the tool window's disposable; the
            // content disposes it earlier when it is replaced.
            val panel: JComponent = if (useWebUi()) {
                WebInspectorPanel(project, toolWindow.disposable)
            } else {
                InspectorToolWindowPanel(project, toolWindow.disposable)
            }
            val content = ContentFactory.getInstance().createContent(panel, "", false).apply {
                isCloseable = false
                setDisposer(panel as Disposable)
            }
            toolWindow.contentManager.addContent(content)
        }
    }
}
