package com.manishdevan.flutterdb.service

import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.openapi.components.StoragePathMacros
import com.intellij.util.xmlb.annotations.Tag
import com.intellij.util.xmlb.annotations.XCollection
import com.intellij.util.xmlb.annotations.XMap
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

@Tag("entry")
data class HistoryEntry(
    var id: String = "",
    var sql: String = "",
    var databaseId: String = "",
    var databaseName: String = "",
    var at: Long = 0,
    var ok: Boolean = true,
    var elapsedMs: Double? = null,
    var rowCount: Long? = null,
)

@Tag("query")
data class SavedQuery(
    var id: String = "",
    var name: String = "",
    var sql: String = "",
    /** Engine type the query was written for, e.g. `sqlite`. */
    var databaseType: String? = null,
    var createdAt: Long = 0,
    var updatedAt: Long? = null,
)

class QueryStoreState {
    @XCollection(style = XCollection.Style.v2)
    var history: MutableList<HistoryEntry> = mutableListOf()

    /** 1.x saved queries, not tied to an app; moved to [SavedQueryStore] on the first connection. */
    @XCollection(style = XCollection.Style.v2)
    var saved: MutableList<SavedQuery> = mutableListOf()

    /** Last SQL console text per database id. */
    @XMap
    var drafts: MutableMap<String, String> = mutableMapOf()
}

/**
 * Query history and SQL console drafts, stored by the IDE in the project's
 * workspace file — never inside the app's database. A port of `queryStore.ts`.
 * Saved queries live per app in the application-level [SavedQueryStore].
 */
@Service(Service.Level.PROJECT)
@State(name = "FlutterDbInspectorQueries", storages = [Storage(StoragePathMacros.WORKSPACE_FILE)])
class QueryStore : PersistentStateComponent<QueryStoreState> {
    private var state = QueryStoreState()
    private val listeners = CopyOnWriteArrayList<() -> Unit>()

    /** History size limit; 0 disables history. */
    var limit: () -> Int = { InspectorSettings.getInstance().state.historyLimit }

    override fun getState(): QueryStoreState = state

    override fun loadState(state: QueryStoreState) {
        this.state = state
    }

    fun addListener(listener: () -> Unit): () -> Unit {
        listeners += listener
        return { listeners -= listener }
    }

    private fun changed() = listeners.forEach { it() }

    val history: List<HistoryEntry> @Synchronized get() = state.history.toList()

    @Synchronized
    fun draft(databaseId: String): String? = state.drafts[databaseId]

    @Synchronized
    fun setDraft(databaseId: String, sql: String) {
        if (sql.isBlank()) state.drafts.remove(databaseId) else state.drafts[databaseId] = sql
    }

    fun record(
        sql: String,
        databaseId: String,
        databaseName: String,
        ok: Boolean,
        elapsedMs: Double? = null,
        rowCount: Long? = null,
        now: Long = System.currentTimeMillis(),
    ) {
        val max = limit()
        if (max <= 0) return
        synchronized(this) {
            val text = sql.trim()
            // Collapse repeats of the same statement on the same database.
            val rest = state.history.filterNot { it.sql.trim() == text && it.databaseId == databaseId }
            val entry = HistoryEntry(newId(), text, databaseId, databaseName, now, ok, elapsedMs, rowCount)
            state.history = (listOf(entry) + rest).take(max).toMutableList()
        }
        changed()
    }

    fun deleteHistory(id: String) {
        synchronized(this) { state.history.removeAll { it.id == id } }
        changed()
    }

    fun clearHistory() {
        synchronized(this) { state.history.clear() }
        changed()
    }

    /** 1.x saved queries of this project, not tied to an app. */
    val legacySaved: List<SavedQuery> @Synchronized get() = state.saved.toList()

    /** Returns the 1.x saved queries and forgets them (see [SavedQueryStore.adoptLegacySaved]). */
    @Synchronized
    fun takeLegacySaved(): List<SavedQuery> {
        val legacy = state.saved.toList()
        state.saved.clear()
        return legacy
    }

    private fun newId(): String = UUID.randomUUID().toString().substring(0, 13)
}
