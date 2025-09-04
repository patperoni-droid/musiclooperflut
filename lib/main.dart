import 'package:flutter/material.dart';
import 'screens/player_screen.dart';
import 'screens/tuner_screen.dart';
import 'screens/metronome_screen.dart';
import 'screens/editor_screen.dart';

void main() {
  runApp(const MusicLooperApp());
}

class MusicLooperApp extends StatelessWidget {
  const MusicLooperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MusicLooper',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.orange,
        colorScheme: const ColorScheme.dark(primary: Colors.orange),
      ),
      home: const HomeTabs(),
    );
  }
}

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _index = 0;

  final List<Widget> _screens = const [
    PlayerScreen(),
    TunerScreen(),
    MetronomeScreen(),
    EditorScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline),
            selectedIcon: Icon(Icons.play_circle_filled),
            label: 'Lecture',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            label: 'Accordeur',
          ),
          NavigationDestination(
            icon: Icon(Icons.av_timer),
            label: 'Métronome',
          ),
          NavigationDestination(
            icon: Icon(Icons.edit),
            label: 'Éditeur',
          ),
        ],
      ),
    );
  }
}
