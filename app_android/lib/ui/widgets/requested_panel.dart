// Panel "Lo que la app está pidiendo".
//
// Muestra SOLO lo pedido (lo que viaja en el comando) y las pocas cosas que
// el ESP devuelve (ACK de recepción, GPS, POK/PERR). Nunca muestra estado
// del robot, motores, velocidad real ni "cortando": la app no lo recibe.

import 'package:flutter/material.dart';

import '../../app/session_controller.dart';
import '../../core/app_config.dart';
import '../../core/robot_link.dart';
import '../labels.dart';

class RequestedPanel extends StatelessWidget {
  const RequestedPanel({super.key, required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final period = AppConfig.heartbeatPeriod.inMilliseconds;
    final hz = c.heartbeatHz.toStringAsFixed(0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(Labels.requestedTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      color: theme.colorScheme.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      Labels.requestedLegend,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _row('Estado pedido (state)',
                '${Labels.state(c.state)} (${c.state.code})'),
            _row('Dirección pedida (dir)',
                '${Labels.direction(c.dir)} (${c.dir.code})'),
            _row('Velocidad pedida (speed)', '${c.outgoingSpeed} %'),
            _row('Cortadora pedida (cutter)', c.cutter ? '1' : '0'),
            _row('Bordeadora pedida (trimmer)', c.trimmer ? '1' : '0'),
            _row(
              'Heartbeat',
              c.heartbeatActive
                  ? '$hz Hz (cada $period ms) · enviando'
                  : '$hz Hz (cada $period ms) · detenido, sin conexión',
            ),
            // Lo único que se refresca a 10 Hz: estas dos filas.
            ValueListenableBuilder<int>(
              valueListenable: c.sendTicks,
              builder: (context, sent, _) => Column(
                children: [
                  _row('Último seq enviado',
                      c.lastSentSeq?.toString() ?? '—'),
                  _row('Comandos enviados', '$sent'),
                ],
              ),
            ),
            const Divider(height: 20),
            Text('Lo único que devuelve el ESP',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            _row(
              'ACK',
              c.lastAckSeq == null
                  ? 'sin ACK'
                  : 'seq ${c.lastAckSeq}: ${Labels.ackMeaning} '
                      '(no significa ejecutado)',
            ),
            _row(_gpsTitle(c.lastGps), _gpsText(c.lastGps)),
            _row('Área', _areaText(c.lastAreaResponse)),
            if (c.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  c.lastError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: Text(label)),
          Expanded(
            flex: 6,
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  static String _gpsTitle(GpsFix? gps) =>
      gps != null && gps.simulated ? 'GPS (simulado)' : 'GPS';

  static String _gpsText(GpsFix? gps) {
    if (gps == null) return 'sin datos';
    if (gps.lat == null || gps.lon == null) return 'sin fix';
    final parts = <String>[
      '${gps.lat!.toStringAsFixed(6)}, ${gps.lon!.toStringAsFixed(6)}',
      if (gps.fixQuality != null) 'fix ${gps.fixQuality}',
      if (gps.satellites != null) '${gps.satellites} sat',
      if (gps.hdop != null) 'HDOP ${gps.hdop!.toStringAsFixed(1)}',
    ];
    return parts.join(' · ');
  }

  static String _areaText(RobotMessage? m) => switch (m) {
        PolygonAccepted(:final id) => 'POK: el ESP informó área aceptada (id $id)',
        PolygonRejected(:final id, :final reason) =>
          'PERR: el ESP informó área rechazada'
              '${id != null ? ' (id $id)' : ''}'
              '${reason != null ? ': $reason' : ''}',
        _ => 'sin respuesta (esta APK no envía áreas)',
      };
}
