package com.manishdevan.flutterdb.ui

import com.intellij.openapi.Disposable
import com.intellij.openapi.actionSystem.ActionManager
import com.intellij.openapi.actionSystem.ActionToolbar
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.actionSystem.ToggleAction
import com.intellij.openapi.application.EDT
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.application.asContextElement
import com.intellij.openapi.editor.colors.EditorColorsManager
import com.intellij.openapi.editor.colors.EditorFontType
import com.intellij.openapi.ide.CopyPasteManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.project.DumbAwareAction
import com.intellij.openapi.util.Disposer
import com.intellij.ui.SimpleColoredComponent
import com.intellij.ui.SimpleTextAttributes
import com.intellij.icons.AllIcons
import com.manishdevan.flutterdb.protocol.ErrorCodes
import com.manishdevan.flutterdb.protocol.InspectorException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.awt.Font
import java.awt.datatransfer.StringSelection
import javax.swing.Icon
import javax.swing.JComponent

/**
 * Coroutine helper for panels: protocol work runs on [Dispatchers.IO],
 * results are delivered on the EDT, and everything is cancelled when the
 * panel is disposed.
 */
class UiTasks(parentScope: CoroutineScope, parent: Disposable) {
    val scope: CoroutineScope = CoroutineScope(parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext.job))

    init {
        Disposer.register(parent) { scope.cancel() }
    }

    /** Runs [work] off the EDT, then [onSuccess] or [onError] on the EDT. */
    fun <T> launch(work: suspend () -> T, onError: (Throwable) -> Unit, onSuccess: (T) -> Unit): Job =
        scope.launch(Dispatchers.IO) {
            val result = try {
                Result.success(work())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Result.failure(e)
            }
            withContext(Dispatchers.EDT + ModalityState.any().asContextElement()) {
                result.fold(onSuccess, onError)
            }
        }

    /** Runs a UI flow on the EDT; use [io] for protocol calls inside it. */
    fun launchUi(block: suspend CoroutineScope.() -> Unit): Job = scope.launch(Dispatchers.EDT, block = block)
}

/**
 * Runs suspending protocol work on a background thread that owns [indicator]
 * (a `Task.Backgroundable` or modal progress); cancelling the indicator
 * cancels the work and surfaces as a `ProcessCanceledException`.
 */
fun <T> runWithIndicator(indicator: ProgressIndicator?, block: suspend () -> T): T = runBlocking {
    val work = async { block() }
    val watcher = launch {
        while (isActive) {
            if (indicator?.isCanceled == true) {
                work.cancel()
                break
            }
            delay(100)
        }
    }
    try {
        work.await()
    } catch (e: CancellationException) {
        indicator?.checkCanceled()
        throw e
    } finally {
        watcher.cancel()
    }
}

/** Runs protocol work off the EDT. */
suspend fun <T> io(block: suspend () -> T): T = withContext(Dispatchers.IO) { block() }

/** Message for an error shown in the UI, with the protocol error code when useful. */
fun errorText(error: Throwable): String {
    val message = error.message ?: error.javaClass.simpleName
    if (error !is InspectorException) return message
    return when (error.code) {
        ErrorCodes.NOT_CONNECTED, ErrorCodes.CONNECTION_LOST, ErrorCodes.CLIENT_TIMEOUT -> message
        else -> "${error.code}: $message"
    }
}

/** Status line with an icon: info, success, warning or error. */
class StatusLine : SimpleColoredComponent() {
    init {
        isOpaque = false
        ipad = com.intellij.util.ui.JBUI.insets(2, 6)
    }

    fun show(text: String, icon: Icon? = null, attributes: SimpleTextAttributes = SimpleTextAttributes.REGULAR_ATTRIBUTES) {
        clear()
        this.icon = icon
        append(text, attributes)
        toolTipText = text
        repaint()
    }

    fun info(text: String) = show(text, null, SimpleTextAttributes.GRAYED_ATTRIBUTES)

    fun success(text: String) = show(text, AllIcons.General.InspectionsOK)

    fun warning(text: String) = show(text, AllIcons.General.Warning)

    fun error(text: String) = show(text, AllIcons.General.Error, SimpleTextAttributes.ERROR_ATTRIBUTES)

    fun loading(text: String) = show(text, com.intellij.ui.AnimatedIcon.Default.INSTANCE, SimpleTextAttributes.GRAYED_ATTRIBUTES)
}

fun copyToClipboard(text: String) {
    CopyPasteManager.getInstance().setContents(StringSelection(text))
}

/** The editor font (monospace), following the IDE color scheme. */
fun monospaceFont(): Font = EditorColorsManager.getInstance().globalScheme.getFont(EditorFontType.PLAIN)

/** A simple EDT action; [enabled] is evaluated on every update. */
fun action(
    text: String,
    icon: Icon? = null,
    description: String? = null,
    enabled: () -> Boolean = { true },
    visible: () -> Boolean = { true },
    run: (AnActionEvent) -> Unit,
): AnAction = object : DumbAwareAction(text, description, icon) {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun update(e: AnActionEvent) {
        e.presentation.isVisible = visible()
        e.presentation.isEnabled = enabled()
    }

    override fun actionPerformed(e: AnActionEvent) = run(e)
}

fun toggleAction(
    text: String,
    icon: Icon?,
    selected: () -> Boolean,
    enabled: () -> Boolean = { true },
    set: (Boolean) -> Unit,
): AnAction = object : ToggleAction(text, null, icon) {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT

    override fun isSelected(e: AnActionEvent): Boolean = selected()

    override fun setSelected(e: AnActionEvent, state: Boolean) = set(state)

    override fun update(e: AnActionEvent) {
        super.update(e)
        e.presentation.isEnabled = enabled()
    }
}

fun toolbar(place: String, target: JComponent, vararg actions: AnAction): ActionToolbar {
    val group = DefaultActionGroup().apply { actions.forEach { add(it) } }
    return ActionManager.getInstance().createActionToolbar(place, group, true).apply {
        targetComponent = target
    }
}

/** Shows a popup menu for [group] at a point of [component]. */
fun showPopupMenu(place: String, group: DefaultActionGroup, component: JComponent, x: Int, y: Int) {
    ActionManager.getInstance().createActionPopupMenu(place, group).component.show(component, x, y)
}
