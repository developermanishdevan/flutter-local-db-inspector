@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Printed by the VM (via DDS) once the service accepts connections.
final _listeningUri = RegExp(r'VM service is listening on (\S+)');

/// Full path: client → VM service → service extension → router → SQLite.
void main() {
  late Process process;
  late VmService service;
  late String isolateId;

  setUpAll(() async {
    process = await Process.start(Platform.resolvedExecutable, [
      'run',
      '--enable-vm-service=0',
      'example/inspector_server.dart',
    ]);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    // Keep draining stdout for the life of the process (closing the pipe
    // would kill the server with EPIPE).
    final found = Completer<Uri>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final match = _listeningUri.firstMatch(line);
      if (match != null && !found.isCompleted) {
        found.complete(Uri.parse(match.group(1)!));
      }
    });
    final uri = await found.future.timeout(const Duration(seconds: 60));
    final ws = uri.replace(
      scheme: 'ws',
      path: '${uri.path.endsWith('/') ? uri.path : '${uri.path}/'}ws',
    );
    service = await vmServiceConnectUri(ws.toString());

    // Find the isolate exposing the extension (registered asynchronously).
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      final vm = await service.getVM();
      String? found;
      for (final ref in vm.isolates ?? <IsolateRef>[]) {
        final isolate = await service.getIsolate(ref.id!);
        if (isolate.extensionRPCs?.contains(serviceExtensionName) ?? false) {
          found = ref.id;
        }
      }
      if (found != null) {
        isolateId = found;
        break;
      }
      if (DateTime.now().isAfter(deadline)) fail('extension never registered');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });

  /// Waits until the app has registered its database; early clients learn
  /// about it from the `databasesChanged` event.
  setUpAll(() async {
    await service.streamListen(EventStreams.kExtension);
    final changed = service.onExtensionEvent
        .firstWhere((e) => e.extensionKind == InspectorEvents.databasesChanged)
        .timeout(const Duration(seconds: 60));
    final list = await service.callServiceExtension(
      serviceExtensionName,
      isolateId: isolateId,
      args: {
        serviceExtensionRequestParam:
            jsonEncode({'method': Methods.databaseList}),
      },
    );
    final dbs = ((list.json!['result']! as Map)['databases']! as List);
    if (dbs.isEmpty) {
      final event = await changed;
      expect(event.extensionData!.data['databases'], ['app_database']);
    }
  });

  tearDownAll(() async {
    await service.dispose();
    process.kill();
  });

  Future<Map<String, Object?>> call(String method,
      [Map<String, Object?> params = const {}]) async {
    final response = await service.callServiceExtension(
      serviceExtensionName,
      isolateId: isolateId,
      args: {
        serviceExtensionRequestParam: jsonEncode({
          'version': protocolVersion,
          'requestId': method,
          'method': method,
          'params': params,
        }),
      },
    );
    final json = response.json!;
    expect(json['success'], isTrue, reason: '$json');
    return (json['result']! as Map).cast<String, Object?>();
  }

  test('database.list → schema.list → rows.query over the VM service',
      () async {
    final dbs = await call(Methods.databaseList);
    final db = (dbs['databases']! as List).single as Map;
    expect(db['id'], 'app_database');

    final schema =
        await call(Methods.schemaList, {'databaseId': 'app_database'});
    final entities = {
      for (final e in schema['entities']! as List)
        (e as Map)['name']: e['rowCount'],
    };
    expect(entities['users'], 1000);
    expect(entities['products'], 5000);
    expect(entities['orders'], 10000);

    final rows = await call(Methods.rowsQuery, {
      'databaseId': 'app_database',
      'table': 'users',
      'search': 'User 99',
      'pageSize': 5,
    });
    expect(rows['total'], 11); // 99, 990–999
    expect((rows['rows']! as List), hasLength(5));
  });

  test('2 MB blob stays out of the grid response', () async {
    final rows = await call(Methods.rowsQuery, {
      'databaseId': 'app_database',
      'table': 'edge_cases',
    });
    expect(utf8.encode(jsonEncode(rows)).length, lessThan(64 * 1024));
  });
}
