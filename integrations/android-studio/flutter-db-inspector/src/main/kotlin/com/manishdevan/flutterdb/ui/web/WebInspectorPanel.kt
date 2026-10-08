package com.manishdevan.flutterdb.ui.web

import com.google.gson.JsonObject
import com.intellij.ide.ui.LafManagerListener
import com.intellij.notification.NotificationType
import com.intellij.openapi.Disposable
import com.intellij.openapi.actionSystem.ActionGroup
import com.intellij.openapi.actionSystem.ActionManager
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.EDT
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.application.asContextElement
import com.intellij.openapi.diagnostic.logger
import com.intellij.openapi.fileChooser.FileChooserFactory
import com.intellij.openapi.fileChooser.FileSaverDescriptor
import com.intellij.openapi.ide.CopyPasteManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.SimpleToolWindowPanel
import com.intellij.openapi.util.Disposer
import com.intellij.openapi.util.text.StringUtil
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.wm.StatusBar
import com.intellij.ui.JBColor
import com.intellij.ui.jcef.JBCefApp
import com.intellij.ui.jcef.JBCefBrowser
import com.intellij.ui.jcef.JBCefBrowserBase
import com.intellij.ui.jcef.JBCefJSQuery
import com.intellij.util.ui.JBUI
import com.manishdevan.flutterdb.FlutterDbPlugin
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.protocol.Protocol
import com.manishdevan.flutterdb.service.InspectorService
import com.manishdevan.flutterdb.service.InspectorSettings
import com.manishdevan.flutterdb.toolwindow.InspectorToolWindowPanel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.job
import kotlinx.coroutines.withContext
import org.cef.browser.CefBrowser
import org.cef.browser.CefFrame
import org.cef.handler.CefLoadHandlerAdapter
import org.cef.network.CefRequest
import java.awt.datatransfer.StringSelection
import java.nio.file.Files
import java.nio.file.Paths

/**
 * The "Flutter DB" tool window with the shared web UI (`shared/web-ui`, app
 * mode) in a JCEF browser. The page holds the tree, tabs and status; this
 * panel only adds the native toolbar and answers the page's requests
 * through [WebUiBridge]:
 *
 * - The page is served from the plugin jar on [WebUiResources.ORIGIN] by
 *   [WebUiRequestHandler].
 * - UI → host: after each load, `window.fdiHost.postMessage(json)` is
 *   injected; it calls a [JBCefJSQuery]. The page queues messages until
 *   the host exists (`fdi-host-ready`).
 * - Host → UI: `window.postMessage(message, '*')`.
 */
