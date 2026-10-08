import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'bridge.dart';

/// Outside the browser (tests) there is no iframe: shows [missing].
Widget buildWebUiFrame({
  required WebUiBridge Function(PostToWebUi post) createBridge,
  required Widget missing,
  required bool dark,
}) =>
    missing;

void downloadFile(String name, Uint8List bytes) {}

String? readUiMode() => null;

void writeUiMode(String mode) {}
