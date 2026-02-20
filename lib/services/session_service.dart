import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../state/editor_state.dart';

class SessionService {
  final EditorState _state;
  Timer? _debounce;

  late final File _sessionFile;
  late final File _tmpFile;

  SessionService(this._state) {
    final dir = sessionDirectory();
    final sep = Platform.pathSeparator;
    _sessionFile = File('${dir.path}${sep}session.json');
    _tmpFile = File('${dir.path}${sep}session.json.tmp');

    // Hook into EditorState: every text edit or structural change schedules a
    // debounced write. onAnyChange is null during restore (SessionService is
    // created after restore completes), so no spurious writes at startup.
    _state.onAnyChange = _schedule;
  }

  // ── Session directory ────────────────────────────────────────────────────────

  // %APPDATA%\Clankpad on Windows; current directory as fallback.
  static Directory sessionDirectory() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        return Directory('$appData${Platform.pathSeparator}Clankpad');
      }
    }
    return Directory('.');
  }

  // ── Read (called once at startup, before SessionService is constructed) ──────

  // Returns the parsed session.json contents, or null if no file exists or
  // the file cannot be parsed. Errors are logged to debugPrint and swallowed
  // so a corrupt session file never prevents the app from starting.
  static Map<String, dynamic>? readSession() {
    final dir = sessionDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}session.json');

    if (!file.existsSync()) return null;

    try {
      final raw = file.readAsStringSync();
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Session read failed: $e');
      return null;
    }
  }

  // ── Debounced write ──────────────────────────────────────────────────────────

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _write);
  }

  void _write() {
    try {
      // Ensure the session directory exists.
      final dir = _sessionFile.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Write to .tmp then atomically rename to .json.
      // On NTFS, rename is atomic — a crash mid-write leaves the previous
      // session.json intact.
      _tmpFile.writeAsStringSync(_buildJson());
      _tmpFile.renameSync(_sessionFile.path);
    } catch (e) {
      // Session write errors must never crash the app.
      debugPrint('Session write failed: $e');
    }
  }

  // ── Synchronous flush on exit ────────────────────────────────────────────────

  // Called from AppLifecycleListener.onExitRequested.
  // Cancels the pending debounce timer and writes synchronously so no changes
  // are lost when the window is closed within the 500 ms debounce window.
  void flushSync() {
    _debounce?.cancel();
    _debounce = null;
    _write();
  }

  // ── JSON serialisation ───────────────────────────────────────────────────────

  String _buildJson() {
    final tabsJson = _state.tabs.map((tab) {
      final m = <String, dynamic>{
        'id': tab.id,
        'title': tab.title,
        'filePath': tab.filePath, // null for untitled tabs; JSON null is fine
      };

      if (tab.filePath == null) {
        // Untitled tab: always store content and savedContent.
        m['content'] = tab.controller.text;
        m['savedContent'] = tab.savedContent;
      } else if (tab.isDirty) {
        // Dirty file-backed tab: store both to preserve unsaved edits.
        m['content'] = tab.controller.text;
        m['savedContent'] = tab.savedContent;
      }
      // Clean file-backed tab: omit both keys entirely.
      // Absence of the 'content' key is the restore signal to re-read from disk.

      return m;
    }).toList();

    return jsonEncode({
      'activeTabIndex': _state.activeTabIndex,
      'nextTabId': _state.nextTabId,
      'untitledCounter': _state.untitledCounter,
      'tabs': tabsJson,
    });
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  void dispose() {
    _debounce?.cancel();
    _state.onAnyChange = null;
  }
}
