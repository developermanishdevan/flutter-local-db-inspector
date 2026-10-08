import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs the device-free demo app (`flutter_db_inspector_sqlite/example/
/// inspector_server.dart`): a real Dart VM with the inspector and a seeded
/// in-memory SQLite database.
class DemoServer {
  DemoServer._(this._process, this.uri, this._lines);

  final Process _process;
  final String uri;
  final Stream<String> _lines;
  bool _stopped = false;

  static final _listening = RegExp(r'VM service is listening on (\S+)');

  static Future<DemoServer> start({bool restartable = false}) async {
    final sqliteDir = Directory.current.uri
        .resolve('../flutter_db_inspector_sqlite/')
        .toFilePath();
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '--enable-vm-service=0',
        'example/inspector_server.dart',
        if (restartable) '--restartable',
      ],
      workingDirectory: sqliteDir,
    );
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    // Keep stdout drained for the life of the process (a full pipe would
    // block the server).
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    final found = Completer<String>();
    lines.listen((line) {
      final match = _listening.firstMatch(line);
      if (match != null && !found.isCompleted) found.complete(match.group(1));
    });
    unawaited(process.exitCode.then((code) {
      if (!found.isCompleted) {
        found.completeError(StateError('demo server exited with $code'));
      }
    }));
    final uri = await found.future.timeout(const Duration(minutes: 2));
    return DemoServer._(process, uri, lines);
  }

  /// Simulates a hot restart (`--restartable` only).
  void restart() => _process.stdin.writeln('restart');

  Future<String> waitForLine(Pattern pattern) =>
      _lines.firstWhere((l) => l.contains(pattern)).timeout(
            const Duration(seconds: 60),
          );

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _process.kill(ProcessSignal.sigint);
    await _process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
