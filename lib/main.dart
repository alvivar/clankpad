import 'package:flutter/material.dart';

import 'screens/editor_screen.dart';
import 'state/editor_state.dart';

void main() {
  runApp(const ClankpadApp());
}

class ClankpadApp extends StatefulWidget {
  const ClankpadApp({super.key});

  @override
  State<ClankpadApp> createState() => _ClankpadAppState();
}

class _ClankpadAppState extends State<ClankpadApp> {
  late final EditorState _editorState;

  @override
  void initState() {
    super.initState();
    _editorState = EditorState();
  }

  @override
  void dispose() {
    _editorState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clankpad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: EditorScreen(editorState: _editorState),
    );
  }
}
