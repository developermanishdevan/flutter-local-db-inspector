package com.manishdevan.flutterdb.service

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.openapi.options.BoundConfigurable
import com.intellij.openapi.project.ProjectManager
import com.intellij.openapi.ui.DialogPanel
import com.intellij.ui.dsl.builder.bindIntText
import com.intellij.ui.dsl.builder.bindItem
import com.intellij.ui.dsl.builder.bindSelected
import com.intellij.ui.dsl.builder.panel
import com.intellij.ui.dsl.builder.toNullableProperty
import com.manishdevan.flutterdb.connection.ConnectionOptions
import com.manishdevan.flutterdb.toolwindow.FlutterDbToolWindowFactory

class InspectorSettingsState {
    /** Connect to Flutter/Dart run sessions automatically. */
    var autoConnect: Boolean = true

    /** Rows per page (25, 50 or 100). */
    var defaultPageSize: Int = 50

    /** How long to wait for the app to answer. */
    var requestTimeoutMs: Int = 30_000

    /** Queries kept in history (0 disables history). */
    var historyLimit: Int = 100

    /** Ask before saving an edited cell. */
    var confirmCellEdits: Boolean = false

    /** Show the shared web UI (JCEF) instead of the Swing UI when JCEF is available. */
    var useWebUi: Boolean = true

    fun connectionOptions(): ConnectionOptions =
        ConnectionOptions(requestTimeoutMs = requestTimeoutMs.coerceAtLeast(1_000).toLong())
}

/** Application-wide settings (Settings ▸ Tools ▸ Flutter DB Inspector). */
@Service(Service.Level.APP)
@State(name = "FlutterDbInspectorSettings", storages = [Storage("flutterDbInspector.xml")])
class InspectorSettings : PersistentStateComponent<InspectorSettingsState> {
    private var state = InspectorSettingsState()

    override fun getState(): InspectorSettingsState = state

    override fun loadState(state: InspectorSettingsState) {
        this.state = state
    }

    companion object {
        fun getInstance(): InspectorSettings = ApplicationManager.getApplication().getService(InspectorSettings::class.java)
    }
}

class InspectorConfigurable : BoundConfigurable("Flutter DB Inspector") {
    private val settings get() = InspectorSettings.getInstance().state

    override fun createPanel(): DialogPanel = panel {
        group("Interface") {
            row {
                checkBox("Use the web UI")
                    .bindSelected(settings::useWebUi)
                    .comment("The same UI as VS Code and DevTools, in an embedded browser (JCEF). Turn off for the classic Swing UI.")
            }
        }
        group("Connection") {
            row {
                checkBox("Connect automatically to Flutter and Dart run sessions")
                    .bindSelected(settings::autoConnect)
            }
            row("Request timeout (ms):") {
                intTextField(1_000..600_000).bindIntText(settings::requestTimeoutMs)
            }
        }
        group("Data") {
            row("Rows per page:") {
                comboBox(listOf(25, 50, 100)).bindItem(settings::defaultPageSize.toNullableProperty())
            }
            row {
                checkBox("Ask before saving an edited cell").bindSelected(settings::confirmCellEdits)
            }
        }
        group("SQL Console") {
            row("Queries kept in history:") {
                intTextField(0..10_000).bindIntText(settings::historyLimit)
                    .comment("Stored by the IDE, never in your app. 0 disables history.")
            }
        }
    }

    override fun apply() {
        val wasWebUi = settings.useWebUi
        super.apply()
        for (project in ProjectManager.getInstance().openProjects) {
            project.getServiceIfCreated(InspectorService::class.java)?.applySettings()
            if (settings.useWebUi != wasWebUi) FlutterDbToolWindowFactory.rebuild(project)
        }
    }
}
