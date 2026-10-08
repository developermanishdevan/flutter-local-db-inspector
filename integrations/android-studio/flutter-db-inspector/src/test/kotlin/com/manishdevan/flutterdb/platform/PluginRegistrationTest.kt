package com.manishdevan.flutterdb.platform

import com.intellij.openapi.actionSystem.ActionGroup
import com.intellij.openapi.actionSystem.ActionManager
import com.intellij.openapi.wm.ToolWindowEP
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.manishdevan.flutterdb.FlutterDbPlugin
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.service.InspectorService
import com.manishdevan.flutterdb.service.QueryStore
import com.manishdevan.flutterdb.toolwindow.FlutterDbToolWindowFactory

/** Light platform test: plugin.xml registrations load in a real (headless) IDE. */
class PluginRegistrationTest : BasePlatformTestCase() {
    fun testToolWindowIsRegistered() {
        val ep = ToolWindowEP.EP_NAME.extensionList.firstOrNull { it.id == FlutterDbPlugin.TOOL_WINDOW_ID }
        assertNotNull("tool window '${FlutterDbPlugin.TOOL_WINDOW_ID}' is not registered", ep)
        assertEquals(FlutterDbToolWindowFactory::class.java.name, ep!!.factoryClass)
    }

    fun testActionsAreRegistered() {
        val manager = ActionManager.getInstance()
        for (id in listOf(
            "FlutterDbInspector.OpenInspector",
            "FlutterDbInspector.Connect",
            "FlutterDbInspector.Refresh",
            "FlutterDbInspector.Disconnect",
            "FlutterDbInspector.SqlConsole",
        )) {
            assertNotNull("action $id", manager.getAction(id))
        }
        assertTrue(manager.getAction("FlutterDbInspector.ToolsMenu") is ActionGroup)
        assertTrue(manager.getAction("FlutterDbInspector.Toolbar") is ActionGroup)
    }

    fun testProjectServicesStartDisconnected() {
        val service = InspectorService.getInstance(project)
        assertEquals(ConnectionState.DISCONNECTED, service.snapshot.state)
        assertTrue(service.model.databases.isEmpty())
        assertNotNull(project.getService(QueryStore::class.java))
    }
}
