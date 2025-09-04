import 'package:flutter/material.dart';

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: Center(
        child: Text(
          'Écran Player (vidéo/audio)',
          style: TextStyle(fontSize: 20, color: Colors.orange),
        ),
      ),
    );
  }
}
