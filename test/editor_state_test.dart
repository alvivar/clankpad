import 'package:clankpad/models/editor_tab.dart';
import 'package:clankpad/state/editor_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('moveTab keeps the active tab by identity', () {
    late EditorState state;
    late EditorTab a, b, c;
    var changes = 0;

    setUp(() {
      state = EditorState()
        ..newTab()
        ..newTab();
      [a, b, c] = state.tabs;
      changes = 0;
      state.addListener(() => changes++);
    });
    tearDown(() => state.dispose());

    test('when the active tab moves', () {
      state.switchTab(0);
      changes = 0;

      state.moveTab(0, 2);

      expect(state.tabs, [b, c, a]);
      expect(state.activeTab, a);
      expect(state.activeTabIndex, 2);
      expect(changes, 1);
    });

    test('when another tab moves forward across it', () {
      state.switchTab(1);
      changes = 0;

      state.moveTab(0, 2);

      expect(state.tabs, [b, c, a]);
      expect(state.activeTab, b);
      expect(state.activeTabIndex, 0);
      expect(changes, 1);
    });

    test('when another tab moves backward across it', () {
      state.switchTab(1);
      changes = 0;

      state.moveTab(2, 0);

      expect(state.tabs, [c, a, b]);
      expect(state.activeTab, b);
      expect(state.activeTabIndex, 2);
      expect(changes, 1);
    });
  });
}
