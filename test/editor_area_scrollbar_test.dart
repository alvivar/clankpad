import 'package:clankpad/models/editor_tab.dart';
import 'package:clankpad/widgets/editor_area.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

Future<EditorTab> _pumpEditor(WidgetTester tester, String text) async {
  final tab = EditorTab(id: 1, title: 'doc', initialContent: text);
  final focusNode = FocusNode();
  addTearDown(tab.dispose);
  addTearDown(focusNode.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EditorArea(tab: tab, focusNode: focusNode),
      ),
    ),
  );
  await tester.pump(); // the scrollbar receives its metrics after a frame
  return tab;
}

MouseCursor? _cursor() =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

/// Hovers [position], lets the scrollbar fade in, then moves again so the
/// cursor is resolved against the visible scrollbar.
Future<void> _hover(
  TestGesture mouse,
  WidgetTester tester,
  Offset position,
) async {
  await mouse.moveTo(position);
  await tester.pump(); // starts the fade-in
  await tester.pump(const Duration(milliseconds: 500));
  await mouse.moveTo(position + const Offset(0, 1));
  await tester.pump();
}

void main() {
  final longText = List.filled(200, 'word ' * 30).join('\n');

  testWidgets('the scrollbar shows the arrow; the text keeps the I-beam', (
    tester,
  ) async {
    final tab = await _pumpEditor(tester, longText);
    final bar = tester.getRect(find.byType(Scrollbar));
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    await mouse.addPointer(location: bar.center);
    addTearDown(mouse.removePointer);

    final thumb = Offset(bar.right - 4, bar.top + 10);
    final track = Offset(bar.right - 4, bar.bottom - 10);
    final text = Offset(bar.right - 30, bar.top + 10);
    await _hover(mouse, tester, thumb);
    expect(_cursor(), SystemMouseCursors.basic);
    await _hover(mouse, tester, track);
    expect(_cursor(), SystemMouseCursors.basic);
    await _hover(mouse, tester, text);
    expect(_cursor(), SystemMouseCursors.text);

    // Dragging the thumb scrolls with each move (a track click would not)
    // without touching the text or selection.
    final before = tab.controller.value;
    await _hover(mouse, tester, thumb);
    await mouse.down(thumb);
    await mouse.moveBy(const Offset(0, 50));
    await tester.pump();
    final halfway = tab.scrollController.offset;
    await mouse.moveBy(const Offset(0, 50));
    await mouse.up();
    await tester.pump();
    expect(halfway, greaterThan(0));
    expect(tab.scrollController.offset, greaterThan(halfway));
    expect(tab.controller.value, before);

    // Dragging over text near the right edge still selects.
    await mouse.down(text);
    await mouse.moveBy(const Offset(0, 60));
    await mouse.up();
    await tester.pump();
    expect(tab.controller.selection.isCollapsed, isFalse);
    expect(tab.controller.text, longText);
  }, variant: _windows);

  testWidgets('a short document keeps the I-beam where a bar would be', (
    tester,
  ) async {
    await _pumpEditor(tester, 'short');
    final bar = tester.getRect(find.byType(Scrollbar));
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    await mouse.addPointer(location: bar.center);
    addTearDown(mouse.removePointer);

    await _hover(mouse, tester, Offset(bar.right - 4, bar.top + 10));
    expect(_cursor(), SystemMouseCursors.text);
  }, variant: _windows);
}
