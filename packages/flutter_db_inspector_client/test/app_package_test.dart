import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:test/test.dart';

/// Mirrors `appPackage.test.ts` (VS Code); the rules must agree.
void main() {
  test('package: root library gives the package name', () {
    expect(appPackageOf('package:sfa_app/main.dart'), 'sfa_app');
    expect(appPackageOf('package:sfa_app/flavors/main_dev.dart'), 'sfa_app');
  });

  test('file root library under lib/ gives the folder above lib/', () {
    expect(
      appPackageOf('file:///Users/me/work/sfa_app/lib/main_dev.dart'),
      'sfa_app',
    );
    expect(appPackageOf('file:///C:/src/sfa_app/lib/src/main.dart'), 'sfa_app');
  });

  test('web root library uses the app library list', () {
    const libraries = [
      'dart:core',
      'package:flutter/material.dart',
      'package:sfa_app/main.dart',
    ];
    expect(appPackageOf('org-dartlang-app:///main.dart', libraries), 'sfa_app');
  });

  test('falls back to the file name, or nothing', () {
    expect(
      appPackageOf('file:///tmp/example/inspector_server.dart'),
      'inspector_server',
    );
    expect(appPackageOf(null), isNull);
    expect(appPackageOf(''), isNull);
  });
}
