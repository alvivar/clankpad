import 'package:clankpad/models/editor_tab.dart';
import 'package:clankpad/screens/editor_screen.dart';
import 'package:clankpad/state/editor_state.dart';
import 'package:clankpad/widgets/find_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('document edits refresh matches, highlights and navigation', (
    tester,
  ) async {
    final state = EditorState();
    final controller = state.activeTab.controller;
    controller.text = 'cat dog cat bird cat';
    await _pumpEditor(tester, state);
    await _find(tester, 'cat');
    expect(_findBar(tester).matchCount, 3);

    // Type in the document while Find stays open.
    final editor = find.byType(EditableText).last;
    await tester.tap(editor);
    await tester.pump();
    final editorFocus = tester.widget<EditableText>(editor).focusNode;
    controller.value = const TextEditingValue(
      text: 'xx cat dog cat bird cat',
      selection: TextSelection.collapsed(offset: 2),
    );
    await tester.pump();
    await tester.pump();

    expect(_findBar(tester).matchCount, 3);
    expect(_highlights(tester, controller), [(3, 6), (11, 14), (20, 23)]);
    expect(controller.selection, const TextSelection.collapsed(offset: 2));
    expect(editorFocus.hasPrimaryFocus, isTrue);

    // Remove the middle match.
    controller.value = const TextEditingValue(
      text: 'xx cat dog  bird cat',
      selection: TextSelection.collapsed(offset: 11),
    );
    await tester.pump();

    expect(_findBar(tester).matchCount, 2);
    expect(_highlights(tester, controller), [(3, 6), (17, 20)]);
    expect(controller.selection, const TextSelection.collapsed(offset: 11));

    _findBar(tester).onNext();
    await tester.pump();
    expect(controller.selection.baseOffset, 17);
    _findBar(tester).onNext();
    await tester.pump();
    expect(controller.selection.baseOffset, 3);
  });

  testWidgets('search follows the active tab and survives tab close', (
    tester,
  ) async {
    final state = EditorState();
    final first = state.activeTab.controller..text = 'cat cat';
    state.newTab();
    state.activeTab.controller.text = 'cat';
    await _pumpEditor(tester, state);
    await _find(tester, 'cat');
    expect(_findBar(tester).matchCount, 1);

    // The inactive tab's edits are not searched.
    first.text = 'cat cat cat';
    await tester.pump();
    expect(_findBar(tester).matchCount, 1);

    // Closing the active tab moves the search to the remaining tab.
    state.forceCloseTab(1);
    await tester.pump();
    await tester.pump();
    expect(_findBar(tester).matchCount, 3);

    first.text = 'cat';
    await tester.pump();
    expect(_findBar(tester).matchCount, 1);

    // Closing Find stops watching; unmounting with Find open must not throw.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(FindBar), findsNothing);
    first.text = 'cat cat';
    await tester.pump();
    expect(_highlights(tester, first), isEmpty);

    await _find(tester, 'cat');
    await tester.pumpWidget(const SizedBox());
    first.text = 'cat cat cat';
  });
}

Future<void> _pumpEditor(WidgetTester tester, EditorState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: EditorScreen(editorState: state, onExitRequested: () async {}),
    ),
  );
  await tester.pump();
}

Future<void> _find(WidgetTester tester, String query) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  await tester.enterText(
    find.descendant(of: find.byType(FindBar), matching: find.byType(TextField)),
    query,
  );
  await tester.pump();
  await tester.pump();
}

FindBar _findBar(WidgetTester tester) =>
    tester.widget<FindBar>(find.byType(FindBar));

// Ranges painted with a background color, as rendered by the controller.
List<(int, int)> _highlights(
  WidgetTester tester,
  HighlightingController controller,
) {
  final span = controller.buildTextSpan(
    context: tester.element(find.byType(EditorScreen)),
    withComposing: false,
  );
  final ranges = <(int, int)>[];
  var offset = 0;
  for (final child in span.children ?? const <InlineSpan>[]) {
    final text = (child as TextSpan).text!;
    if (child.style?.backgroundColor != null) {
      ranges.add((offset, offset + text.length));
    }
    offset += text.length;
  }
  return ranges;
}
