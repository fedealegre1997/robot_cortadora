// Auditor — test 2: el heartbeat NO se retrasa bajo carga del hilo principal.
//
// CÓMO SE CORRE (reloj real: necesita la CPU para él):
//   flutter.bat test test/audit/audit_heartbeat_load_test.dart --concurrency=1
//   (o la suite completa con --concurrency=1). En paralelo con otros archivos
//   de test la CPU se comparte y la medición puede quedar INVÁLIDA (ver abajo).
//
// Con fake_async no hay carga real (el reloj es ficticio), así que esta prueba
// usa RELOJ REAL (test() de package:test, sin testWidgets) y carga sintética
// en el MISMO isolate que el heartbeat:
//   - una cadena continua de tareas del event loop, cada una ocupando la CPU
//     [chunkMs] ms (simula frames/handlers pesados), y
//   - en cada tarea, una ráfaga de microtareas + acciones de UI sobre el
//     controlador (notifyListeners, setSpeed, press/release).
//
// Tres veredictos DISTINTOS (nunca se mezclan):
//   1. "MEDICIÓN INVÁLIDA — no se generó la carga": la carga ocupó < 80 % de
//      la ventana (CPU compartida). No dice nada del heartbeat.
//   2. "MEDICIÓN INVÁLIDA — el entorno retrasó también al testigo": un
//      Timer.periodic TESTIGO de 100 ms, independiente del controlador y en el
//      mismo isolate, tuvo un hueco ≥ [maxGapMs]: el retraso es del entorno
//      (SO/CPU), no de la app. No dice nada del heartbeat.
//   3. Solo si 1 y 2 están bien se juzga el heartbeat: hueco máximo < 200 ms
//      (corte del ESP: 300 ms), período medio 95–110 ms, y el heartbeat no se
//      atrasa más de [vsWitnessMs] respecto del testigo.
//
// QUÉ DEMUESTRA: que con el isolate ocupado al ~100 % en trozos cortos
// (≤ chunkMs) el Timer.periodic del controlador sigue saliendo a ~100 ms y no
// peor que un timer cualquiera: la carga y las notificaciones de UI no lo
// empujan más allá de un trozo.
// QUÉ NO DEMUESTRA: el comportamiento en el Galaxy M12 real (CPU lenta, GC,
// hilo de raster, BLE con write-with-response, ahorro de energía de Android).
// Un trabajo SÍNCRONO largo SÍ lo retrasa: lo caracteriza el tercer test (es
// inherente a Dart de un solo hilo; el respaldo es el corte de 300 ms del ESP).

import 'dart:async';
import 'dart:math' as math;

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_helpers.dart';

const off = AppConfig(toolsEnabled: false);
const int chunkMs = 8;
const int maxGapMs = 200;
const int vsWitnessMs = 20;
const double meanLo = 95;
const double meanHi = 110;
const double minLoadShare = 0.8;
const Duration window = Duration(seconds: 4);

void _busy(int ms) {
  final sw = Stopwatch()..start();
  while (sw.elapsedMicroseconds < ms * 1000) {}
}

class _Stats {
  final int count;
  final double meanMs;
  final int maxGapMs;
  final List<int> gaps;
  _Stats(this.count, this.meanMs, this.maxGapMs, this.gaps);
  @override
  String toString() =>
      'envíos=$count medio=${meanMs.toStringAsFixed(1)}ms máx=${maxGapMs}ms';
}

_Stats _stats(List<Duration> at) {
  final gaps = <int>[
    for (var i = 1; i < at.length; i++) (at[i] - at[i - 1]).inMilliseconds,
  ];
  final mean = gaps.isEmpty ? 0.0 : gaps.reduce((a, b) => a + b) / gaps.length;
  return _Stats(at.length, mean, gaps.isEmpty ? 0 : gaps.reduce(math.max), gaps);
}

