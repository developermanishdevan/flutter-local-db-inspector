package com.manishdevan.flutterdb.ui

import com.intellij.icons.AllIcons
import com.intellij.ui.AnimatedIcon
import com.intellij.ui.components.JBLabel
import com.intellij.util.ui.JBUI
import com.manishdevan.flutterdb.connection.ConnectionSnapshot
import com.manishdevan.flutterdb.connection.ConnectionState
import java.awt.BorderLayout
import javax.swing.JPanel

/** Strip shown above a view while the app is not connected. */
class ConnectionBanner : JPanel(BorderLayout()) {
    private val label = JBLabel()

    init {
        isOpaque = true
        border = JBUI.Borders.compound(
            JBUI.Borders.customLineBottom(JBUI.CurrentTheme.Banner.WARNING_BORDER_COLOR),
            JBUI.Borders.empty(4, 8),
        )
        add(label, BorderLayout.CENTER)
        isVisible = false
    }

    fun update(snapshot: ConnectionSnapshot) {
        val state = snapshot.state
        isVisible = state != ConnectionState.CONNECTED
        if (!isVisible) return
        val error = state == ConnectionState.ERROR || state == ConnectionState.DISCONNECTED
        background = if (error) JBUI.CurrentTheme.Banner.ERROR_BACKGROUND else JBUI.CurrentTheme.Banner.INFO_BACKGROUND
        label.icon = when (state) {
            ConnectionState.CONNECTING, ConnectionState.RECONNECTING -> AnimatedIcon.Default.INSTANCE
            ConnectionState.ERROR -> AllIcons.General.Error
            else -> AllIcons.General.Warning
        }
        label.text = snapshot.message ?: when (state) {
            ConnectionState.DISCONNECTED -> "The app is not connected."
            else -> state.name.lowercase()
        }
    }
}
