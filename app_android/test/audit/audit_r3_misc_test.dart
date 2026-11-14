// Auditor — ronda 3: AUD-11 con RELOJ REAL (sin fake_async) y nombre de la
// app "Gramanova".
//
// AUD-11 con reloj real: el corte se decide AL CONSULTAR con el Stopwatch por
// defecto del simulador. Para aislar esa decisión del timer de respaldo, las
// consultas se hacen en una espera ACTIVA (síncrona): mientras dura, ningún
// timer puede correr. Mi cronómetro arranca DESPUÉS de que el simulador
// registró el comando, así que la antigüedad interna = la mía + δ (δ > 0, µs):
//   - con la mía = 299,0 ms → interna ≤ 299,0 ms + δ ≤ 300 ms → NO corta;
//   - con la mía = 300,3 ms → interna ≥ 300,3 ms > 300 ms → SÍ corta.

import 'dart:async';
import 'dart:math' as math;

import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/core/simulated_robot_link.dart';
import 'package:cortadora_e7/ui/app.dart';
import 'package:cortadora_e7/ui/labels.dart';
import 'package:cortadora_e7/app/session_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_helpers.dart';

const on = AppConfig(toolsEnabled: true);

ControlCommand full(int seq) => ControlCommand(
    state: RobotState.manual,
    dir: Direction.forward,
    speed: 100,
    cutter: 1,
    trimmer: 1,
    seq: seq);

void _spinUntil(Stopwatch sw, int micros) {
  while (sw.elapsedMicroseconds < micros) {}
}

Future<SimulatedRobotLink> _connected() async {
  final link = SimulatedRobotLink(on, connectDelay: Duration.zero);
  await link.connect();
  expect(link.status, LinkStatus.connected);
  return link;
}

bool _cut(SimulatedRobotLink l) {
  final p = l.espPublishedCommand!;
  return p.dir == Direction.none && p.cutter == 0 && p.trimmer == 0;
}

