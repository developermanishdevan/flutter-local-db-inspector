package com.manishdevan.flutterdb.service

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.util.xmlb.annotations.Attribute
import com.intellij.util.xmlb.annotations.Tag
import com.intellij.util.xmlb.annotations.XCollection
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

/** Saved queries of one app, keyed by its Dart package name. */
data class SavedQueryGroup(val app: String, val queries: List<SavedQuery>)

/** Persisted form of one app's saved queries. */
@Tag("app")
class SavedQueryAppState {
    @Attribute("name")
    var name: String = ""

    @XCollection(style = XCollection.Style.v2)
    var queries: MutableList<SavedQuery> = mutableListOf()
}

class SavedQueryStoreState {
    @XCollection(style = XCollection.Style.v2)
    var apps: MutableList<SavedQueryAppState> = mutableListOf()
}

/**
 * Saved SQL queries, kept per app (its Dart package name, see
 * [com.manishdevan.flutterdb.connection.appPackageOf]) in the IDE's
 * application settings (`flutterDbInspector.xml`), so they survive restarts
 * and are shared by every project window until the user deletes them.
 * Never stored inside the app's database. A port of the saved-query part of
 * `queryStore.ts`; history stays per project in [QueryStore].
 */
@Service(Service.Level.APP)
@State(name = "FlutterDbInspectorSavedQueries", storages = [Storage("flutterDbInspector.xml")])
class SavedQueryStore : PersistentStateComponent<SavedQueryStoreState> {
    private var state = SavedQueryStoreState()
    private val listeners = CopyOnWriteArrayList<() -> Unit>()

    @Synchronized
    override fun getState(): SavedQueryStoreState = state

    @Synchronized
    override fun loadState(state: SavedQueryStoreState) {
        this.state = state
    }

    fun addListener(listener: () -> Unit): () -> Unit {
        listeners += listener
        return { listeners -= listener }
    }

    private fun changed() = listeners.forEach { it() }

    /** Saved queries of [app], sorted by name. */
    @Synchronized
    fun saved(app: String): List<SavedQuery> = group(app)?.queries?.map { it.copy() }.orEmpty()

    /** Every app with saved queries; [current] first, then by name. */
    @Synchronized
    fun savedGroups(current: String? = null): List<SavedQueryGroup> = state.apps
        .filter { it.queries.isNotEmpty() }
        .sortedWith(compareBy<SavedQueryAppState> { it.name != current }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.name })
        .map { SavedQueryGroup(it.name, it.queries.map { q -> q.copy() }) }

    /**
     * Saves [sql] as [name] for [app]. A query with the same name (ignoring
     * case) is replaced, keeping its id, so saving again updates it.
     */
    fun save(app: String, name: String, sql: String, databaseType: String? = null, now: Long = System.currentTimeMillis()): SavedQuery {
        val trimmed = name.trim()
        val query = synchronized(this) {
            val list = group(app)?.queries.orEmpty()
            val existing = list.firstOrNull { it.name.equals(trimmed, ignoreCase = true) }
            val query = existing?.copy(name = trimmed, sql = sql.trim(), databaseType = databaseType ?: existing.databaseType, updatedAt = now)
                ?: SavedQuery(newId(), trimmed, sql.trim(), databaseType, now)
            put(app, list.filter { it.id != query.id } + query)
            query
        }
        changed()
        return query.copy()
    }

    fun deleteSaved(app: String, id: String) {
        synchronized(this) { put(app, group(app)?.queries.orEmpty().filter { it.id != id }) }
        changed()
    }

    /**
     * Moves 1.x saved queries (not tied to an app) to [app]. Queries whose
     * name [app] already uses are dropped.
     */
    fun adoptLegacySaved(app: String, legacy: List<SavedQuery>) {
        if (legacy.isEmpty()) return
        synchronized(this) {
            val merged = group(app)?.queries.orEmpty().toMutableList()
            for (q in legacy) {
                if (merged.none { it.name.equals(q.name, ignoreCase = true) }) merged += q.copy(id = q.id.ifEmpty { newId() })
            }
            put(app, merged)
        }
        changed()
    }

    private fun group(app: String): SavedQueryAppState? = state.apps.firstOrNull { it.name == app }

    /** Replaces the queries of [app] (sorted by name); an empty list drops the app. */
    private fun put(app: String, queries: List<SavedQuery>) {
        state.apps.removeAll { it.name == app }
        if (queries.isEmpty()) return
        state.apps.add(
            SavedQueryAppState().apply {
                name = app
                this.queries = queries.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }).toMutableList()
            },
        )
        state.apps.sortWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
    }

    private fun newId(): String = UUID.randomUUID().toString().substring(0, 13)

    companion object {
        /** Used when the VM does not tell the app's package name. */
        const val UNKNOWN_APP = "(unknown app)"

        fun getInstance(): SavedQueryStore = ApplicationManager.getApplication().getService(SavedQueryStore::class.java)
    }
}
