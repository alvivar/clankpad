import 'package:clankpad/screens/editor_screen.dart';
import 'package:clankpad/state/editor_state.dart';
import 'package:clankpad/widgets/editor_tab_item.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dragging reorders tabs; clicks still select and close', (
    tester,
  ) async {
    final state = EditorState()
      ..newTab()
      ..newTab()
      ..switchTab(1);
    final [one, two, three] = state.tabs;
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(editorState: state, onExitRequested: () async {}),
      ),
    );
    await tester.pump();

    await _dragTab(tester, 'Untitled 1', 300);
    expect(state.tabs, [two, three, one]);
    expect(state.activeTab, two, reason: 'dragging does not select');

    await tester.tap(find.text('Untitled 3'));
    await tester.pump();
    expect(state.activeTab, three);

    await tester.tap(_closeButton('Untitled 1'));
    await tester.pumpAndSettle();
    expect(state.tabs, [two, three]);

    await tester.tap(find.text('Untitled 2'), buttons: kMiddleMouseButton);
    await tester.pumpAndSettle();
    expect(state.tabs, [three]);
  });
}

/// Drags the tab titled [title] horizontally by [dx] with the mouse.
Future<void> _dragTab(WidgetTester tester, String title, double dx) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text(title)),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  for (var i = 0; i < 2; i++) {
    await gesture.moveBy(Offset(dx / 2, 0));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

Finder _closeButton(String title) => find.descendant(
  of: find.widgetWithText(EditorTabItem, title),
  matching: find.byTooltip('Close tab'),
);
