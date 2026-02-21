import 'dart:ui';

import 'package:flutter/material.dart';

import 'screens/editor_screen.dart';
import 'services/session_service.dart';
import 'state/editor_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Restore the previous session before the widget tree is built so there is
  // no flicker or loading state — the restored state is the initial state.
  final editorState = EditorState();
  final sessionJson = SessionService.readSession();
  if (sessionJson != null) {
    await editorState.restoreFromSession(sessionJson);
  }

  runApp(ClankpadApp(editorState: editorState));
}

class ClankpadApp extends StatefulWidget {
  final EditorState editorState;

  const ClankpadApp({super.key, required this.editorState});

  @override
  State<ClankpadApp> createState() => _ClankpadAppState();
}

class _ClankpadAppState extends State<ClankpadApp> {
  late final SessionService _sessionService;
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();

    // SessionService registers itself as onAnyChange on the EditorState.
    // It is created AFTER restore so restore-time mutations do not trigger
    // spurious debounced writes.
    _sessionService = SessionService(widget.editorState);

    // Flush the session synchronously when the OS requests app exit
    // (normal window close on Windows). Force-close (Task Manager, SIGKILL)
    // bypasses this; debounced writes already minimise the exposure window.
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        _sessionService.flushSync();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _sessionService.dispose();
    widget.editorState.dispose();
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
      home: EditorScreen(editorState: widget.editorState),
    );
  }
}
