package com.manishdevan.flutterdb.connection

import com.intellij.execution.ExecutionListener
import com.intellij.execution.process.ProcessEvent
import com.intellij.execution.process.ProcessHandler
import com.intellij.execution.process.ProcessListener
import com.intellij.execution.runners.ExecutionEnvironment
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Key
import com.manishdevan.flutterdb.service.InspectorService

/**
 * Finds running Dart/Flutter apps without depending on the Flutter or Dart
 * plugins: listens to every process started through a run configuration
 * (`ExecutionManager.EXECUTION_TOPIC`) and watches its console output for the
 * VM service announcement:
 *
 * - `A Dart VM Service on <device> is available at: <uri>` (`flutter run`)
 * - `The Dart VM service is listening on <uri>` (`dart run --enable-vm-service`)
 * - `{"event":"app.debugPort",…,"wsUri":"<uri>"}` (Flutter daemon / `--machine`)
 *
 * The service connects to the newest app (unless auto-connect is off) and
 * disconnects when that process terminates.
 */
class RunConsoleDiscovery(private val project: Project) : ExecutionListener {
    override fun processStarted(executorId: String, env: ExecutionEnvironment, handler: ProcessHandler) {
        val label = env.runProfile.name
        handler.addProcessListener(ConsoleScanner(label) { uri ->
            if (!project.isDisposed) InspectorService.getInstance(project).onVmServiceDiscovered(handler, uri, label)
        }.also { scanner ->
            scanner.onTerminated = {
                if (!project.isDisposed) InspectorService.getInstance(project).onProcessTerminated(handler)
            }
        })
    }

    /** Splits process output into lines and reports each newly announced URI. */
    class ConsoleScanner(private val label: String, private val onUri: (String) -> Unit) : ProcessListener {
        private val partial = StringBuilder()
        private val seen = mutableSetOf<String>()
        var onTerminated: () -> Unit = {}

        override fun onTextAvailable(event: ProcessEvent, outputType: Key<*>) {
            accept(event.text ?: return)
        }

        /** Feeds raw output (may contain partial or several lines). */
        @Synchronized
        fun accept(text: String) {
            partial.append(text)
            while (true) {
                val newline = partial.indexOf("\n")
                if (newline < 0) break
                val line = partial.substring(0, newline)
                partial.delete(0, newline + 1)
                scan(line)
            }
            // Never buffer unbounded output without newlines.
            if (partial.length > MAX_LINE) partial.setLength(0)
        }

        private fun scan(line: String) {
            if (line.length > MAX_LINE) return
            val uri = VmServiceUri.fromConsoleLine(line) ?: return
            if (seen.add(uri)) onUri(uri)
        }

        override fun processTerminated(event: ProcessEvent) {
            onTerminated()
        }

        override fun toString(): String = "ConsoleScanner($label)"
    }

    private companion object {
        const val MAX_LINE = 16 * 1024
    }
}
