import 'package:vm_service/vm_service.dart';

/// Opens a VM service connection. Only available where `dart:io` is.
Future<VmService> connectToVmService(String uri) => throw UnsupportedError(
      'InspectorConnection.connectUri needs dart:io. On the web, create the '
      'VmService yourself and call InspectorConnection.attach.',
    );
