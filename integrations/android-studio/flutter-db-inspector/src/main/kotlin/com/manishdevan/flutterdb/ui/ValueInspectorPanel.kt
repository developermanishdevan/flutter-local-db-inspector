package com.manishdevan.flutterdb.ui

import com.intellij.icons.AllIcons
import com.intellij.openapi.ui.Messages
import com.intellij.ui.InplaceButton
import com.intellij.ui.SimpleColoredComponent
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTextArea
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.UIUtil
import com.manishdevan.flutterdb.protocol.Json
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.protocol.WireValue
import com.manishdevan.flutterdb.service.FullValue
import java.awt.BorderLayout
import java.awt.FlowLayout
import javax.swing.ButtonGroup
import javax.swing.JButton
import javax.swing.JPanel
import javax.swing.JToggleButton

/** What the value inspector shows and what it may do. */
class ValueOptions(
    val column: String,
    val valueType: String,
    val value: WireValue,
    val editable: Boolean,
    val nullable: Boolean,
    /** Fetches the complete value (truncated text / blob) up to `maxBytes`. */
    val loadFull: (suspend (maxBytes: Long) -> FullValue)? = null,
    val saveToFile: (() -> Unit)? = null,
    /** Persists a new value; resolves on the EDT. */
    val save: ((WireValue) -> Unit)? = null,
)

/**
 * Side panel showing one value in full: JSON pretty/raw, large text loaded on
 * demand, BLOB hex preview and save to file, and an editor for writable cells.
 * A port of the VS Code `ValuePanel`.
 */
class ValueInspectorPanel(private val tasks: UiTasks, private val onClose: () -> Unit) : JPanel(BorderLayout()) {
    private var options: ValueOptions? = null
    private var fullText: String? = null
    private var pretty = true
    private var editing = false

    private val title = SimpleColoredComponent()
    private val body = JPanel(BorderLayout())

    init {
        border = JBUI.Borders.customLineLeft(JBUI.CurrentTheme.ToolWindow.borderColor())
        val header = JPanel(BorderLayout()).apply {
            border = JBUI.Borders.empty(4, 8)
            add(title, BorderLayout.CENTER)
            add(InplaceButton("Close", AllIcons.Actions.Close) { hideValue() }, BorderLayout.EAST)
        }
        add(header, BorderLayout.NORTH)
        add(body, BorderLayout.CENTER)
    }

    val isOpen: Boolean get() = options != null

    fun showValue(options: ValueOptions) {
        this.options = options
        fullText = null
        editing = false
        render()
    }

    fun hideValue() {
        options = null
        onClose()
    }

    private fun currentText(o: ValueOptions): String? {
        fullText?.let { return it }
        return when (val v = o.value) {
            is WireValue.Text -> v.preview
            is WireValue.Blob, WireValue.Masked -> null
            else -> Values.editText(v)
        }
    }

    private fun parsedJson(text: String?): com.google.gson.JsonElement? {
        val trimmed = text?.trim() ?: return null
        if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return null
        return Json.parseOrNull(trimmed)
    }

    private fun render() {
        val o = options ?: return
        title.clear()
        title.append(o.column, SimpleTextAttributes.REGULAR_BOLD_ATTRIBUTES)
        title.append("  ${o.valueType}", SimpleTextAttributes.GRAYED_ATTRIBUTES)
        body.removeAll()
        when {
            o.value is WireValue.Masked -> body.add(notice(AllIcons.Nodes.Padlock, "This column is marked sensitive by the app. Its value never leaves the device."), BorderLayout.NORTH)
            o.value is WireValue.Blob -> renderBlob(o, o.value)
            else -> renderText(o)
        }
        body.revalidate()
        body.repaint()
    }

