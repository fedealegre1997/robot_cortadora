// Pantalla de control manual: estado pedido, dirección con botones
// discretos (giro en modo "mantener" o "pulsos"), velocidad, herramientas y
// panel de lo pedido. El STOP grande está en el Scaffold principal.

import 'package:flutter/material.dart';

import '../../app/session_controller.dart';
import '../../core/control_command.dart';
import '../labels.dart';
import '../widgets/hold_button.dart';
import '../widgets/requested_panel.dart';

class ControlScreen extends StatelessWidget {
  const ControlScreen({super.key, required this.controller});

  final SessionController controller;

  static Key stateKey(RobotState s) => Key('state_${s.name}');
  static Key directionKey(Direction d) => Key('dir_${d.name}');
  static const cutterKey = Key('tool_cutter');
  static const trimmerKey = Key('tool_trimmer');
  static const turnModeKey = Key('turn_mode');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (!c.isConnected) ...[
              _Notice(
                icon: Icons.link_off,
                text: Labels.notConnected,
                color: Theme.of(context).colorScheme.errorContainer,
              ),
              const SizedBox(height: 12),
            ],
            _SectionTitle('Estado pedido'),
            _StateSelector(controller: c),
            const SizedBox(height: 8),
            _Notice(
              icon: Icons.map_outlined,
              text: Labels.autoNotice,
              color: Theme.of(context).colorScheme.secondaryContainer,
            ),
            const SizedBox(height: 16),
            _SectionTitle('Dirección (solo en MANUAL)'),
            _DirectionPad(controller: c),
            const SizedBox(height: 8),
            _TurnModeSelector(controller: c),
            const SizedBox(height: 16),
            _SpeedControl(controller: c),
            const SizedBox(height: 16),
            _ToolsSection(controller: c),
            const SizedBox(height: 16),
            RequestedPanel(controller: c),
          ],
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class _StateSelector extends StatelessWidget {
  const _StateSelector({required this.controller});
  final SessionController controller;

  Widget _option(BuildContext context, RobotState s) {
    final c = controller;
    final selected = c.state == s;
    // STOP siempre se puede pedir; el resto solo con enlace.
    final enabled = s == RobotState.stop || c.isConnected;
    final onPressed = enabled ? () => c.requestState(s) : null;
    // scaleDown: "AUTO_PAUSE" entra en 360 dp aun con texto grande.
    final child = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(Labels.state(s), maxLines: 1),
    );
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: selected
            ? FilledButton(
                key: ControlScreen.stateKey(s), onPressed: onPressed, child: child)
            : OutlinedButton(
                key: ControlScreen.stateKey(s), onPressed: onPressed, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Row(children: [
            _option(context, RobotState.stop),
            _option(context, RobotState.manual),
          ]),
          Row(children: [
            _option(context, RobotState.autoRun),
            _option(context, RobotState.autoPause),
          ]),
        ],
      );
}

const double _padButton = 96;
const double _padGap = 14;

class _DirectionPad extends StatelessWidget {
  const _DirectionPad({required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final enabled = c.isConnected && c.state == RobotState.manual;

    Widget hold(Direction d, IconData icon) => HoldButton(
          key: ControlScreen.directionKey(d),
          icon: icon,
          label: Labels.direction(d),
          active: c.dir == d,
          onPress: enabled ? () => c.pressDirection(d) : null,
          onRelease: c.releaseDirection,
        );

    Widget turn(Direction d, IconData icon) {
      if (c.turnMode == TurnMode.hold) return hold(d, icon);
      return HoldButton(
        key: ControlScreen.directionKey(d),
        icon: icon,
        label: '${Labels.direction(d)}\n(pulso)',
        active: c.dir == d,
        onPress: enabled ? () => c.pulseTurn(d) : null,
        // En modo pulso, el dir vuelve a 0 solo al terminar el pulso.
      );
    }

    // Cruz de 3×3 con botones de 96 dp y 14 dp de separación: entra en
    // 360 dp de ancho (96·3 + 14·2 = 316) y evita tocar dos a la vez.
    const gap = SizedBox(width: _padGap, height: _padGap);
    return Column(
      children: [
        hold(Direction.forward, Icons.arrow_upward),
        gap,
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            turn(Direction.left, Icons.rotate_left),
            gap,
            SizedBox(
              width: _padButton,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'pedido:\n${Labels.direction(c.dir)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            gap,
            turn(Direction.right, Icons.rotate_right),
          ],
        ),
        gap,
        hold(Direction.backward, Icons.arrow_downward),
        if (!enabled && c.isConnected)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Elegí MANUAL para pedir dirección. '
                'Fuera de MANUAL la app envía dir = 0.'),
          ),
      ],
    );
  }
}

