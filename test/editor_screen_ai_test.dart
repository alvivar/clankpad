import 'dart:async';

import 'package:clankpad/screens/editor_screen.dart';
import 'package:clankpad/services/ai_provider.dart';
import 'package:clankpad/services/pi_provider.dart';
import 'package:clankpad/state/editor_state.dart';
import 'package:clankpad/widgets/ai_diff_view.dart';
import 'package:clankpad/widgets/ai_prompt_popup.dart';
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
}) async {
  final editorState = state ?? EditorState();
  if (state == null) editorState.activeTab.controller.text = text;
  final pi = _FakePi();
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

Future<void> _pressCtrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  await tester.pump();
}

Future<void> _submit(WidgetTester tester, String prompt) async {
  await _pressCtrlK(tester);
  final field = find.descendant(
    of: find.byType(AiPromptPopup),
    matching: find.byType(TextField),
  );
  await tester.enterText(field, prompt);
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

  @override
  Future<AiProviderModels> fetchModels() async => const AiProviderModels();

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