/// Corre la carga durante [window] con un testigo; devuelve
/// (stats heartbeat, stats testigo, fracción de carga, tareas).
Future<(_Stats, _Stats, double, int)> _runLoaded({required bool pressRelease}) async {
  final sw = Stopwatch()..start();
  final link = RecordingLink(clock: () => sw.elapsed);
  final c = SessionController(link: link, config: off);
  link.setStatus(LinkStatus.connected);
  await Future<void>.delayed(Duration.zero);
  if (pressRelease) c.requestState(RobotState.manual);

  final witness = <Duration>[];
  final witnessTimer =
      Timer.periodic(AppConfig.heartbeatPeriod, (_) => witness.add(sw.elapsed));

  var running = true;
  var tasks = 0;
  final loadClock = Stopwatch();
  void loadTask() {
    if (!running) return;
    tasks++;
    _busy(chunkMs);
    for (var i = 0; i < 200; i++) {
      scheduleMicrotask(() {});
    }
    c.setSpeed(tasks % 101);
    if (pressRelease) {
      tasks.isEven ? c.pressDirection(Direction.forward) : c.releaseDirection();
    }
    Timer.run(loadTask);
  }

  loadClock.start();
  Timer.run(loadTask);
  await Future<void>.delayed(window);
  running = false;
  loadClock.stop();
  witnessTimer.cancel();
  final hb = _stats(List.of(link.sentAt));
  final w = _stats(witness);
  c.dispose();
  await link.dispose();
  final share = tasks * chunkMs / loadClock.elapsedMilliseconds;
  return (hb, w, share, tasks);
}

/// Veredictos 1 y 2: si la medición no es válida, falla con un mensaje que
/// NO habla del heartbeat.
void _requireValidMeasurement(String name, _Stats witness, double share, int tasks) {
  if (share < minLoadShare) {
    fail('$name: MEDICIÓN INVÁLIDA — no se generó la carga '
        '(ocupó ${(share * 100).toStringAsFixed(0)} % < ${(minLoadShare * 100).toStringAsFixed(0)} %, '
        'tareas=$tasks). CPU compartida: correr con --concurrency=1. '
        'No es un veredicto sobre el heartbeat.');
  }
  if (witness.maxGapMs >= maxGapMs) {
    fail('$name: MEDICIÓN INVÁLIDA — el entorno retrasó también al timer testigo '
        '($witness). El retraso no es de la app. Correr con --concurrency=1. '
        'No es un veredicto sobre el heartbeat.');
  }
}

void main() {
  test('A2 bajo carga continua del event loop el heartbeat sigue a ~100 ms (reloj real)',
      () async {
    final (hb, w, share, tasks) = await _runLoaded(pressRelease: true);
    // ignore: avoid_print
    print('A2 con carga + press/release: heartbeat $hb | testigo $w | '
        'carga ${(share * 100).toStringAsFixed(0)} % (tareas=$tasks)');
    _requireValidMeasurement('A2', w, share, tasks);
    // Los envíos incluyen los inmediatos de releaseDirection: importa el hueco
    // máximo (corte del ESP) y que no haya menos envíos que el heartbeat solo.
    expect(hb.maxGapMs, lessThan(maxGapMs), reason: '$hb');
    expect(hb.count, greaterThanOrEqualTo(36), reason: '$hb');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('A2 solo heartbeat bajo carga: período medio 95–110 ms y no peor que el testigo',
      () async {
    final (hb, w, share, tasks) = await _runLoaded(pressRelease: false);
    // ignore: avoid_print
    print('A2 solo heartbeat con carga: heartbeat $hb | testigo $w | '
        'carga ${(share * 100).toStringAsFixed(0)} % (tareas=$tasks)');
    _requireValidMeasurement('A2', w, share, tasks);
    expect(hb.meanMs, inInclusiveRange(meanLo, meanHi), reason: '$hb');
    expect(hb.maxGapMs, lessThan(maxGapMs), reason: '$hb');
    expect(hb.maxGapMs, lessThanOrEqualTo(w.maxGapMs + vsWitnessMs),
        reason: 'heartbeat $hb vs testigo $w');
    expect(hb.count, inInclusiveRange(36, 41), reason: '$hb');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('A2 (caracterización) un bloqueo síncrono de 400 ms SÍ abre un hueco > 300 ms',
      () async {
    final sw = Stopwatch()..start();
    final link = RecordingLink(clock: () => sw.elapsed);
    final c = SessionController(link: link, config: off);
    link.setStatus(LinkStatus.connected);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    _busy(400);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final s = _stats(List.of(link.sentAt));
    c.dispose();
    await link.dispose();
    // ignore: avoid_print
    print('A2 bloqueo 400 ms: $s gaps=${s.gaps}');
    // Documenta la limitación: el heartbeat vive en el hilo de la UI.
    expect(s.maxGapMs, greaterThan(300));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
