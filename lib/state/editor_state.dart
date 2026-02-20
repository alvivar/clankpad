import 'package:flutter/widgets.dart';

import '../models/editor_tab.dart';

class EditorState extends ChangeNotifier {
  final List<EditorTab> _tabs = [];

  int _activeTabIndex = 0;

  // Ever-incrementing. Never reset or reused — survives tab closes.
  // Persisted in session.json (Phase 3).
  int _nextTabId = 0;

  // Ever-incrementing counter for "Untitled N" titles.
  // Never reused — closing "Untitled 2" and opening a new tab gives "Untitled 3".
  // Persisted in session.json (Phase 3).
  int _untitledCounter = 0;

  List<EditorTab> get tabs => List.unmodifiable(_tabs);
  int get activeTabIndex => _activeTabIndex;
  EditorTab get activeTab => _tabs[_activeTabIndex];

  EditorState() {
    _addUntitledTab();
  }

  // Creates a new EditorTab and wires the controller → isDirtyNotifier listener.
  // Does NOT call notifyListeners — callers are responsible for that.
  EditorTab _buildTab({
    String? filePath,
    required String title,
    String initialContent = '',
    String savedContent = '',
  }) {
    final tab = EditorTab(
      id: _nextTabId++,
      filePath: filePath,
      title: title,
      savedContent: savedContent,
      initialContent: initialContent,
    );

    // Update dirty indicator on every keystroke.
    // Deliberately does NOT call notifyListeners() — that would rebuild the
    // entire tab bar on every keystroke. Only the tab chip listens to isDirtyNotifier.
    tab.controller.addListener(() {
      tab.isDirtyNotifier.value = tab.controller.text != tab.savedContent;
    });

    return tab;
  }

  // Appends a fresh untitled tab and makes it active.
  // Does NOT call notifyListeners — callers decide when to notify.
  void _addUntitledTab() {
    _untitledCounter++;
    final tab = _buildTab(title: 'Untitled $_untitledCounter');
    _tabs.add(tab);
    _activeTabIndex = _tabs.length - 1;
  }

  // Public: create a new empty tab (Ctrl+N / + button).
  void newTab() {
    _addUntitledTab();
    notifyListeners();
  }

  // Public: remove the tab at [index].
  // The dirty-check dialog is handled in the UI layer before calling this.
  // Enforces the "at least one tab" invariant by creating a fresh tab if needed.
  void forceCloseTab(int index) {
    _tabs[index].dispose();
    _tabs.removeAt(index);

    if (_tabs.isEmpty) {
      _addUntitledTab(); // _activeTabIndex set inside
    } else {
      _activeTabIndex = index.clamp(0, _tabs.length - 1);
    }

    notifyListeners();
  }

  // Public: switch the active tab.
  void switchTab(int index) {
    if (index == _activeTabIndex) return;
    _activeTabIndex = index;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }
}