    private fun renderText(o: ValueOptions) {
        val text = currentText(o)
        val json = parsedJson(text)
        val shown = when {
            o.value == WireValue.Null && fullText == null -> ""
            json != null && pretty -> Json.prettyPrint(json)
            else -> text ?: Values.displayCell(o.value).text
        }
        val area = JBTextArea(shown).apply {
            font = monospaceFont()
            isEditable = editing
            lineWrap = json == null
            wrapStyleWord = true
            margin = JBUI.insets(6)
            if (o.value == WireValue.Null && !editing) emptyText.text = "NULL"
        }
        area.caretPosition = 0

        val tools = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(4), 0))
        if (json != null && !editing) {
            val group = ButtonGroup()
            for ((label, isPretty) in listOf("Pretty" to true, "Raw" to false)) {
                val button = JToggleButton(label, pretty == isPretty)
                button.addActionListener {
                    pretty = isPretty
                    render()
                }
                group.add(button)
                tools.add(button)
            }
        }
        tools.add(JButton("Copy", AllIcons.Actions.Copy).apply {
            addActionListener { copyToClipboard(if (json != null && pretty) Json.prettyPrint(json) else text ?: "") }
        })
        val canEdit = o.editable && o.save != null && (!Values.isPartial(o.value) || fullText != null)
        if (canEdit && !editing) {
            tools.add(JButton("Edit", AllIcons.Actions.Edit).apply {
                addActionListener {
                    editing = true
                    render()
                }
            })
        }

        val north = JPanel(BorderLayout()).apply {
            border = JBUI.Borders.empty(0, 4, 4, 4)
            add(tools, BorderLayout.NORTH)
        }
        if (Values.isPartial(o.value) && fullText == null) {
            val size = (o.value as? WireValue.Text)?.size ?: 0
            val row = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(4), 0)).apply {
                add(JBLabel("Showing a preview of ${Values.formatBytes(size)}.", AllIcons.General.Information, JBLabel.LEFT))
                o.loadFull?.let { load ->
                    add(JButton("Load Full Value").apply { addActionListener { loadFullText(o, load) } })
                }
            }
            north.add(row, BorderLayout.SOUTH)
        }
        body.add(north, BorderLayout.NORTH)
        body.add(JBScrollPane(area), BorderLayout.CENTER)

        if (editing) {
            val status = JBLabel().apply { foreground = UIUtil.getContextHelpForeground() }
            val save = o.save!!
            val actions = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(4), JBUI.scale(4))).apply {
                add(JButton("Save").apply {
                    addActionListener {
                        status.text = "Saving…"
                        save(Values.parseInput(area.text, o.valueType))
                    }
                })
                if (o.nullable) add(JButton("Set NULL").apply { addActionListener { save(WireValue.Null) } })
                add(JButton("Cancel").apply {
                    addActionListener {
                        editing = false
                        render()
                    }
                })
                add(status)
            }
            body.add(actions, BorderLayout.SOUTH)
            area.requestFocusInWindow()
        }
    }

    private fun loadFullText(o: ValueOptions, load: suspend (Long) -> FullValue) {
        tasks.launch({ load(FULL_TEXT_LIMIT) }, onError = { e ->
            Messages.showErrorDialog(this, errorText(e), "Load Value")
        }) { full ->
            if (options !== o) return@launch
            fullText = full.text
            render()
            if (!full.complete) {
                body.add(notice(AllIcons.General.Warning, "Only the first ${Values.formatBytes(FULL_TEXT_LIMIT)} were loaded."), BorderLayout.SOUTH)
                body.revalidate()
            }
        }
    }

    private fun renderBlob(o: ValueOptions, blob: WireValue.Blob) {
        val hex = JBTextArea(Values.hexDump(Values.decodeBase64(blob.preview))).apply {
            font = monospaceFont()
            isEditable = false
            margin = JBUI.insets(6)
        }
        val tools = JPanel(FlowLayout(FlowLayout.LEFT, JBUI.scale(4), 0)).apply {
            add(JBLabel("Binary value, ${Values.formatBytes(blob.size)}", AllIcons.FileTypes.Any_type, JBLabel.LEFT))
            o.loadFull?.let { load ->
                add(JButton("Preview ${Values.formatBytes(minOf(blob.size, BLOB_PREVIEW_BYTES))}").apply {
                    addActionListener {
                        tasks.launch({ load(BLOB_PREVIEW_BYTES) }, onError = { e -> hex.text = errorText(e) }) { full ->
                            hex.text = Values.hexDump(full.bytes.copyOf(minOf(full.bytes.size, BLOB_PREVIEW_BYTES.toInt())))
                            hex.caretPosition = 0
                        }
                    }
                })
            }
            o.saveToFile?.let { saveToFile ->
                add(JButton("Save to File…", AllIcons.Actions.MenuSaveall).apply { addActionListener { saveToFile() } })
            }
        }
        body.add(tools, BorderLayout.NORTH)
        body.add(JBScrollPane(hex), BorderLayout.CENTER)
    }

    private fun notice(icon: javax.swing.Icon, text: String) = JBLabel("<html>$text</html>", icon, JBLabel.LEFT).apply {
        border = JBUI.Borders.empty(8)
    }

    /** Called after a save succeeded: leaves edit mode with the new value. */
    fun saved(value: WireValue) {
        val o = options ?: return
        options = ValueOptions(o.column, o.valueType, value, o.editable, o.nullable, o.loadFull, o.saveToFile, o.save)
        fullText = null
        editing = false
        render()
    }

    companion object {
        const val FULL_TEXT_LIMIT = 10L * 1024 * 1024
        const val BLOB_PREVIEW_BYTES = 64L * 1024
    }
}
