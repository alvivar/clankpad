import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/editor_tab.dart';
import '../models/intents.dart';
import '../services/ai_service.dart';
import '../state/editor_state.dart';
import '../widgets/ai_diff_view.dart';
import '../widgets/ai_prompt_popup.dart';
import '../widgets/editor_area.dart';
import '../widgets/editor_tab_bar.dart';

class EditorScreen extends StatefulWidget {
  final EditorState editorState;

  const EditorScreen({super.key, required this.editorState});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  // ── Local UI state ──────────────────────────────────────────────────────────

  bool _aiPromptVisible = false;

  // True while the AI request is in-flight AND while the diff view is shown.
  // Keeps the editor readOnly so the snapshot remains valid.
  bool _editorReadOnly = false;

  // Snapshot captured when the Ctrl+K popup opens.
  String _snapshotDocumentText = '';
  TextSelection _snapshotSelection = const TextSelection.collapsed(offset: 0);

  // Diff view state — populated after the AI response arrives.
  bool _diffVisible = false;
  String _diffEditTarget = '';
  String _diffProposed = '';

  // Guards against re-entrant close attempts while a dialog is showing.
  bool _closingTab = false;

  // ── Convenience ─────────────────────────────────────────────────────────────

  EditorState get _state => widget.editorState;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _state.addListener(_onEditorStateChanged);

