package com.manishdevan.flutterdb.service

import com.intellij.execution.process.ProcessHandler
import com.intellij.openapi.Disposable
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.logger
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Condition
import com.intellij.openapi.util.Disposer
import com.manishdevan.flutterdb.connection.ConnectionManager
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.connection.ConnectionState
import com.manishdevan.flutterdb.connection.ConnectionTarget
import com.manishdevan.flutterdb.connection.UriConnectionTarget
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.SchemaOverview
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/** Databases of the connected app with their cached `schema.list`. */
data class DatabasesModel(
    val databases: List<DatabaseDescriptor> = emptyList(),
    val overviews: Map<String, SchemaOverview> = emptyMap(),
    /** Per-database `schema.list` failures. */
    val errors: Map<String, String> = emptyMap(),
    /** `database.list` failure. */
    val loadError: String? = null,
) {
    fun database(id: String): DatabaseDescriptor? = databases.firstOrNull { it.id == id }

    companion object {
        val EMPTY = DatabasesModel()
    }
}

/** UI-facing events. Always delivered on the EDT. */
interface InspectorListener {
    fun connectionChanged(snapshot: ConnectionSnapshot) {}

    /**
     * Databases or their schema overviews were reloaded. [reloadViews] is true
     * after (re)connecting, an app event or a manual refresh — open views
     * reload; false after the plugin itself changed data (only counts change).
     */
    fun databasesChanged(model: DatabasesModel, reloadViews: Boolean) {}
}

/** An app announced in a run console. */
data class DiscoveredApp(val handler: ProcessHandler, val uri: String, val label: String, val at: Long)

/**
 * Project-level owner of the connection, the typed client and the query
 * history. All network work runs on background coroutines of [scope];
 * listeners are notified on the EDT.
 */
@Service(Service.Level.PROJECT)
class InspectorService(private val project: Project, val scope: CoroutineScope) : Disposable {
    val manager = ConnectionManager(scope, InspectorSettings.getInstance().state.connectionOptions()) { LOG.info(it) }
    val client = InspectorClient { method, params -> manager.request(method, params) }
    val exporter = Exporter(client)
    val queries: QueryStore get() = project.getService(QueryStore::class.java)

    @Volatile
    var model: DatabasesModel = DatabasesModel.EMPTY
        private set

    private val listeners = CopyOnWriteArrayList<InspectorListener>()
    private val discovered = CopyOnWriteArrayList<DiscoveredApp>()
    private val reloadSeq = AtomicInteger()
    private var reloadJob: Job? = null

    init {
        manager.addStateListener { snapshot ->
            if (snapshot.state == ConnectionState.DISCONNECTED || snapshot.state == ConnectionState.ERROR ||
                (snapshot.state == ConnectionState.CONNECTING && snapshot.isolateId == null)
            ) {
                if (model != DatabasesModel.EMPTY) {
                    reloadSeq.incrementAndGet()
                    model = DatabasesModel.EMPTY
                    onEdt { listeners.forEach { it.databasesChanged(DatabasesModel.EMPTY, reloadViews = false) } }
                }
            }
            onEdt { listeners.forEach { it.connectionChanged(snapshot) } }
        }
        manager.addDatabasesListener { reloadDatabases(reloadViews = true) }
    }

    val snapshot: ConnectionSnapshot get() = manager.snapshot

    val isConnected: Boolean get() = manager.isConnected

    /** Adds [listener] until [parent] is disposed. */
    fun addListener(listener: InspectorListener, parent: Disposable) {
        listeners += listener
        Disposer.register(parent) { listeners -= listener }
    }

    fun connect(target: ConnectionTarget) {
        scope.launch { manager.connect(target) }
    }

    /** Connects to a pasted URI. Throws [IllegalArgumentException] if [input] has no VM service URI. */
    fun connectUri(input: String, label: String? = null) {
        connect(UriConnectionTarget(input, label))
    }

    fun disconnect() = manager.disconnectAsync()

    /** Reloads databases and asks open views to reload. */
    fun refresh() = reloadDatabases(reloadViews = true)

    /** Reloads schema overviews (row counts) after the plugin changed data. */
    fun dataChanged() = reloadDatabases(reloadViews = false)

    private fun reloadDatabases(reloadViews: Boolean) {
        val seq = reloadSeq.incrementAndGet()
        reloadJob?.cancel()
        reloadJob = scope.launch(Dispatchers.IO) {
            val next = if (!manager.isConnected) {
                DatabasesModel.EMPTY
            } else {
                try {
                    val databases = client.listDatabases()
                    val overviews = mutableMapOf<String, SchemaOverview>()
                    val errors = mutableMapOf<String, String>()
                    for (db in databases) {
                        try {
                            overviews[db.id] = client.schema(db.id)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            errors[db.id] = e.message ?: e.javaClass.simpleName
                        }
                    }
                    DatabasesModel(databases, overviews, errors)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    DatabasesModel(loadError = e.message ?: e.javaClass.simpleName)
                }
            }
            if (seq != reloadSeq.get()) return@launch
            model = next
            onEdt { if (seq == reloadSeq.get()) listeners.forEach { it.databasesChanged(next, reloadViews) } }
        }
    }

    // Run-console discovery --------------------------------------------------

    /** Apps announced in run consoles, newest first. */
    val discoveredApps: List<DiscoveredApp> get() = discovered.toList()

    fun onVmServiceDiscovered(handler: ProcessHandler, uri: String, label: String) {
        val app = DiscoveredApp(handler, uri, label, System.currentTimeMillis())
        discovered.removeIf { it.handler == handler || it.uri == uri }
        discovered.add(0, app)
        LOG.info("VM service discovered in '$label': $uri")
        if (InspectorSettings.getInstance().state.autoConnect && manager.currentTargetId != uri) {
            connect(UriConnectionTarget(uri, label))
        }
    }

    fun onProcessTerminated(handler: ProcessHandler) {
        val gone = discovered.filter { it.handler == handler }
        discovered.removeAll(gone.toSet())
        if (gone.any { it.uri == manager.currentTargetId }) disconnect()
    }

    /** Connects to the newest discovered app, if any. Returns false when there is none. */
    fun connectToLatest(): Boolean {
        val latest = discovered.firstOrNull() ?: return false
        connect(UriConnectionTarget(latest.uri, latest.label))
        return true
    }

    fun applySettings() {
        manager.options = InspectorSettings.getInstance().state.connectionOptions()
    }

    private fun onEdt(action: () -> Unit) {
        ApplicationManager.getApplication().invokeLater(action, ModalityState.any(), Condition<Any?> { project.isDisposed })
    }

    override fun dispose() {
        manager.dispose()
        listeners.clear()
        discovered.clear()
    }

    companion object {
        private val LOG = logger<InspectorService>()

        fun getInstance(project: Project): InspectorService = project.getService(InspectorService::class.java)
    }
}
