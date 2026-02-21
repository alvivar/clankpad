import 'dart:io';

import 'package:flutter/widgets.dart';

import '../models/editor_tab.dart';

class EditorState extends ChangeNotifier {
  final List<EditorTab> _tabs = [];

  int _activeTabIndex = 0;
  int _nextTabId = 0;
  int _untitledCounter = 0;

  List<EditorTab> get tabs => List.unmodifiable(_tabs);
  int get activeTabIndex => _activeTabIndex;
  EditorTab get activeTab => _tabs[_activeTabIndex];

  // Exposed for session serialisation.
  int get nextTabId => _nextTabId;
  int get untitledCounter => _untitledCounter;

  // Set by SessionService after construction.
  // Called on every meaningful change — structural OR text edit — so the
  // service can schedule a debounced write without subscribing to each
  // individual controller.
  VoidCallback? onAnyChange;

  // Startup notices accumulated during session restore (missing files, etc.).
  // EditorScreen reads and clears these once after the first frame.
  // Notices collected during session restore (missing files, etc.).
  // Consumed once by EditorScreen via takeStartupNotices().
  final List<String> _startupNotices = [];

  bool get hasStartupNotices => _startupNotices.isNotEmpty;

  /// Removes and returns all pending startup notices atomically.
  List<String> takeStartupNotices() {
    final result = List<String>.from(_startupNotices);
    _startupNotices.clear();
    return result;
  }

  EditorState() {
    _addUntitledTab();
  }

  // ── Internal helpers ─────────────────────────────────────────────────────────

  // Calls onAnyChange and then notifyListeners.
  // All structural mutations go through this so the session service and the
  // widget tree are both notified in one place.
  void _structuralChange() {
    onAnyChange?.call();
    notifyListeners();
  }

  // Builds a tab and wires its controller listener.
  // Pass an explicit [id] when restoring from session; otherwise the next
  // sequential ID is used.
  EditorTab _buildTab({
    int? id,
    String? filePath,
    required String title,
    String initialContent = '',
    String savedContent = '',
  }) {
    final resolvedId = id ?? _nextTabId++;
    final tab = EditorTab(
      id: resolvedId,
      filePath: filePath,
      title: title,
      savedContent: savedContent,
      initialContent: initialContent,
    );

    tab.controller.addListener(() {
      final newDirty = tab.controller.text != tab.savedContent;
      final changed = newDirty != tab.isDirtyNotifier.value;
      tab.isDirtyNotifier.value = newDirty;
      // Text edits are NOT structural — notifyListeners is not called.
      // Only the tab chip (ValueListenableBuilder on isDirtyNotifier) rebuilds.
      //
      // onAnyChange fires when content is dirty (user is actively editing)
      // OR when the dirty state just flipped (clean→dirty or dirty→clean).
      // This suppresses the redundant call in loadFileIntoTab's reuseActive
      // branch, where controller.text is set to equal savedContent — both
      // newDirty and changed are false, so only _structuralChange() fires.
      if (newDirty || changed) onAnyChange?.call();
    });

    return tab;
  }

  // Appends a fresh untitled tab and makes it active.
  void _addUntitledTab() {
    _untitledCounter++;
    final tab = _buildTab(title: 'Untitled $_untitledCounter');
    _tabs.add(tab);
    _activeTabIndex = _tabs.length - 1;
  }

  // ── Public structural mutations ──────────────────────────────────────────────

  void newTab() {
    _addUntitledTab();
    _structuralChange();
  }

  // Removes the tab at [index]. Dirty-check dialogs are handled by the UI
  // layer before calling this. Enforces the "at least one tab" invariant.
  void forceCloseTab(int index) {
    _tabs[index].dispose();
    _tabs.removeAt(index);

    if (_tabs.isEmpty) {
      _addUntitledTab();
    } else {
      _activeTabIndex = index.clamp(0, _tabs.length - 1);
    }

    _structuralChange();
  }

  void switchTab(int index) {
    if (index == _activeTabIndex) return;
    _activeTabIndex = index;
    _structuralChange();
  }

