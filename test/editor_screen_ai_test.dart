import 'dart:async';

import 'package:clankpad/screens/editor_screen.dart';
import 'package:clankpad/services/ai_provider.dart';
import 'package:clankpad/services/pi_provider.dart';
import 'package:clankpad/state/editor_state.dart';
import 'package:clankpad/widgets/ai_diff_view.dart';
import 'package:clankpad/widgets/ai_prompt_popup.dart';
import 'package:clankpad/widgets/editor_area.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Ctrl+K cannot reopen while a request is loading', (
    tester,
  ) async {
    final pi = await _pumpEditor(tester);
    await _submit(tester, 'first');

    await _pressCtrlK(tester);

    expect(find.byType(AiPromptPopup), findsNothing);
    expect(pi.requests, hasLength(1));
    await pi.finishAll(tester);
  });

  testWidgets('duplicate popup submission before rebuild starts one request', (
    tester,
  ) async {
    final pi = await _pumpEditor(tester);
    await _pressCtrlK(tester);
    final popup = tester.widget<AiPromptPopup>(find.byType(AiPromptPopup));

    popup.onSubmit('first');
    popup.onSubmit('second');
    await tester.pump();

    expect(pi.requests, hasLength(1));
    pi.requests.single.add('owned output');
    await tester.pump();
    expect(find.byType(AiDiffView), findsOneWidget);
    expect(find.text('owned output'), findsOneWidget);
    await pi.finishAll(tester);
  });

  testWidgets('model fetch failure is shown, blocks submit and retries', (
    tester,
  ) async {
    final pi = await _pumpEditor(tester);
    pi.fetchErrors.add(const AiProviderError('enabledModels is broken.'));

    await _pressCtrlK(tester);
    expect(
      find.text(
        "Couldn't load Pi models: enabledModels is broken. "
        '— close the prompt with Esc, then press Ctrl+K to retry.',
      ),
      findsOneWidget,
    );
    await tester.enterText(_promptField, 'edit');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pi.requests, isEmpty);
    expect(find.byType(AiPromptPopup), findsOneWidget);

    // As the banner says: Ctrl+K alone does nothing while the prompt is open;
    // Esc, then Ctrl+K retries.
    await _pressCtrlK(tester);
    expect(pi.fetchCount, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await _submit(tester, 'edit');

    expect(pi.fetchCount, 2);
    expect(find.textContaining("Couldn't load Pi models"), findsNothing);
    expect(pi.requests, hasLength(1));
    expect(pi.lastModel, 'test/model');
    await pi.finishAll(tester);
  });

  testWidgets('a listed persisted model wins and the list stays cached', (
    tester,
  ) async {
    final state = EditorState()..activeTab.controller.text = 'original';
    state.setAiPrefs({
      'modelProvider': 'test',
      'modelId': 'c',
      'thinkingLevel': 'xhigh',
    });
    final pi = await _pumpEditor(tester, state: state, models: _threeModels);

    await _submit(tester, 'first');
    expect(pi.lastModel, 'test/c');
    expect(pi.lastThinkingLevel, 'high');
    await pi.finishAll(tester);
    await tester.tap(find.text('Reject  (Ctrl+Backspace)'));
    await tester.pump();

    // Reopening keeps the in-session choice instead of reseeding or refetching.
    await _pressCtrlK(tester);
    tester
        .widget<AiPromptPopup>(find.byType(AiPromptPopup))
        .onModelChanged('test', 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await _submit(tester, 'second');
    expect(pi.lastModel, 'test/a');
    expect(pi.fetchCount, 1);
    await pi.finishAll(tester);
  });

  testWidgets('an unlisted persisted model yields to Pi suggestion', (
    tester,
  ) async {
    final state = EditorState()..activeTab.controller.text = 'original';
    state.setAiPrefs({'modelProvider': 'gone', 'modelId': 'c'});
    final pi = await _pumpEditor(tester, state: state, models: _threeModels);

    await _submit(tester, 'edit');

    expect(pi.lastModel, 'test/b');
    expect(pi.lastThinkingLevel, 'low');
    await pi.finishAll(tester);
  });

  testWidgets('cancel blocks resubmit until the old request terminates', (
    tester,
  ) async {
    final pi = await _pumpEditor(tester);
    await _submit(tester, 'first');

    await tester.tap(find.text('Cancel  (Esc)'));
    await tester.pump();
    await _pressCtrlK(tester);

    expect(pi.abortCount, 1);
    expect(find.byType(AiPromptPopup), findsNothing);

    pi.requests.single.add('late old output');
    await _completeCancellation(tester);
    expect(find.byType(AiDiffView), findsNothing);

    await pi.finish(tester, 0);
    await _submit(tester, 'second');
    expect(pi.requests, hasLength(2));
    await pi.finishAll(tester);
  });

  for (final action in ['Reject  (Ctrl+Backspace)', 'Accept  (Ctrl+Enter)']) {
    testWidgets('$action during generation drains before the next request', (
      tester,
    ) async {
      final pi = await _pumpEditor(tester, text: 'old');
      await _submit(tester, 'first');
      pi.requests.single.add('partial');
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text(action));
      await tester.pump();
      await _pressCtrlK(tester);

      expect(pi.abortCount, 1);
      expect(find.byType(AiPromptPopup), findsNothing);
      final expectedText = action.startsWith('Accept') ? 'partial' : 'old';
      expect(_activeText(tester), expectedText);

      // The old subscription was released by the first late chunk.
      pi.requests.single.add(' stale');
      await _completeCancellation(tester);
      expect(find.byType(AiDiffView), findsNothing);
      expect(_activeText(tester), expectedText);

      await pi.finish(tester, 0);
      await _submit(tester, 'second');
      expect(pi.requests, hasLength(2));
      await pi.finishAll(tester);
    });
  }

  // Accept rebuilds the document from the snapshot taken when the prompt
  // opened, so any edit made while the prompt is open would be lost.
  testWidgets('the editor cannot be edited while the prompt is open', (
    tester,
  ) async {
    await _pumpEditor(tester, text: '');
    // Earlier edits give Ctrl+Z something to revert.
    for (final text in ['one\ntwo', 'one\ntwo\nsix']) {
      await tester.enterText(_editorField, text);
      await tester.pump(const Duration(seconds: 1));
    }
    const snapshot = 'one\ntwo\nsix';

    await _pressCtrlK(tester);
    await tester.tap(_editorField);
    await tester.pump();
    expect(find.byType(AiPromptPopup), findsOneWidget);
    expect(_editorFocusNode(tester).hasFocus, isTrue);

    tester.testTextInput.enterText('typed');
    await tester.pump();
    expect(_activeText(tester), snapshot, reason: 'typing');
    // One of the two directions moves a line whichever line the caret is on.
    await _sendShortcut(tester, LogicalKeyboardKey.arrowUp, alt: true);
    expect(_activeText(tester), snapshot, reason: 'Alt+Up');
    await _sendShortcut(tester, LogicalKeyboardKey.arrowDown, alt: true);
    expect(_activeText(tester), snapshot, reason: 'Alt+Down');
    await _sendShortcut(tester, LogicalKeyboardKey.keyJ, control: true);
    expect(_activeText(tester), snapshot, reason: 'Ctrl+J');
    await _sendShortcut(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(_activeText(tester), snapshot, reason: 'Ctrl+Z');
    // Bound to Ctrl+T on macOS; transposes the characters around the caret,
    // which the tap left after the text.
    expect(_editorController(tester).selection.baseOffset, snapshot.length);
    await _transposeCharacters(tester);
    expect(_activeText(tester), snapshot, reason: 'transpose');
    // Last: an unhandled Tab moves focus out of the read-only editor.
    await _sendShortcut(tester, LogicalKeyboardKey.tab);
    expect(_activeText(tester), snapshot, reason: 'Tab');

    // Esc from the popup closes it and returns focus to an editable editor.
    await tester.tap(_promptField);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(AiPromptPopup), findsNothing);
    expect(_editorFocusNode(tester).hasFocus, isTrue);
    tester.testTextInput.enterText('typed');
    await tester.pump();
    expect(_activeText(tester), 'typed');
    await _transposeCharacters(tester);
    expect(_activeText(tester), 'typde');
  });

  testWidgets('accept fails explicitly when the original tab is gone', (
    tester,
  ) async {
    final state = EditorState();
    state.activeTab.controller.text = 'original';
    final pi = await _pumpEditor(tester, state: state);
    await _submit(tester, 'replace');
    pi.requests.single.add('replacement');
    await tester.pump();
    await pi.finish(tester, 0);

    state.forceCloseTab(0);
    await tester.pump();
    await tester.tap(find.text('Accept  (Ctrl+Enter)'));
    await tester.pump();

    expect(state.tabs.single.controller.text, isEmpty);
    expect(
      find.text(
        'The original tab is no longer open. The AI edit was not applied.',
      ),
      findsOneWidget,
    );
    expect(find.byType(AiDiffView), findsNothing);
  });
}

