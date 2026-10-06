import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clankpad/models/editor_tab.dart';
import 'package:clankpad/screens/editor_screen.dart';
import 'package:clankpad/state/editor_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _root = 'C:/held/';

void main() {
  late _HeldWrites writes;

  setUp(() {
    writes = _HeldWrites();
    IOOverrides.global = writes;
  });
  tearDown(() => IOOverrides.global = null);

  testWidgets('save completion follows its tab when a preceding tab closes', (
    tester,
  ) async {
    final state = EditorState();
    final x = _openFile(state, 'x');
    final a = _openFile(state, 'a');
    final b = _openFile(state, 'b');
    a.controller.text = 'a saved';
    b.controller.text = 'b edited';
    state.switchTab(state.tabs.indexOf(a));
    await _pumpEditor(tester, state);

    await _pressCtrlS(tester);
    expect(writes.pending.single.path, '${_root}a.txt');
    expect(writes.pending.single.content, 'a saved');

    a.controller.text = 'a saved, then edited';
    state.forceCloseTab(state.tabs.indexOf(x));
    writes.completeAll();
    await tester.pump();

    expect(state.tabs, [a, b]);
    expect(a.savedContent, 'a saved');
    expect(a.isDirty, isTrue);
    _expectUntouched(b, 'b', isDirty: true);
    expect(find.text('Save failed'), findsNothing);
  });

  testWidgets('save completion does not touch a replacement at its old index', (
    tester,
  ) async {
    final state = EditorState();
    final a = _openFile(state, 'a');
    final b = _openFile(state, 'b');
    a.controller.text = 'a saved';
    state.switchTab(state.tabs.indexOf(a));
    await _pumpEditor(tester, state);

    await _pressCtrlS(tester);
    expect(writes.pending.single.path, '${_root}a.txt');

    state.forceCloseTab(state.tabs.indexOf(a));
    writes.completeAll();
    await tester.pump();

    expect(state.tabs, [b]);
    _expectUntouched(b, 'b', isDirty: false);
    expect(find.text('Save failed'), findsNothing);
  });
}

EditorTab _openFile(EditorState state, String name) {
  state.loadFileIntoTab('$_root$name.txt', '$name.txt', name);
  return state.activeTab;
}

void _expectUntouched(EditorTab tab, String name, {required bool isDirty}) {
  expect(tab.filePath, '$_root$name.txt');
  expect(tab.title, '$name.txt');
  expect(tab.savedContent, name);
  expect(tab.isDirty, isDirty);
}

Future<void> _pumpEditor(WidgetTester tester, EditorState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: EditorScreen(editorState: state, onExitRequested: () async {}),
    ),
  );
  await tester.pump();
}

Future<void> _pressCtrlS(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

// Holds writes under [_root] until the test completes them, so tab changes can
// happen while a save is pending. Other paths use the real file system.
final class _HeldWrites extends IOOverrides {
  final pending = <_HeldFile>[];

  void completeAll() {
    for (final file in pending) {
      file.done.complete(file);
    }
  }

  @override
  File createFile(String path) =>
      path.startsWith(_root) ? _HeldFile(path, this) : super.createFile(path);
}

class _HeldFile implements File {
  _HeldFile(this.path, this.writes);

  @override
  final String path;
  final _HeldWrites writes;
  final done = Completer<File>();
  String? content;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    content = contents;
    writes.pending.add(this);
    return done.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
