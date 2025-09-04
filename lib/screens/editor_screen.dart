import 'package:flutter/material.dart';

class EditorScreen extends StatelessWidget {
  const EditorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: Center(
        child: Text(
          'Écran Éditeur de boucles',
          style: TextStyle(fontSize: 20, color: Colors.orange),
        ),
      ),
    );
  }
}
