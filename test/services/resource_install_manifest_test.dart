import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:loop_back/services/resource_install_manifest.dart';

void main() {
  test('ResourceInstallManifest round trips the install schema', () {
    final manifest = ResourceInstallManifest(
      resourceId: 'en_US-amy-medium',
      installAt: DateTime(2026, 8, 26, 21, 54, 5),
      resourceSize: 1024,
    );

    final decoded = ResourceInstallManifest.fromJson(manifest.toJson());

    expect(decoded.resourceId, manifest.resourceId);
    expect(decoded.installAt, manifest.installAt);
    expect(decoded.resourceSize, manifest.resourceSize);
  });

  test('ResourceInstallManifest rejects invalid fields', () {
    expect(
      () => ResourceInstallManifest.fromJson({
        'resourceId': 'model',
        'installAt': 'not-a-date',
        'resourceSize': 1024,
      }),
      throwsFormatException,
    );
  });

  test('reads resourceSize from install.json', () async {
    final directory = await Directory.systemTemp.createTemp('install-manifest');
    addTearDown(() => directory.delete(recursive: true));
    await File(p.join(directory.path, 'install.json')).writeAsString(
      '{"resourceId":"model","installAt":"2026-08-26T00:00:00.000Z","resourceSize":4096}',
    );

    final manifest = await readResourceInstallManifest(directory);

    expect(manifest?.resourceId, 'model');
    expect(manifest?.resourceSize, 4096);
  });
}
