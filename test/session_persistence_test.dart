import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:clankpad/main.dart';
import 'package:clankpad/services/session_service.dart';
import 'package:clankpad/state/editor_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  // A regular file where the session directory should be: every session
  // write fails until the test deletes it.
  late File blocker;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('clankpad_session_test');
    blocker = File('${temp.path}${Platform.pathSeparator}session')
      ..writeAsStringSync('');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  File sessionFile() =>
      File('${blocker.path}${Platform.pathSeparator}session.json');

  test('debounced write failure is reported until a write succeeds', () async {
    final state = EditorState();
    final service = SessionService(state, directory: Directory(blocker.path));
    addTearDown(service.dispose);

    state.activeTab.controller.text = 'unsaved';
    expect(await _nextError(state), isNotNull);

    blocker.deleteSync();
    state.activeTab.controller.text = 'unsaved, then edited';
    expect(await _nextError(state), isNull);
    expect(sessionFile().readAsStringSync(), contains('unsaved, then edited'));
  });

  test('flushSync reports failure and recovery', () {
    final state = EditorState();
    final service = SessionService(state, directory: Directory(blocker.path));
    addTearDown(service.dispose);
    state.activeTab.controller.text = 'unsaved';

    expect(service.flushSync(), isFalse);
    expect(state.sessionWriteError.value, isNotNull);

    blocker.deleteSync();
    expect(service.flushSync(), isTrue);
    expect(state.sessionWriteError.value, isNull);
    expect(sessionFile().readAsStringSync(), contains('unsaved'));
  });

  test('a write failing after dispose does not touch disposed state', () async {
    final writes = _HeldTmpWrites();
    IOOverrides.global = writes;
    addTearDown(() => IOOverrides.global = null);
    final state = EditorState();
    final service = SessionService(state, directory: temp);

    state.activeTab.controller.text = 'unsaved';
    final pending = await writes.started.future.timeout(
      const Duration(seconds: 5),
    );
    service.dispose();
    state.dispose();

    // Without the guard, the catch block would set the disposed notifier and
    // fail this test with an uncaught assertion.
    pending.completeError(const FileSystemException('held write failed'));
    await Future<void>.delayed(Duration.zero);
  });

  testWidgets('failed flush cancels window close and keeps unsaved tabs', (
    tester,
  ) async {
    final state = EditorState();
    state.activeTab.controller.text = 'unsaved';
    await tester.pumpWidget(
      ClankpadApp(
        editorState: state,
        sessionDirectory: Directory(blocker.path),
      ),
    );

    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    await tester.pump();
    expect(state.activeTab.controller.text, 'unsaved');
    expect(find.textContaining("Couldn't save the session"), findsOneWidget);

    blocker.deleteSync();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
    await tester.pump();
    expect(sessionFile().readAsStringSync(), contains('unsaved'));
    expect(find.textContaining("Couldn't save the session"), findsNothing);
  });

  // Only the failing case is exercised: a successful explicit exit calls
  // exit(0), which would end the test process.
  testWidgets('failed flush cancels last-tab exit and keeps the app usable', (
    tester,
  ) async {
    final state = EditorState();
    await tester.pumpWidget(
      ClankpadApp(
        editorState: state,
        sessionDirectory: Directory(blocker.path),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(state.tabs, hasLength(1));
    expect(find.textContaining("Couldn't save the session"), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'still editable');
    expect(state.activeTab.controller.text, 'still editable');
  });

  testWidgets('repeated failures keep one banner and no dialog', (
    tester,
  ) async {
    final state = EditorState();
    await tester.pumpWidget(
      ClankpadApp(
        editorState: state,
        sessionDirectory: Directory(blocker.path),
      ),
    );

    state.sessionWriteError.value = 'first failure';
    await tester.pump();
    state.sessionWriteError.value = 'second failure';
    await tester.pump();

    expect(find.textContaining("Couldn't save the session"), findsOneWidget);
    expect(find.textContaining('second failure'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });
}

Future<String?> _nextError(EditorState state) {
  final changed = Completer<String?>();
  void listener() {
    state.sessionWriteError.removeListener(listener);
    changed.complete(state.sessionWriteError.value);
  }

  state.sessionWriteError.addListener(listener);
  return changed.future.timeout(const Duration(seconds: 5));
}

// Holds the debounced write's per-generation tmp file so the test can finish
// it after disposal. Other files use the real file system.
final class _HeldTmpWrites extends IOOverrides {
  final started = Completer<Completer<File>>();

  @override
  File createFile(String path) => path.endsWith('.tmp')
      ? _HeldTmpFile(path, started)
      : super.createFile(path);
}

class _HeldTmpFile implements File {
  _HeldTmpFile(this.path, this.started);

  @override
  final String path;
  final Completer<Completer<File>> started;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    final done = Completer<File>();
    started.complete(done);
    return done.future;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async => this;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
