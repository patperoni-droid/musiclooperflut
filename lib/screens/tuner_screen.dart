import 'package:flutter/material.dart';

class TunerScreen extends StatelessWidget {
  const TunerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: Center(
        child: Text(
          'Écran Accordeur',
          style: TextStyle(fontSize: 20, color: Colors.orange),
        ),
      ),
    );
  }
}
