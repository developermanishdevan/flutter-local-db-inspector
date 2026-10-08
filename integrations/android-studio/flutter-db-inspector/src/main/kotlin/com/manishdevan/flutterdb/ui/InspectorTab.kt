package com.manishdevan.flutterdb.ui

import com.intellij.openapi.Disposable
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import javax.swing.Icon
import javax.swing.JComponent

enum class EntityTab { DATA, SCHEMA }

/** Opens views; implemented by the tool window. */
interface InspectorNavigator {
    fun openEntity(db: DatabaseDescriptor, name: String, kind: String? = null, tab: EntityTab = EntityTab.DATA)

    fun openSql(db: DatabaseDescriptor, sql: String? = null, run: Boolean = false)

    fun openStatistics(db: DatabaseDescriptor)
}

/** A closeable view in the tool window (entity, SQL console, statistics). */
interface InspectorTab : Disposable {
    /** Identity: `table:<db>:<name>`, `sql:<db>`, `stats:<db>`. */
    val key: String
    val title: String
    val icon: Icon?
    val component: JComponent
    val database: DatabaseDescriptor

    /** Reloads from the app (after reconnecting, a refresh or an app event). */
    fun refresh()

    fun connectionChanged(snapshot: ConnectionSnapshot)

    /** The database descriptor changed (capabilities, read-only flag). */
    fun databaseUpdated(db: DatabaseDescriptor)
}
