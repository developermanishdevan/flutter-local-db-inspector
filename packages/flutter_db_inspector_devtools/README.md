# flutter_db_inspector_devtools

Source of the Flutter DB Inspector DevTools extension (a Flutter web app). It
is not published on its own: the build is copied into
`packages/flutter_db_inspector/extension/devtools` and ships inside
`flutter_db_inspector`.

## Rebuild

```bash
tool/sync_web_ui.sh
dart run devtools_extensions build_and_copy --source=. --dest=../flutter_db_inspector/extension/devtools
dart run devtools_extensions validate --package=../flutter_db_inspector
```

See [docs/devtools.md](../../docs/devtools.md).