Future<_FakePi> _pumpEditor(
  WidgetTester tester, {
  EditorState? state,
  String text = 'original',
  AiProviderModels? models,
}) async {
  final editorState = state ?? EditorState();
  if (state == null) editorState.activeTab.controller.text = text;
  final pi = _FakePi();
  if (models != null) pi.models = models;
  // Match a desktop window; the default test surface is narrower than the
  // diff's existing action-row layout.
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: EditorScreen(
        editorState: editorState,
        onExitRequested: () async {},
        piProvider: pi,
      ),
    ),
  );
  await tester.pump();
  return pi;
}

const _threeModels = AiProviderModels(
  models: [
    AiModel(provider: 'test', id: 'a', name: 'A'),
    AiModel(provider: 'test', id: 'b', name: 'B'),
    AiModel(provider: 'test', id: 'c', name: 'C'),
  ],
  suggestedProvider: 'test',
  suggestedModelId: 'b',
  suggestedThinkingLevel: 'minimal',
);

Future<void> _pressCtrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  await tester.pump();
}

final _promptField = find.descendant(
  of: find.byType(AiPromptPopup),
  matching: find.byType(TextField),
);

final _editorField = find.descendant(
  of: find.byType(EditorArea),
  matching: find.byType(TextField),
);

FocusNode _editorFocusNode(WidgetTester tester) =>
    tester.widget<TextField>(_editorField).focusNode!;

