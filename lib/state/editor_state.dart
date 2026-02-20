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

  // Public: load a file into the editor.
  //
  // Reuses the active tab if it is empty and untitled (matches the standard
  // "open replaces blank tab" behavior). Otherwise appends a new tab.
  // The caller is responsible for duplicate-detection and path normalization
  // before calling this.
  void loadFileIntoTab(String filePath, String title, String content) {
    final active = _tabs[_activeTabIndex];
    final reuseActive =
        active.filePath == null && active.controller.text.isEmpty;

    if (reuseActive) {
      // Mutate in place — no new tab, no ID change.
      active.filePath = filePath;
      active.title = title;
      active.savedContent = content;
      // Setting controller.text fires the listener, which sets isDirtyNotifier
      // = (content != savedContent) = false. Correct.
      active.controller.text = content;
    } else {
      final tab = _buildTab(
        filePath: filePath,
        title: title,
        initialContent: content,
        savedContent: content,
      );
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    }

    notifyListeners();
  }

  // Public: update tab state after a successful file write.
  //
  // Always updates savedContent (and recomputes isDirty synchronously).
  // filePath and title are only updated when non-null — pass them on Save As,
  // omit them (or pass null) on a plain Save where the path hasn't changed.
  void onTabSaved(
    int index, {
    required String savedContent,
    String? filePath,
    String? title,
  }) {
    final tab = _tabs[index];
    tab.savedContent = savedContent;
    if (filePath != null) tab.filePath = filePath;
    if (title != null) tab.title = title;
    // Recompute dirty synchronously — the controller listener won't fire
    // again unless the text changes.
    tab.isDirtyNotifier.value = tab.controller.text != tab.savedContent;
    notifyListeners(); // title or path may have changed
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }
}
