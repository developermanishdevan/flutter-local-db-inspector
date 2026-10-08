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
)

class QueryStoreState {
    @XCollection(style = XCollection.Style.v2)
    var history: MutableList<HistoryEntry> = mutableListOf()

    @XCollection(style = XCollection.Style.v2)
    var saved: MutableList<SavedQuery> = mutableListOf()

    /** Last SQL console text per database id. */
    @XMap
    var drafts: MutableMap<String, String> = mutableMapOf()
}

/**
 * Query history and saved queries, stored by the IDE in the project's
 * workspace file — never inside the app's database. A port of `queryStore.ts`.
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

    val saved: List<SavedQuery> @Synchronized get() = state.saved.toList()

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

    fun save(name: String, sql: String, databaseType: String? = null, now: Long = System.currentTimeMillis()): SavedQuery {
        val query = SavedQuery(newId(), name, sql.trim(), databaseType, now)
        synchronized(this) {
            state.saved = (state.saved + query).sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }).toMutableList()
        }
        changed()
        return query
    }

    fun deleteSaved(id: String) {
        synchronized(this) { state.saved.removeAll { it.id == id } }
        changed()
    }

    private fun newId(): String = UUID.randomUUID().toString().substring(0, 13)
}
