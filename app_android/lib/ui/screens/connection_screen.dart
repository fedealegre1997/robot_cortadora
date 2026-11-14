// Pantalla de conexión: tipo de robot (simulado activo, BLE real
// deshabilitado hasta que exista el firmware BLE del ESP) y estado del enlace.

import 'package:flutter/material.dart';

import '../../app/session_controller.dart';
import '../../core/robot_link.dart';
import '../labels.dart';

class ConnectionScreen extends StatelessWidget {
  const ConnectionScreen({super.key, required this.controller});

  final SessionController controller;

  static const simulatedOptionKey = Key('option_simulated');
  static const bleOptionKey = Key('option_ble');
  static const connectKey = Key('connect_button');
  static const disconnectKey = Key('disconnect_button');
  static const statusKey = Key('link_status');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final theme = Theme.of(context);
        final status = c.linkStatus;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: _statusColor(theme.colorScheme, status),
              child: ListTile(
                key: statusKey,
                leading: Icon(_statusIcon(status), size: 36),
                title: Text(
                  'Enlace: ${Labels.linkStatus(status)}',
                  style: theme.textTheme.titleLarge,
                ),
                subtitle: const Text(
                  'Estado del enlace con el ESP (no es el estado del robot).',
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Robot', style: theme.textTheme.titleMedium),
            Card(
              child: Column(
                children: [
                  ListTile(
                    key: simulatedOptionKey,
                    enabled: true,
                    selected: c.isSimulated,
                    leading: Icon(c.isSimulated
                        ? Icons.check_circle
                        : Icons.circle_outlined),
                    title: const Text('Robot simulado'),
                    subtitle: const Text(
                        'Para probar la app sin robot. Opción activa.'),
                  ),
                  const Divider(height: 1),
                  const ListTile(
                    key: bleOptionKey,
                    enabled: false,
                    leading: Icon(Icons.bluetooth_disabled),
                    title: Text('Robot real (BLE)'),
                    subtitle: Text('Deshabilitado: ${Labels.blePending}.'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: connectKey,
                    onPressed: status == LinkStatus.disconnected
                        ? c.connect
                        : null,
                    icon: const Icon(Icons.link),
                    label: const Text('Conectar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: disconnectKey,
                    onPressed: status == LinkStatus.disconnected
                        ? null
                        : c.disconnect,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Desconectar'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Al conectar, la app arranca siempre en STOP y envía comandos a '
              '10 Hz. Al desconectar, primero envía STOP. Si la app pasa a '
              'segundo plano, pide STOP.',
            ),
            if (c.lastError != null) ...[
              const SizedBox(height: 8),
              Text(c.lastError!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        );
      },
    );
  }

  static IconData _statusIcon(LinkStatus s) => switch (s) {
        LinkStatus.disconnected => Icons.link_off,
        LinkStatus.connecting => Icons.sync,
        LinkStatus.connected => Icons.link,
      };

  static Color _statusColor(ColorScheme scheme, LinkStatus s) => switch (s) {
        LinkStatus.disconnected => scheme.errorContainer,
        LinkStatus.connecting => scheme.secondaryContainer,
        LinkStatus.connected => scheme.primaryContainer,
      };
}
