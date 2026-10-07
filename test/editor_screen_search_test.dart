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

  testWidgets('Find scrolls to a Markdown heading below the viewport', (
    tester,
  ) async {
    final state = EditorState();
    final controller = state.activeTab.controller;
    controller.text = [
      for (var i = 0; i < 80; i++) 'line $i',
      '# Target **heading**',
      'after `code` target',
    ].join('\n');
    await _pumpEditor(tester, state);
    await _find(tester, 'target');
    await tester.pump(const Duration(milliseconds: 200));

    final text = controller.text;
    final heading = text.indexOf('Target');
    final after = text.indexOf('after');
    expect(controller.selection, TextSelection.collapsed(offset: heading));
    expect(_highlights(tester, controller), [
      (heading, heading + 6),
      (text.length - 6, text.length),
    ]);

    final editable = find.byType(EditableText).last;
    final render = tester.state<EditableTextState>(editable).renderEditable;
    expect(state.activeTab.scrollController.offset, greaterThan(0));
    final caret = render.getLocalRectForCaret(TextPosition(offset: heading));
    expect(
      tester.getRect(editable).contains(render.localToGlobal(caret.center)),
      isTrue,
    );

    // Body lines keep their height (rounded to whole pixels); the heading
    // line is taller.
    double top(int offset) => render
        .getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: offset + 1),
        )
        .single
        .top;
    final bodyLine =
        top(text.indexOf('line 79')) - top(text.indexOf('line 78'));
    expect(bodyLine, moreOrLessEquals(14 * 1.6, epsilon: 0.5));
    expect(
      top(after) - top(text.indexOf('line 79')),
      greaterThan(2 * bodyLine + 1),
    );
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

// Ranges painted with a Find match background, merged across the pieces
// Markdown styling splits them into. Adjacent matches would merge.
List<(int, int)> _highlights(
  WidgetTester tester,
  HighlightingController controller,
) {
  final context = tester.element(find.byType(EditorScreen));
  final scheme = Theme.of(context).colorScheme;
  final findColors = {
    scheme.primaryContainer,
    scheme.primary.withValues(alpha: 0.35),
  };
  final span = controller.buildTextSpan(context: context, withComposing: false);
  final ranges = <(int, int)>[];
  var offset = 0;
  span.visitChildren((child) {
    final length = (child as TextSpan).text?.length ?? 0;
    if (length > 0 && findColors.contains(child.style?.backgroundColor)) {
      if (ranges.isNotEmpty && ranges.last.$2 == offset) {
        ranges.last = (ranges.last.$1, offset + length);
      } else {
        ranges.add((offset, offset + length));
      }
    }
    offset += length;
    return true;
  });
  return ranges;
}