class WebInspectorPanel(
    private val project: Project,
    parent: Disposable,
) : SimpleToolWindowPanel(true, true), Disposable, WebUiHost {
    private val service = InspectorService.getInstance(project)
    private val scope = CoroutineScope(service.scope.coroutineContext + SupervisorJob(service.scope.coroutineContext.job) + Dispatchers.IO)
    private val browser = JBCefBrowser.createBuilder().build()
    private val query: JBCefJSQuery
    private val bridge = WebUiBridge(scope, this, ::post)

    /** Orders `init`/`connection` against state changes; guards [pageReady]. */
    private val lock = Any()
    private var pageReady = false

    /** An `open` requested before the page was ready (the tool window was just created). */
    private var pendingOpen: String? = null

    /** Set on `connected`: the page reloads everything then, so the databases event that follows is redundant. */
    @Volatile
    private var skipDatabasesEvent = false

    init {
        Disposer.register(parent, this)
        Disposer.register(this, browser)
        // Created before the page loads so its JS function exists in the page.
        // Registered after the browser: children are disposed in reverse order.
        query = JBCefJSQuery.create(browser as JBCefBrowserBase)
        Disposer.register(this, query)
        query.addHandler { json ->
            bridge.onMessage(json)
            null
        }
        // Registered last, so disposed first: no coroutine posts to the page while it goes away.
        Disposer.register(this) { scope.cancel() }

        val client = browser.jbCefClient
        client.addRequestHandler(WebUiRequestHandler(::theme), browser.cefBrowser)
        client.addLifeSpanHandler(WebUiRequestHandler.noPopups, browser.cefBrowser)
        client.addLoadHandler(object : CefLoadHandlerAdapter() {
            override fun onLoadStart(browser: CefBrowser, frame: CefFrame, transitionType: CefRequest.TransitionType) {
                if (frame.isMain) synchronized(lock) { pageReady = false }
            }

            override fun onLoadEnd(browser: CefBrowser, frame: CefFrame, httpStatusCode: Int) {
                if (frame.isMain && frame.url.startsWith(WebUiResources.ORIGIN)) {
                    browser.executeJavaScript(bridgeScript(), frame.url, 0)
                }
            }
        }, browser.cefBrowser)

        val group = ActionManager.getInstance().getAction(InspectorToolWindowPanel.TOOLBAR_GROUP) as ActionGroup
        val actionToolbar = ActionManager.getInstance().createActionToolbar("FlutterDbToolWindow", group, true)
        actionToolbar.targetComponent = this
        toolbar = actionToolbar.component.apply {
            border = JBUI.Borders.customLineBottom(JBUI.CurrentTheme.ToolWindow.borderColor())
        }
        setContent(browser.component)

        val manager = service.manager
        val removeStateListener = manager.addStateListener { snapshot ->
            synchronized(lock) {
                if (snapshot.state == ConnectionState.CONNECTED) skipDatabasesEvent = true
                if (pageReady) post(WebUiMessages.connection(snapshot))
            }
        }
        val removeDatabasesListener = manager.addDatabasesListener {
            if (skipDatabasesEvent) {
                skipDatabasesEvent = false
            } else {
                postIfReady(WebUiMessages.event(Protocol.EVENT_DATABASES_CHANGED))
            }
        }
        Disposer.register(this) {
            removeStateListener()
            removeDatabasesListener()
        }
        ApplicationManager.getApplication().messageBus.connect(this)
            .subscribe(LafManagerListener.TOPIC, LafManagerListener { postIfReady(WebUiMessages.theme(theme())) })

        browser.loadURL(WebUiResources.INDEX_URL)
    }

    /** Defines `window.fdiHost` and tells the page's transport to flush its queue. */
    private fun bridgeScript(): String = """
        (function () {
          if (window.fdiHost) return;
          window.fdiHost = { postMessage: function (json) { ${query.inject("json")} } };
          window.dispatchEvent(new Event('fdi-host-ready'));
        })();
    """.trimIndent()

    private fun theme(): String = if (JBColor.isBright()) "light" else "dark"

    /** Posts a host message (JSON text) to the page. Safe from any thread. */
    private fun post(json: String) {
        if (browser.isDisposed) return
        browser.cefBrowser.executeJavaScript("window.postMessage($json, '*');", WebUiResources.INDEX_URL, 0)
    }

    private fun postIfReady(json: String) {
        synchronized(lock) { if (pageReady) post(json) }
    }

    // Native actions -----------------------------------------------------------

    /** Native Refresh: reload the tree and every open view. */
    fun reload() = postIfReady(WebUiMessages.reload())

    /** Opens (or focuses) the SQL console of [databaseId]. */
    fun openSql(databaseId: String) {
        val message = WebUiMessages.openSql(databaseId)
        synchronized(lock) { if (pageReady) post(message) else pendingOpen = message }
    }

    // WebUiHost ----------------------------------------------------------------

    override fun onReady() {
        val settings = InspectorSettings.getInstance().state
        synchronized(lock) {
            post(WebUiMessages.init("android-studio", settings.defaultPageSize, theme(), settings.confirmCellEdits, settings.historyLimit))
            post(WebUiMessages.connection(service.snapshot))
            pendingOpen?.let(::post)
            pendingOpen = null
            pageReady = true
        }
    }

    override suspend fun call(method: String, params: JsonObject): JsonObject = service.manager.request(method, params)

    override suspend fun copy(text: String, label: String?) = onEdt {
        CopyPasteManager.getInstance().setContents(StringSelection(text))
        StatusBar.Info.set(label?.let { "Copied $it" } ?: "Copied", project)
    }

    override suspend fun saveFile(name: String, bytes: ByteArray): Boolean {
        val file = onEdt {
            val extension = name.substringAfterLast('.', "")
            val descriptor = if (extension.isEmpty()) FileSaverDescriptor("Save File", "") else FileSaverDescriptor("Save File", "", extension)
            FileChooserFactory.getInstance().createSaveFileDialog(descriptor, project)
                .save(project.basePath?.let { Paths.get(it) }, name)?.file
        } ?: return false
        Files.write(file.toPath(), bytes)
        LocalFileSystem.getInstance().refreshIoFiles(listOf(file), true, false, null)
        return true
    }

    override fun notify(message: String, level: String?) {
        val type = when (level) {
            "error" -> NotificationType.ERROR
            "warning" -> NotificationType.WARNING
            else -> NotificationType.INFORMATION
        }
        // Notifications render HTML; page text can contain app-controlled names.
        FlutterDbPlugin.notify(project, StringUtil.escapeXmlEntities(message), type)
    }

    override fun logError(message: String) {
        LOG.warn("Web UI: $message")
    }

    private suspend fun <T> onEdt(block: () -> T): T =
        withContext(Dispatchers.EDT + ModalityState.nonModal().asContextElement()) { block() }

    override fun dispose() {
        scope.cancel()
        synchronized(lock) { pageReady = false }
    }

    companion object {
        private val LOG = logger<WebInspectorPanel>()

        /** JCEF is available and the plugin was built with the web UI. */
        fun isSupported(): Boolean = JBCefApp.isSupported() && WebUiResources.isAvailable()
    }
}
