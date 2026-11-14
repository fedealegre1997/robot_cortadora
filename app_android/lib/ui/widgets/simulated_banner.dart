// Banner permanente "MODO SIMULADO" (se muestra en todas las pantallas
// mientras el enlace sea el robot simulado).

import 'package:flutter/material.dart';

import '../labels.dart';
import '../theme.dart';

class SimulatedBanner extends StatelessWidget {
  const SimulatedBanner({super.key});

  static const bannerKey = Key('simulated_banner');

  @override
  Widget build(BuildContext context) {
    return Material(
      key: bannerKey,
      color: kSimulatedAmber,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.science, color: Colors.black),
            SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    Labels.simulatedBanner,
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  Text(
                    Labels.simulatedBannerDetail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.black, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