void main() {
  group('AUD-11 con reloj REAL (Stopwatch por defecto, VM real)', () {
    test('regla exacta con reloj REAL inyectado que registra cada lectura: en cada consulta '
        'alrededor del borde, corta ⇔ (lectura − recepción) > 300 ms', () async {
      // Reloj real (Stopwatch, µs) que guarda lo que el simulador leyó: la
      // aserción usa los valores que el código realmente vio, no los míos.
      final sw = Stopwatch()..start();
      final reads = <Duration>[];
      Duration clock() {
        final d = sw.elapsed;
        reads.add(d);
        return d;
      }

      final link = SimulatedRobotLink(on, connectDelay: Duration.zero, monotonicClock: clock);
      await link.connect();
      var sawFresh = 0, sawCut = 0;
      for (var i = 0; i < 10; i++) {
        reads.clear();
        await link.sendCommand(full(i));
        final at = reads.last; // instante de recepción que guardó el simulador
        _cut(link); // calentamiento (JIT)
        // consultas cada ~50 µs entre 299,5 y 300,5 ms de antigüedad
        for (var target = 299500; target <= 300500; target += 50) {
          while ((sw.elapsed - at).inMicroseconds < target) {}
          reads.clear();
          final cut = _cut(link);
          final age = reads.last - at; // la antigüedad que usó el código
          expect(cut, age > AppConfig.espCommandTimeout,
              reason: 'rep $i: edad leída ${age.inMicroseconds} µs → corte=$cut');
          cut ? sawCut++ : sawFresh++;
        }
        await Future<void>.delayed(Duration.zero);
      }
      // ignore: avoid_print
      print('R3 borde reloj real: consultas vigentes=$sawFresh cortadas=$sawCut');
      expect(sawFresh, greaterThan(0));
      expect(sawCut, greaterThan(0));
      await link.dispose();
    });

    test('reloj POR DEFECTO (Stopwatch interno), con calentamiento y márgenes: '
        '298 ms NO corta; 302 ms SÍ corta (20 repeticiones)', () async {
      final link = await _connected();
      await link.sendCommand(full(0));
      _cut(link); // calentamiento (JIT) del camino de consulta
      for (var i = 0; i < 20; i++) {
        await link.sendCommand(full(i));
        final sw = Stopwatch()..start(); // arranca DESPUÉS del registro
        _spinUntil(sw, 298000);
        expect(_cut(link), isFalse, reason: 'rep $i: cortó con ~298 ms');
        _spinUntil(sw, 302000);
        expect(_cut(link), isTrue, reason: 'rep $i: no cortó con ~302 ms');
        await Future<void>.delayed(Duration.zero);
      }
      await link.dispose();
    });

    test('sin espera activa (timers corriendo): a ~250 ms vigente, a ~320 ms cortado', () async {
      final link = await _connected();
      await link.sendCommand(full(1));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(_cut(link), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(_cut(link), isTrue);
      await link.dispose();
    });

    test('el timer de respaldo (espStaleTimerDelay) nunca dispara con antigüedad ≤ 300 ms '
        '(30 timers en fases sub-ms distintas)', () async {
      expect(SimulatedRobotLink.espStaleTimerDelay, const Duration(milliseconds: 301));
      final fired = <int>[];
      for (var i = 0; i < 30; i++) {
        // Cronómetro arrancado DESPUÉS de crear el timer → medido ≤ edad real.
        final sw = Stopwatch();
        Timer(SimulatedRobotLink.espStaleTimerDelay, () => fired.add(sw.elapsedMicroseconds));
        sw.start();
        // desfasar el próximo timer una fracción de ms
        final spin = Stopwatch()..start();
        while (spin.elapsedMicroseconds < (i * 37) % 1000) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 450));
      // ignore: avoid_print
      print('R3 timer de respaldo: disparos medidos en µs (cota inferior de la edad real) '
          'mín=${fired.reduce(math.min)} máx=${fired.reduce(math.max)}');
      expect(fired, hasLength(30));
      expect(fired.every((us) => us > 300000), isTrue, reason: '$fired');
    });

    test('(caracterización) con fake_async y SIN reloj inyectado: a 300,5 ms el comando '
        'sigue "vigente" (el Stopwatch real no avanza; corta el timer a los 301 ms)', () {
      // Documenta por qué existe el timer de respaldo. En el teléfono no pasa:
      // el Stopwatch avanza (ver los dos primeros tests de este grupo).
      fakeAsync((async) {
        final link = SimulatedRobotLink(on, connectDelay: Duration.zero);
        link.connect();
        async.elapse(Duration.zero);
        link.sendCommand(full(1));
        async.elapse(const Duration(microseconds: 300500));
        expect(_cut(link), isFalse, reason: 'artefacto de test documentado (AUD-16)');
        async.elapse(const Duration(microseconds: 500));
        expect(_cut(link), isTrue);
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('con fake_async y reloj INYECTADO (async.elapsed): 300 ms vale, 300 ms + 1 µs corta',
        () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(on,
            connectDelay: Duration.zero, monotonicClock: () => async.elapsed);
        link.connect();
        async.elapse(Duration.zero);
        link.sendCommand(full(1));
        async.elapse(const Duration(milliseconds: 300));
        expect(_cut(link), isFalse);
        async.elapse(const Duration(microseconds: 1));
        expect(_cut(link), isTrue);
        link.dispose();
        async.flushMicrotasks();
      });
    });
  });
  group('nombre de la app "Gramanova"', () {
    testWidgets('AppBar y MaterialApp.title muestran "Gramanova"; el nombre viejo no aparece',
        (tester) async {
      expect(Labels.appTitle, 'Gramanova');
      final link = RecordingLink();
      final c = SessionController(link: link, config: const AppConfig(toolsEnabled: false));
      await tester.pumpWidget(CortadoraApp(controller: c));
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.title, 'Gramanova');
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Gramanova')),
          findsOneWidget);
      expect(find.textContaining('Robot Cortadora E7'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await link.dispose();
    });
  });
}