TextEditingController _editorController(WidgetTester tester) =>
    tester.widget<TextField>(_editorField).controller!;

// Dispatches the intent from the focused node, as a shortcut would.
Future<void> _transposeCharacters(WidgetTester tester) async {
  Actions.invoke(primaryFocus!.context!, const TransposeCharactersIntent());
  await tester.pump();
}

Future<void> _sendShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool alt = false,
  bool control = false,
}) async {
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pump();
}

Future<void> _submit(WidgetTester tester, String prompt) async {
  await _pressCtrlK(tester);
  await tester.enterText(_promptField, prompt);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

// Breaking an await-for cancels its subscription asynchronously; FakeAsync
// pumps do not complete that cancellation by themselves.
Future<void> _completeCancellation(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

String _activeText(WidgetTester tester) {
  final screen = tester.widget<EditorScreen>(find.byType(EditorScreen));
  return screen.editorState.activeTab.controller.text;
}

class _FakePi extends PiProvider {
  final requests = <StreamController<String>>[];
  var abortCount = 0;
  var fetchCount = 0;
  // Thrown by the next fetches, in order.
  final fetchErrors = <Object>[];
  var models = const AiProviderModels(
    models: [AiModel(provider: 'test', id: 'model', name: 'Model')],
  );
  // `provider/id` and thinking level of the last request.
  String? lastModel;
  String? lastThinkingLevel;

  @override
  Future<AiProviderModels> fetchModels() async {
    fetchCount++;
    if (fetchErrors.isNotEmpty) throw fetchErrors.removeAt(0);
    return models;
  }

  @override
  Stream<String> streamEdit({
    required String documentText,
    required String editTarget,
    required String userInstruction,
    String? modelProvider,
    String? modelId,
    String thinkingLevel = 'off',
    int? insertOffset,
  }) {
    lastModel = '$modelProvider/$modelId';
    lastThinkingLevel = thinkingLevel;
    final request = StreamController<String>();
    requests.add(request);
    return request.stream;
  }

  @override
  void abort() => abortCount++;

  // A cancelled stream may have no listener, so tests never await close().
  Future<void> finish(WidgetTester tester, int index) async {
    unawaited(requests[index].close());
    await tester.pump();
  }

  Future<void> finishAll(WidgetTester tester) async {
    _closeOpenRequests();
    await tester.pump();
  }

  @override
  Future<void> dispose() async => _closeOpenRequests();

  void _closeOpenRequests() {
    for (final request in requests) {
      if (!request.isClosed) unawaited(request.close());
    }
  }
}
