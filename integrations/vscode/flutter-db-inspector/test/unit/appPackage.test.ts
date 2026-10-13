import assert from 'node:assert/strict';
import { test } from 'node:test';

import { appPackageOf } from '../../src/connection/appPackage';

test('package: root library gives the package name', () => {
  assert.equal(appPackageOf('package:sfa_app/main.dart'), 'sfa_app');
  assert.equal(appPackageOf('package:sfa_app/flavors/main_dev.dart'), 'sfa_app');
});

test('file root library under lib/ gives the folder above lib/', () => {
  assert.equal(appPackageOf('file:///Users/me/work/sfa_app/lib/main_dev.dart'), 'sfa_app');
  assert.equal(appPackageOf('file:///C:/src/sfa_app/lib/src/main.dart'), 'sfa_app');
});

test('web root library uses the app library list', () => {
  const libraries = ['dart:core', 'package:flutter/material.dart', 'package:sfa_app/main.dart'];
  assert.equal(appPackageOf('org-dartlang-app:///main.dart', libraries), 'sfa_app');
});

test('falls back to the file name, or nothing', () => {
  assert.equal(appPackageOf('file:///tmp/example/inspector_server.dart'), 'inspector_server');
  assert.equal(appPackageOf(undefined), undefined);
  assert.equal(appPackageOf(''), undefined);
});