  // Reuses the active tab if it is empty and untitled; otherwise appends a
  // new tab. The caller must have already normalised the path and confirmed
  // the file is not already open.
  void loadFileIntoTab(String filePath, String title, String content) {
    final active = _tabs[_activeTabIndex];
    final reuseActive =
        active.filePath == null && active.controller.text.isEmpty;

    if (reuseActive) {
      active.filePath = filePath;
      active.title = title;
      active.savedContent = content;
      // Fires the controller listener → isDirtyNotifier = false.
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

    _structuralChange();
  }

  // Called after a successful file write. Always updates savedContent.
  // filePath and title are only updated when non-null (Save As only).
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
    tab.isDirtyNotifier.value = tab.controller.text != tab.savedContent;
    _structuralChange();
  }

  // ── Session restore ──────────────────────────────────────────────────────────

  // Restores editor state from a parsed session.json map.
  // Called once before runApp; onAnyChange is not yet set, so no session
  // writes are triggered during restore.
  // User-facing notices (missing files, etc.) are stored internally and
  // consumed by EditorScreen via takeStartupNotices().
  Future<void> restoreFromSession(Map<String, dynamic> json) async {
    _nextTabId = (json['nextTabId'] as int?) ?? _nextTabId;
    _untitledCounter = (json['untitledCounter'] as int?) ?? _untitledCounter;
    final storedActiveIndex = (json['activeTabIndex'] as int?) ?? 0;

    // Dispose the initial tab created by the constructor.
    for (final tab in _tabs) {
      tab.dispose();
    }
    _tabs.clear();

    final notices = <String>[];
    final rawTabs = (json['tabs'] as List?) ?? [];

    for (final raw in rawTabs) {
      final tab = await _restoreTab(raw as Map<String, dynamic>, notices);
      if (tab != null) _tabs.add(tab);
    }

    // Post-restore fixup 1: enforce "at least one tab" invariant.
    if (_tabs.isEmpty) {
      _addUntitledTab();
    }

    // Post-restore fixup 2: clamp activeTabIndex after min-1 is guaranteed.
    _activeTabIndex = storedActiveIndex.clamp(0, _tabs.length - 1);

    // notifyListeners here is a no-op (no listeners yet), but is correct to
    // call for completeness in case the restore happens to have listeners.
    notifyListeners();

    _startupNotices
      ..clear()
      ..addAll(notices);
  }

  Future<EditorTab?> _restoreTab(
    Map<String, dynamic> json,
    List<String> notices,
  ) async {
    final id = json['id'] as int?;
    final title = (json['title'] as String?) ?? 'Untitled';
    final filePath = json['filePath'] as String?;
    final hasContent = json.containsKey('content');
    final content = (json['content'] as String?) ?? '';
    final savedContent = (json['savedContent'] as String?) ?? '';

    // Ensure _nextTabId stays ahead of any restored ID.
    if (id != null && id >= _nextTabId) _nextTabId = id + 1;

    if (filePath == null) {
      // Untitled tab — content is always stored in the session.
      return _buildTab(
        id: id,
        title: title,
        initialContent: content,
        savedContent: savedContent,
      );
    }

    if (hasContent) {
      // Dirty file-backed tab — restore unsaved edits from the session.
      final tab = _buildTab(
        id: id,
        filePath: filePath,
        title: title,
        initialContent: content,
        savedContent: savedContent,
      );

      // Warn if the backing file has since gone missing.
      bool exists = false;
      try {
        exists = await File(filePath).exists();
      } catch (_) {}

      if (!exists) {
        notices.add(
          '⚠ "$title" not found at its original path — content restored from last session.',
        );
      }

      return tab;
    }

    // Clean file-backed tab — re-read content from disk.
    try {
      final diskContent = await File(filePath).readAsString();
      return _buildTab(
        id: id,
        filePath: filePath,
        title: title,
        initialContent: diskContent,
        savedContent: diskContent,
      );
    } catch (_) {
      // File is gone and we have no stored content — skip the tab.
      notices.add('"$title" could not be restored — file no longer exists.');
      return null;
    }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }
}
