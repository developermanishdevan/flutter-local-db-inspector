# Troubleshooting

| Symptom | Fix |
|---|---|
| **Inspector not connecting** | Run a *debug* build. Check that `DbInspector.initialize()` runs in `main`. In VS Code, open *Output → Flutter DB Inspector*. For apps started from a terminal, use **Connect to VM Service URI…** with the URI `flutter run` prints. |
| **"Waiting for the app to call DbInspector.initialize()"** | Connected to the VM, but the extension isn't registered yet, or `enabled` is false. |
| **Database not appearing** | Call `DbInspector.registerDatabase(...)` after the database is open. Clients refresh automatically when you do. |
| **Hot restart** | Handled automatically: the view shows *Reconnecting…*, then reloads. Requests made during the restart wait for the app. |
| **Multiple isolates** | Only the isolate that called `initialize` is inspected. Databases opened in background isolates must be registered from that isolate; full multi-isolate support is planned. |
| **`DATABASE_BUSY`** | The app holds a lock, for example during a long transaction. Retry when it finishes. |
| **`QUERY_TIMEOUT`** | The operation took longer than 5 s. Narrow the query or raise `InspectorLimits(queryTimeout: …)`. SQLite statements may still finish in the background. |
| **Large database / `RESULT_TOO_LARGE`** | Use a smaller page size and fewer columns. Large values are previewed; open them in the value inspector to stream the full value. |
| **Filtering is slow / `RESULT_TOO_LARGE` on Hive, ObjectBox, …** | These engines filter in memory, bounded by `maxScanDocuments`. Narrow the search or raise the bound. |
| **Permission errors** | `PERMISSION_DENIED` means the column is masked. `WRITE_NOT_ALLOWED` means read-only mode or a read-only database. |
| **Unsupported adapter / operation** | Operations the engine doesn't advertise are hidden. Calling them returns `UNSUPPORTED_OPERATION`. |
| **Release build** | The inspector is disabled by design. See [security.md](security.md). |
| **VS Code tests fail to launch from a VS Code terminal** | Unset `ELECTRON_RUN_AS_NODE` (`env -u ELECTRON_RUN_AS_NODE npm run test:vscode`). |
