# Security

> Flutter DB Inspector is a development and debugging tool.

- **Disabled in release builds.** `DbInspector.initialize()` is enabled only in debug builds by default. In release mode it stays disabled even with `enabled: true`, unless you also pass `allowInReleaseMode: true`. Release builds have no VM service anyway.
- **No network server.** The inspector is a Dart VM service extension. It's only reachable by tools that already have debugging access to the app, such as the IDE, `flutter run` or DevTools. It never opens a port of its own.
- **Read-only mode.** `DbInspector.initialize(readOnly: true)` rejects every write, including confirmed SQL writes. You can also make individual databases read-only with `registerDatabase(..., readOnly: true)`.
- **Masking.** `sensitiveColumns: {'users.password', '*.token'}`:
  - Masked values are replaced with `{"$type":"masked"}` *inside the app*; the real value never leaves the device.
  - Masked columns can't be filtered, sorted, searched or read with `value.read`, so their contents can't be probed.
  - Ad-hoc SQL results are masked by column name.
  - Exports write masked values as `null`.
- **Secure storage** values are masked by default (`revealValues: false`).
- **Confirmation.** Deleting rows, clearing tables, and any SQL the runtime can't prove is read-only all need explicit confirmation in the client. SQL writes are also checked again on the app side (`allowWrite`).
- **Your data stays local.** Query history and saved queries are stored by the IDE, never in your app's database.

Never enable full access in production builds, and remember that local databases often contain personal data. Use masking for anything sensitive.
