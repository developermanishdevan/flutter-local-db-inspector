import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'uri.dart';

/// Opens a WebSocket connection to the VM service at [uri].
Future<VmService> connectToVmService(String uri) =>
    vmServiceConnectUri(vmServiceWebSocketUri(uri).toString());
