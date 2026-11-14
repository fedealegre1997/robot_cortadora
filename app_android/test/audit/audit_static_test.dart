// Auditor — verificaciones ESTÁTICAS sobre las fuentes (no ejecutan el
// código: leen los archivos). Sirven para lo que no se puede ejercitar sin
// hardware o sin compilar (BLE conectado, manifest, gradle). Se corren desde
// la raíz del proyecto (flutter test lo hace).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String p) => File(p).readAsStringSync();

List<File> dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  test('lib/: nadie construye AppConfig con toolsEnabled: true ni lee TOOLS_ENABLED fuera de app_config',
      () {
    final offenders = <String>[];
    for (final f in dartFiles('lib')) {
      final src = f.readAsStringSync();
      final name = f.path.replaceAll('\\', '/');
      if (RegExp(r'toolsEnabled\s*:\s*true').hasMatch(src)) offenders.add('$name: toolsEnabled: true');
      if (!name.endsWith('core/app_config.dart') && src.contains('TOOLS_ENABLED') &&
          RegExp(r'fromEnvironment\(\s*.TOOLS_ENABLED').hasMatch(src)) {
        offenders.add('$name: lee TOOLS_ENABLED');
      }
      if (!name.endsWith('core/app_config.dart') && RegExp(r'\bAppConfig\(').hasMatch(src)) {
        offenders.add('$name: construye AppConfig(...)');
      }
    }
    expect(offenders, isEmpty);
    expect(read('lib/core/app_config.dart'),
        contains("bool.fromEnvironment('TOOLS_ENABLED', defaultValue: false)"));
    expect(read('lib/main.dart'), contains('AppConfig.fromEnvironment'));
  });

  test('BleRobotLink.sendCommand aplica la política de herramientas ANTES de escribir', () {
    final src = read('lib/core/ble_robot_link.dart');
    final start = src.indexOf('Future<void> sendCommand(ControlCommand command)');
    expect(start, greaterThan(0));
    final end = src.indexOf('\n  }', start);
    final body = src.substring(start, end);
    final policy = body.indexOf('applyToolsPolicy(toolsEnabled: config.toolsEnabled)');
    final write = body.indexOf('_enqueueWrite(');
    expect(policy, greaterThan(0), reason: body);
    expect(write, greaterThan(policy), reason: 'escribe lo filtrado');
    expect(body, contains('_enqueueWrite(toSend.toJsonLine())'));
    // Ningún otro camino escribe una línea CMD.
    expect('toJsonLine()'.allMatches(src).length, 1);
  });

  test('SimulatedRobotLink.sendCommand aplica la política de herramientas', () {
    final src = read('lib/core/simulated_robot_link.dart');
    expect(src, contains('command.applyToolsPolicy(toolsEnabled: config.toolsEnabled)'));
  });

  test('link_factory: el enlace por defecto es el simulado (BLE no cableado en la APK)', () {
    final src = read('lib/app/link_factory.dart');
    expect(src, contains('SimulatedRobotLink(config)'));
    for (final f in dartFiles('lib')) {
      final name = f.path.replaceAll('\\', '/');
      if (name.endsWith('core/ble_robot_link.dart')) continue;
      expect(f.readAsStringSync().contains('BleRobotLink('), isFalse, reason: name);
    }
  });

  // Ronda 2: la licencia pasó de `null` (PENDIENTE) a `License.nonprofit` por
  // DECISIÓN DEL USUARIO (13/11/26, AUD-09): no es un dato inventado. Los UUID
  // siguen PENDIENTES y connect() sigue bloqueado (ver audit_ble_test.dart).
  test('BLE: UUID sin inventar (null = PENDIENTE); licencia = la decidida por el usuario', () {
    final src = read('lib/core/ble_robot_link.dart');
    expect(src, contains('static const String? serviceUuid = null;'));
    expect(src, contains('static const String? rxCharacteristicUuid = null;'));
    expect(src, contains('static const String? txCharacteristicUuid = null;'));
    expect(src, contains('static const License license = License.nonprofit;'));
    expect(RegExp(r'License\.commercial').hasMatch(src), isFalse);
    // isConfigured sigue dependiendo de los tres UUID
    expect(src, contains('serviceUuid != null'));
    expect(src, contains('rxCharacteristicUuid != null'));
    expect(src, contains('txCharacteristicUuid != null'));
    // ningún UUID literal en lib/
    final uuid = RegExp(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');
    for (final f in dartFiles('lib')) {
      expect(uuid.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
  });

  test('sin mapa en esta APK: ninguna dependencia ni pantalla de mapa', () {
    final pubspec = read('pubspec.yaml');
    for (final p in ['google_maps', 'flutter_map', 'mapbox', 'maplibre']) {
      expect(pubspec.contains(p), isFalse, reason: p);
    }
    for (final f in dartFiles('lib')) {
      // Se quitan los comentarios de línea: home_shell.dart deja la pantalla
      // de mapa futura SOLO comentada, lo cual está permitido.
      final code = f
          .readAsLinesSync()
          .map((l) => l.replaceFirst(RegExp(r'//.*$'), ''))
          .join('\n');
      expect(code.contains('MapScreen'), isFalse,
          reason: '${f.path} (solo se admite en comentario)');
    }
  });

  group('AndroidManifest.xml (FUENTE; el compilado/mergeado queda para la ronda APK)', () {
    final m = read('android/app/src/main/AndroidManifest.xml')
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ''); // sin comentarios

    String? permTag(String name) => RegExp(
            '<uses-permission[^>]*android:name="android\\.permission\\.$name"[^>]*/>')
        .firstMatch(m)
        ?.group(0);

    test('BLUETOOTH_SCAN con neverForLocation, sin maxSdkVersion', () {
      final t = permTag('BLUETOOTH_SCAN');
      expect(t, isNotNull);
      expect(t, contains('android:usesPermissionFlags="neverForLocation"'));
      expect(t, isNot(contains('maxSdkVersion')));
    });

    test('BLUETOOTH_CONNECT sin maxSdkVersion', () {
      final t = permTag('BLUETOOTH_CONNECT');
      expect(t, isNotNull);
      expect(t, isNot(contains('maxSdkVersion')));
    });

    test('permisos viejos solo con maxSdkVersion ≤ 30', () {
      for (final p in [
        'BLUETOOTH',
        'BLUETOOTH_ADMIN',
        'ACCESS_FINE_LOCATION',
        'ACCESS_COARSE_LOCATION',
      ]) {
        final t = permTag(p);
        if (t == null) continue;
        final v = RegExp(r'android:maxSdkVersion="(\d+)"').firstMatch(t);
        expect(v, isNotNull, reason: '$p sin maxSdkVersion');
        expect(int.parse(v!.group(1)!), lessThanOrEqualTo(30), reason: p);
      }
    });

    test('AUD-10: features bluetooth, bluetooth_le y location declaradas required="false"', () {
      for (final f in ['bluetooth', 'bluetooth_le', 'location']) {
        final t = RegExp('<uses-feature[^>]*android:name="android\\.hardware\\.$f"[^>]*/>')
            .firstMatch(m)
            ?.group(0);
        expect(t, isNotNull, reason: f);
        expect(t, contains('android:required="false"'), reason: f);
      }
    });

    test('no pide ubicación en segundo plano ni BLUETOOTH_ADVERTISE', () {
      expect(permTag('ACCESS_BACKGROUND_LOCATION'), isNull);
      expect(permTag('BLUETOOTH_ADVERTISE'), isNull);
    });
  });

  test('build.gradle.kts: bloque que desactiva flutterBluePlusLicensePing*', () {
    final g = read('android/app/build.gradle.kts');
    expect(
        g,
        contains(
            'tasks.matching { it.name.startsWith("flutterBluePlusLicensePing") }.configureEach {'));
    expect(g, contains('enabled = false'));
  });
}
