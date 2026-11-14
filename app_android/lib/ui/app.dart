import 'package:flutter/material.dart';

import '../app/session_controller.dart';
import 'home_shell.dart';
import 'labels.dart';
import 'theme.dart';

class CortadoraApp extends StatelessWidget {
  const CortadoraApp({super.key, required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Labels.appTitle,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: HomeShell(controller: controller),
    );
  }
}
