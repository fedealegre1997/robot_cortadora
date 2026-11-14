// Estructura principal: banner MODO SIMULADO arriba, pantalla actual en el
// medio y, abajo, el STOP grande (siempre visible en TODAS las pantallas)
// encima de la barra de navegación.

import 'package:flutter/material.dart';

import '../app/session_controller.dart';
import 'labels.dart';
import 'screens/connection_screen.dart';
import 'screens/control_screen.dart';
import 'widgets/simulated_banner.dart';
import 'widgets/stop_button.dart';

/// Una sección de la navegación. Para sumar la pantalla de mapa más adelante
/// alcanza con agregar una entrada a [appSections].
class AppSection {
  const AppSection({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function(SessionController controller) builder;
}

final List<AppSection> appSections = [
  AppSection(
    label: 'Conexión',
    icon: Icons.link_outlined,
    selectedIcon: Icons.link,
    builder: (c) => ConnectionScreen(controller: c),
  ),
  AppSection(
    label: 'Control',
    icon: Icons.gamepad_outlined,
    selectedIcon: Icons.gamepad,
    builder: (c) => ControlScreen(controller: c),
  ),
  // Futuro (no en esta APK): AppSection(label: 'Mapa', icon: Icons.map_outlined,
  //   selectedIcon: Icons.map, builder: (c) => MapScreen(controller: c)),
];

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final SessionController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _select(int i) {
    // Cambiar de pantalla nunca deja una dirección "apretada".
    widget.controller.releaseDirection();
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final section = appSections[_index];
    return Scaffold(
      appBar: AppBar(
        title: const Text(Labels.appTitle),
        centerTitle: false,
      ),
      // Arriba: el AppBar ya respeta la barra de estado. Costados: SafeArea
      // (recortes / horizontal). Abajo: NavigationBar respeta la barra de
      // navegación de Samsung, y el STOP va encima de ella, fuera del scroll.
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            if (c.isSimulated) const SimulatedBanner(),
            Expanded(child: section.builder(c)),
          ],
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            elevation: 8,
            child: SafeArea(
              top: false,
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: StopButton(controller: c),
              ),
            ),
          ),
          NavigationBar(
            height: 64,
            selectedIndex: _index,
            onDestinationSelected: _select,
            destinations: [
              for (final s in appSections)
                NavigationDestination(
                  icon: Icon(s.icon),
                  selectedIcon: Icon(s.selectedIcon),
                  label: s.label,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
