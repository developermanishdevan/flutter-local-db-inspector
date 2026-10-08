package com.manishdevan.flutterdb.ui

import com.google.gson.JsonObject
import com.intellij.notification.NotificationType
import com.intellij.openapi.fileChooser.FileChooser
import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory
import com.intellij.openapi.fileChooser.FileChooserFactory
import com.intellij.openapi.fileChooser.FileSaverDescriptor
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.Task
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.Messages
import com.manishdevan.flutterdb.FlutterDbPlugin
import com.manishdevan.flutterdb.protocol.DatabaseDescriptor
import com.manishdevan.flutterdb.protocol.Labels
import com.manishdevan.flutterdb.protocol.RowsQuery
import com.manishdevan.flutterdb.protocol.Values
import com.manishdevan.flutterdb.service.ExportFormat
import com.manishdevan.flutterdb.service.ExportSummary
import com.manishdevan.flutterdb.service.InspectorService
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

/**
 * Operations shared by the database tree and the data view: clearing an
 * entity, exporting entities or databases, and saving large values to files.
 * Long-running work uses cancellable background tasks with progress.
 */
object EntityOperations {
    private fun defaultDir(project: Project): Path? = project.basePath?.let { Paths.get(it) }

    /** Asks for confirmation (with the record count), then deletes every record. */
    fun clear(project: Project, service: InspectorService, db: DatabaseDescriptor, table: String, kind: String, tasks: UiTasks, onCleared: () -> Unit) {
        val noun = Labels.recordNoun(kind, plural = true)
        tasks.launchUi {
            val count = try {
                io { service.client.countRows(RowsQuery(db.id, table)) }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
            val choice = Messages.showOkCancelDialog(
                project,
                "Delete all ${count?.let { "${Values.formatCount(it)} " } ?: ""}$noun from \"$table\"?\n\n" +
                    "This permanently changes the running app's ${Labels.engineLabel(db.type)} data.",
                "Clear $table",
                "Clear",
                Messages.getCancelButton(),
                Messages.getWarningIcon(),
            )
            if (choice != Messages.OK) return@launchUi
            try {
                val result = io { service.client.clearTable(db.id, table) }
                FlutterDbPlugin.notify(project, "Deleted ${Values.formatCount(result.affectedRows)} $noun from $table.")
                service.dataChanged()
                onCleared()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                Messages.showErrorDialog(project, errorText(e), "Clear $table")
            }
        }
    }

    private fun chooseFormat(project: Project, db: DatabaseDescriptor, what: String): ExportFormat? {
        val formats = ExportFormat.available(db.isRelational)
        val options = formats.map { it.label } + Messages.getCancelButton()
        val index = Messages.showDialog(project, "Choose the export format:", "Export $what", options.toTypedArray(), 0, null)
        return formats.getOrNull(index)
    }

    private fun chooseSaveFile(project: Project, title: String, format: String, fileName: String): File? {
        val descriptor = FileSaverDescriptor(title, "", format)
        return FileChooserFactory.getInstance().createSaveFileDialog(descriptor, project)
            .save(defaultDir(project), fileName)?.file
    }

    /** Exports one table / collection / box to a file chosen by the user. */
    fun exportEntity(project: Project, service: InspectorService, db: DatabaseDescriptor, table: String) {
        val format = chooseFormat(project, db, table) ?: return
        val file = chooseSaveFile(project, "Export $table", format.extension, "$table.${format.extension}") ?: return
        object : Task.Backgroundable(project, "Exporting $table", true) {
            private var summary: ExportSummary? = null

            override fun run(indicator: ProgressIndicator) {
                indicator.isIndeterminate = false
                file.bufferedWriter(Charsets.UTF_8).use { out ->
                    summary = runWithIndicator(indicator) {
                        service.exporter.export(
                            db.id, table, format,
                            write = out::write,
                            onProgress = { rows, total -> progress(indicator, table, rows, total) },
                            isCancelled = indicator::isCanceled,
                        )
                    }
                }
            }

            override fun onSuccess() {
                summary?.let { report(project, table, listOf(it), file) }
            }

            override fun onCancel() {
                FlutterDbPlugin.notify(project, "Export of $table was cancelled — ${file.name} is incomplete.", NotificationType.WARNING)
            }

            override fun onThrowable(error: Throwable) {
                FlutterDbPlugin.notify(project, "Export of $table failed: ${errorText(error)}", NotificationType.ERROR)
            }
        }.queue()
    }

    /** Exports every entity: one SQL file, or one JSON/CSV file per entity in a folder. */
    fun exportDatabase(project: Project, service: InspectorService, db: DatabaseDescriptor) {
        val format = chooseFormat(project, db, db.name) ?: return
        val sqlFile: File?
        val dir: File?
        if (format == ExportFormat.SQL) {
            sqlFile = chooseSaveFile(project, "Export ${db.name}", "sql", "${db.id}.sql") ?: return
            dir = null
        } else {
            val descriptor = FileChooserDescriptorFactory.createSingleFolderDescriptor().withTitle("Export ${db.name} — Choose a Folder")
            val folder = FileChooser.chooseFile(descriptor, project, null) ?: return
            sqlFile = null
            dir = File(folder.path, db.id)
        }
        object : Task.Backgroundable(project, "Exporting ${db.name}", true) {
            private val summaries = mutableListOf<ExportSummary>()

            override fun run(indicator: ProgressIndicator) {
                runWithIndicator(indicator) {
                    val overview = service.client.schema(db.id)
                    val entities = overview.entities.filter { format != ExportFormat.SQL || it.kind == "table" }
                    if (sqlFile != null) {
                        sqlFile.bufferedWriter(Charsets.UTF_8).use { out ->
                            out.write("-- ${db.name} exported by Flutter DB Inspector\nBEGIN TRANSACTION;\n\n")
                            for ((i, entity) in entities.withIndex()) {
                                if (indicator.isCanceled) break
                                indicator.fraction = i.toDouble() / entities.size.coerceAtLeast(1)
                                summaries += service.exporter.export(
                                    db.id, entity.name, format,
                                    write = out::write,
                                    onProgress = { rows, _ -> indicator.text2 = "${entity.name}: ${Values.formatCount(rows)}" },
                                    isCancelled = indicator::isCanceled,
                                )
                                out.write("\n")
                            }
                            out.write("COMMIT;\n")
                        }
                    } else if (dir != null) {
                        Files.createDirectories(dir.toPath())
                        for ((i, entity) in entities.withIndex()) {
                            if (indicator.isCanceled) break
                            indicator.fraction = i.toDouble() / entities.size.coerceAtLeast(1)
                            File(dir, "${safeFileName(entity.name)}.${format.extension}").bufferedWriter(Charsets.UTF_8).use { out ->
                                summaries += service.exporter.export(
                                    db.id, entity.name, format,
                                    write = out::write,
                                    onProgress = { rows, _ -> indicator.text2 = "${entity.name}: ${Values.formatCount(rows)}" },
                                    isCancelled = indicator::isCanceled,
                                )
                            }
                        }
                    }
                }
            }

            override fun onSuccess() = report(project, db.name, summaries, sqlFile ?: dir)

            override fun onCancel() {
                FlutterDbPlugin.notify(project, "Export of ${db.name} was cancelled — the output is incomplete.", NotificationType.WARNING)
            }

            override fun onThrowable(error: Throwable) {
                FlutterDbPlugin.notify(project, "Export of ${db.name} failed: ${errorText(error)}", NotificationType.ERROR)
            }
        }.queue()
    }

    /** Streams a large value with `value.read` into a file. */
    fun saveValueToFile(project: Project, service: InspectorService, db: DatabaseDescriptor, table: String, key: JsonObject, column: String) {
        val file = chooseSaveFile(project, "Save $table.$column", "bin", "${safeFileName(table)}_${safeFileName(column)}.bin") ?: return
        object : Task.Backgroundable(project, "Saving $column", true) {
            override fun run(indicator: ProgressIndicator) {
                indicator.isIndeterminate = false
                val full = runWithIndicator(indicator) {
                    service.client.readFullValue(
                        db.id, table, key, column,
                        onProgress = { read, total ->
                            if (total > 0) indicator.fraction = read.toDouble() / total
                            indicator.text2 = "${Values.formatBytes(read)} of ${Values.formatBytes(total)}"
                        },
                        isCancelled = indicator::isCanceled,
                    )
                }
                indicator.checkCanceled()
                file.writeBytes(full.bytes)
            }

            override fun onSuccess() {
                FlutterDbPlugin.notify(project, "Saved $column to ${file.path} (${Values.formatBytes(file.length())}).")
            }

            override fun onThrowable(error: Throwable) {
                FlutterDbPlugin.notify(project, "Saving $column failed: ${errorText(error)}", NotificationType.ERROR)
            }
        }.queue()
    }

    private fun progress(indicator: ProgressIndicator, table: String, rows: Long, total: Long?) {
        indicator.text2 = "$table: ${Values.formatCount(rows)}${total?.let { " / ${Values.formatCount(it)}" } ?: ""}"
        if (total != null && total > 0) indicator.fraction = rows.toDouble() / total
    }

    private fun report(project: Project, what: String, summaries: List<ExportSummary>, target: File?) {
        val rows = summaries.sumOf { it.rows }
        val masked = summaries.flatMap { it.maskedColumns }.toSortedSet()
        val notes = listOfNotNull(
            "masked columns exported as null: ${masked.joinToString(", ")}".takeIf { masked.isNotEmpty() },
            "cancelled — the output is incomplete".takeIf { summaries.any { it.cancelled } },
        )
        val where = target?.let { " to ${it.path}" } ?: ""
        FlutterDbPlugin.notify(
            project,
            "Exported ${Values.formatCount(rows)} records from $what$where.${if (notes.isEmpty()) "" else " (${notes.joinToString("; ")})"}",
            if (masked.isEmpty()) NotificationType.INFORMATION else NotificationType.WARNING,
        )
    }

    private fun safeFileName(name: String): String = name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
}