    // Show any session-restore notices (missing files, etc.) once the first
    // frame has been drawn so there is a valid BuildContext for the dialog.
    if (_state.startupNotices.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showStartupNotices());
    }
  }

  @override
  void dispose() {
    _state.removeListener(_onEditorStateChanged);
    super.dispose();
  }

  void _onEditorStateChanged() => setState(() {});

  // ── Startup notices ──────────────────────────────────────────────────────────

  Future<void> _showStartupNotices() async {
    final notices = List<String>.from(_state.startupNotices);
    _state.startupNotices.clear();

    for (final notice in notices) {
      if (!mounted) return;
      await _showErrorDialog(title: 'Session Restore', message: notice);
    }
  }

  // ── File helpers ─────────────────────────────────────────────────────────────

  static String _fileNameFromPath(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  static String _suggestedSaveName(EditorTab tab) {
    if (tab.filePath != null) return _fileNameFromPath(tab.filePath!);
    final title = tab.title;
    return title.contains('.') ? title : '$title.txt';
  }

  // ── Open file ────────────────────────────────────────────────────────────────

  Future<void> _openFile() async {
    final picked = await openFile();
    if (picked == null) return;

    final absPath = File(picked.path).absolute.path;
    final normalised = absPath.toLowerCase();

    // Switch to the existing tab if the file is already open.
    final existingIndex = _state.tabs.indexWhere(
      (t) =>
          t.filePath != null &&
          File(t.filePath!).absolute.path.toLowerCase() == normalised,
    );
    if (existingIndex != -1) {
      _state.switchTab(existingIndex);
      return;
    }

    String content;
    try {
      content = await File(absPath).readAsString();
    } catch (e) {
      if (!mounted) return;
      await _showErrorDialog(title: 'Could not open file', message: e.toString());
      return;
    }

    _state.loadFileIntoTab(absPath, _fileNameFromPath(absPath), content);
  }

  // ── Save / Save As ───────────────────────────────────────────────────────────

  Future<bool> _saveTab(int index) async {
    final tab = _state.tabs[index];
    if (tab.filePath != null && !tab.isDirty) return true;

    if (tab.filePath != null) {
      return _writeFile(tab.filePath!, tab.controller.text, index);
    } else {
      return _saveTabAs(index);
    }
  }

  Future<bool> _saveTabAs(int index) async {
    final tab = _state.tabs[index];
    final location = await getSaveLocation(suggestedName: _suggestedSaveName(tab));
    if (location == null) return false;
    return _writeFile(location.path, tab.controller.text, index);
  }

  Future<bool> _writeFile(String path, String content, int index) async {
    try {
      await File(path).writeAsString(content);
      _state.onTabSaved(
        index,
        savedContent: content,
        filePath: path,
        title: _fileNameFromPath(path),
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      await _showErrorDialog(title: 'Save failed', message: e.toString());
      return false;
    }
  }

  // ── AI prompt ────────────────────────────────────────────────────────────────

  void _openAiPrompt() {
    // Block if another overlay is already active.
    if (_aiPromptVisible || _diffVisible) return;

    final controller = _state.activeTab.controller;

    setState(() {
      _snapshotDocumentText = controller.text;
      _snapshotSelection = controller.selection;
      _aiPromptVisible = true;
    });
  }

  void _dismissAiPrompt() => setState(() => _aiPromptVisible = false);

  Future<void> _submitAiPrompt(String prompt) async {
    final sel = _snapshotSelection;
    final docText = _snapshotDocumentText;

    setState(() {
      _aiPromptVisible = false;
      _editorReadOnly = true; // lock editor for the duration of request + diff review
    });

    final editTarget = sel.isCollapsed ? docText : sel.textInside(docText);

    final result = await AiService().getCompletion(
      documentText: docText,
      editTarget: editTarget,
      prompt: prompt,
    );

    if (!mounted) return;

    // Show the diff view; keep editor locked until the user decides.
    setState(() {
      _diffVisible = true;
      _diffEditTarget = editTarget;
      _diffProposed = result;
    });
  }

  // ── Diff accept / reject ─────────────────────────────────────────────────────

  void _acceptDiff() {
    final sel = _snapshotSelection;
    final docText = _snapshotDocumentText;
    final result = _diffProposed;

    final String newText;
    final int newCursorPos;

    if (sel.isCollapsed) {
      newText = result;
      newCursorPos = result.length;
    } else {
      newText = docText.replaceRange(sel.start, sel.end, result);
      newCursorPos = sel.start + result.length;
    }

    _state.activeTab.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );

    setState(() {
      _diffVisible = false;
      _editorReadOnly = false;
    });
  }

  void _rejectDiff() {
    // Text is unchanged — no controller update needed.
    setState(() {
      _diffVisible = false;
      _editorReadOnly = false;
    });
  }

  // ── Tab close ────────────────────────────────────────────────────────────────

  Future<void> _handleCloseTab(int index) async {
    if (_closingTab) return;
    _closingTab = true;

    try {
      final tab = _state.tabs[index];

      if (tab.isDirty) {
        final choice = await _showDirtyCloseDialog(tab.title);

        switch (choice) {
          case _DirtyChoice.cancel:
            return;
          case _DirtyChoice.save:
            final saved = await _saveTab(index);
            if (!saved) return; // save failed or cancelled → keep tab open
          case _DirtyChoice.dontSave:
            break;
        }
      }

      _state.forceCloseTab(index);
    } finally {
      _closingTab = false;
    }
  }

  // ── Dialogs ──────────────────────────────────────────────────────────────────

  Future<_DirtyChoice> _showDirtyCloseDialog(String tabTitle) async {
    final choice = await showDialog<_DirtyChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: Text('"$tabTitle" has unsaved changes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DirtyChoice.dontSave),
            child: const Text("Don't Save"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DirtyChoice.cancel),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _DirtyChoice.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    return choice ?? _DirtyChoice.cancel;
  }

  Future<void> _showErrorDialog({
    required String title,
    required String message,
  }) =>
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyN, control: true): NewTabIntent(),
        SingleActivator(LogicalKeyboardKey.keyW, control: true): CloseTabIntent(),
        SingleActivator(LogicalKeyboardKey.keyO, control: true): OpenFileIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
            SaveAsIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            OpenAiPromptIntent(),
      },
      child: Actions(
        actions: {
          NewTabIntent: CallbackAction<NewTabIntent>(
            onInvoke: (_) => _state.newTab(),
          ),
          CloseTabIntent: CallbackAction<CloseTabIntent>(
            onInvoke: (_) => _handleCloseTab(_state.activeTabIndex),
          ),
          OpenFileIntent: CallbackAction<OpenFileIntent>(
            onInvoke: (_) => _openFile(),
          ),
          SaveIntent: CallbackAction<SaveIntent>(
            onInvoke: (_) => _saveTab(_state.activeTabIndex),
          ),
          SaveAsIntent: CallbackAction<SaveAsIntent>(
            onInvoke: (_) => _saveTabAs(_state.activeTabIndex),
          ),
          OpenAiPromptIntent: CallbackAction<OpenAiPromptIntent>(
            onInvoke: (_) => _openAiPrompt(),
          ),
        },
        child: Scaffold(
          body: Column(
            children: [
              // Tab bar
              EditorTabBar(
                tabs: _state.tabs,
                activeTabIndex: _state.activeTabIndex,
                onTabTap: _state.switchTab,
                onTabClose: _handleCloseTab,
                onNewTab: _state.newTab,
              ),

              // Thin progress stripe: visible while AI request is in-flight.
              if (_editorReadOnly && !_diffVisible)
                const LinearProgressIndicator(minHeight: 2),

              // Editor area + overlays
              Expanded(
                child: Stack(
                  children: [
                    EditorArea(
                      tab: _state.activeTab,
                      readOnly: _editorReadOnly,
                    ),

                    if (_aiPromptVisible)
                      AiPromptPopup(
                        onDismiss: _dismissAiPrompt,
                        onSubmit: _submitAiPrompt,
                      ),

                    if (_diffVisible)
                      AiDiffView(
                        editTarget: _diffEditTarget,
                        proposed: _diffProposed,
                        onAccept: _acceptDiff,
                        onReject: _rejectDiff,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _DirtyChoice { save, dontSave, cancel }
