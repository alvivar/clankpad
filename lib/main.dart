import 'dart:io';
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

  Future<void> _exitApplication() async {
    _sessionService.flushSync();
    exit(0);
  }

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
        colorScheme: const ColorScheme(
          brightness: Brightness.dark,
          primary: Color(0xFF0078D4),
          onPrimary: Color(0xFFFFFFFF),
          primaryContainer: Color(0xFF264F78),
          onPrimaryContainer: Color(0xFFFFFFFF),
          secondary: Color(0xFF73C991),
          onSecondary: Color(0xFF181818),
          secondaryContainer: Color(0xFF23352B),
          onSecondaryContainer: Color(0xFFCCCCCC),
          tertiary: Color(0xFF9D9D9D),
          onTertiary: Color(0xFF181818),
          tertiaryContainer: Color(0xFF3A3D41),
          onTertiaryContainer: Color(0xFFCCCCCC),
          error: Color(0xFFF14C4C),
          onError: Color(0xFFFFFFFF),
          errorContainer: Color(0xFFFF0000),
          onErrorContainer: Color(0xFFCCCCCC),
          surface: Color(0xFF1F1F1F),
          onSurface: Color(0xFFCCCCCC),
          surfaceDim: Color(0xFF181818),
          surfaceBright: Color(0xFF313131),
          surfaceContainerLowest: Color(0xFF181818),
          surfaceContainerLow: Color(0xFF202020),
          surfaceContainer: Color(0xFF252526),
          surfaceContainerHigh: Color(0xFF252526),
          surfaceContainerHighest: Color(0xFF181818),
          onSurfaceVariant: Color(0xFF9D9D9D),
          outline: Color(0xFF454545),
          outlineVariant: Color(0xFF2B2B2B),
          shadow: Color(0xFF000000),
          scrim: Color(0xFF000000),
          inverseSurface: Color(0xFFCCCCCC),
          onInverseSurface: Color(0xFF1F1F1F),
          inversePrimary: Color(0xFF0078D4),
          // Elevated widgets stay neutral instead of picking up a blue tint.
          surfaceTint: Colors.transparent,
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Color(0xFFCCCCCC),
          selectionColor: Color(0xFF264F78),
          selectionHandleColor: Color(0xFF0078D4),
        ),
        useMaterial3: true,
      ),
      home: EditorScreen(
        editorState: widget.editorState,
        onExitRequested: _exitApplication,
      ),
    );
  }
}