class _TurnModeSelector extends StatelessWidget {
  const _TurnModeSelector({required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final pulseMs = controller.pulseDuration.inMilliseconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Modo de giro', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        SegmentedButton<TurnMode>(
          key: ControlScreen.turnModeKey,
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: TurnMode.hold,
              label: FittedBox(fit: BoxFit.scaleDown, child: Text('Mantener')),
            ),
            ButtonSegment(
              value: TurnMode.pulse,
              label: FittedBox(fit: BoxFit.scaleDown, child: Text('Pulsos')),
            ),
          ],
          selected: {controller.turnMode},
          onSelectionChanged: (s) => controller.setTurnMode(s.first),
        ),
        const SizedBox(height: 4),
        Text(
          '${Labels.turnNotice} Pulso: $pulseMs ms (valor provisional).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _SpeedControl extends StatelessWidget {
  const _SpeedControl({required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final speed = c.selectedSpeed;
    final enabled = c.isConnected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('Velocidad pedida: $speed %'),
        Row(
          children: [
            IconButton.filledTonal(
              iconSize: 32,
              tooltip: 'Bajar 10 %',
              onPressed:
                  enabled && speed > 0 ? () => c.setSpeed((speed - 10).clamp(0, 100)) : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Slider(
                value: speed.toDouble(),
                min: 0,
                max: 100,
                divisions: 20,
                label: '$speed %',
                onChanged: enabled ? (v) => c.setSpeed(v.round()) : null,
              ),
            ),
            IconButton.filledTonal(
              iconSize: 32,
              tooltip: 'Subir 10 %',
              onPressed: enabled && speed < 100
                  ? () => c.setSpeed((speed + 10).clamp(0, 100))
                  : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        if (c.state == RobotState.stop)
          const Text('En STOP la app envía speed = 0.'),
      ],
    );
  }
}

class _ToolsSection extends StatelessWidget {
  const _ToolsSection({required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final canRequest =
        c.toolsEnabled && c.isConnected && c.state != RobotState.stop;

    Widget tool(Key key, String name, IconData icon, bool on,
        ValueChanged<bool> set) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: on
              ? FilledButton.icon(
                  key: key,
                  onPressed: canRequest ? () => set(false) : null,
                  icon: Icon(icon),
                  label: Text('$name: pedida'),
                )
              : OutlinedButton.icon(
                  key: key,
                  onPressed: canRequest ? () => set(true) : null,
                  icon: Icon(icon),
                  label: Text(name),
                ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Herramientas'),
        Row(
          children: [
            tool(ControlScreen.cutterKey, 'Cortadora', Icons.content_cut,
                c.cutter, c.setCutter),
            tool(ControlScreen.trimmerKey, 'Bordeadora', Icons.grass,
                c.trimmer, c.setTrimmer),
          ],
        ),
        if (!c.toolsEnabled)
          _Notice(
            icon: Icons.lock,
            text: Labels.toolsLocked,
            color: Theme.of(context).colorScheme.errorContainer,
          )
        else if (c.state == RobotState.stop)
          const Text('En STOP las herramientas se piden apagadas.'),
      ],
    );
  }
}
