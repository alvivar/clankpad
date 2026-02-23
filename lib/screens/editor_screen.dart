import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/editor_tab.dart';
import '../models/intents.dart';
import '../services/pi_rpc_service.dart';
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

  // Diff view state — populated as chunks arrive from the AI stream.
  bool _diffVisible = false;
  String _diffEditTarget = '';
  String _diffProposed = '';

  // Error banner — set when Pi fails; cleared on dismiss or next Ctrl+K.
  String? _errorBanner;

  // Prompt history — session-only; entries appended on each successful submit.
  final List<String> _promptHistory = [];
  int _historyIndex = 0; // reset to _promptHistory.length on popup open
  String _historySavedInput = ''; // preserves draft while navigating history

  // Guards against re-entrant close attempts while a dialog is showing.
  bool _closingTab = false;

  // Persistent FocusNode for the editor TextField. Kept alive across tab
  // switches so that focus can be explicitly restored after popups and diffs
  // are dismissed (autofocus on the TextField only fires on first insertion).
  final FocusNode _editorFocusNode = FocusNode();

  // FocusNode for the diff overlay. requestFocus() is called in a post-frame
  // callback once the overlay is mounted; focus returns to _editorFocusNode
  // after accept / reject.
  final FocusNode _diffFocusNode = FocusNode();

  // Owned as a field so the process is killed if the screen is disposed while
  // a request is in-flight.
  final _piRpcService = PiRpcService();

  // ── Convenience ─────────────────────────────────────────────────────────────

  EditorState get _state => widget.editorState;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _state.addListener(_onEditorStateChanged);

    // Show any session-restore notices (missing files, etc.) once the first
    // frame has been drawn so there is a valid BuildContext for the dialog.
    if (_state.hasStartupNotices) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showStartupNotices(),
      );
    }
  }

  @override
  void dispose() {
    _state.removeListener(_onEditorStateChanged);
    _editorFocusNode.dispose();
    _diffFocusNode.dispose();
    _piRpcService.dispose();
    super.dispose();
  }

  void _onEditorStateChanged() {
    setState(() {});
    // Restore focus to the editor after every structural change.
    // Mouse clicks on tab chips and buttons clear focus from the TextField
    // (Flutter desktop clears focus on clicks to non-focusable areas).
    // The post-frame callback ensures _editorFocusNode is settled before
    // requesting focus. Safe for keyboard shortcuts too: without ValueKey,
    // _editorFocusNode stays attached to the same element the whole time,
    // so calling requestFocus on an already-focused node is a no-op.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_aiPromptVisible && !_diffVisible) {
        _editorFocusNode.requestFocus();
      }
    });
  }

  // ── Startup notices ──────────────────────────────────────────────────────────

  Future<void> _showStartupNotices() async {
    final notices = _state.takeStartupNotices();

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
      await _showErrorDialog(
        title: 'Could not open file',
        message: e.toString(),
      );
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
    }
    return _saveTabAs(index);
  }

  Future<bool> _saveTabAs(int index) async {
    final tab = _state.tabs[index];
    final location = await getSaveLocation(
      suggestedName: _suggestedSaveName(tab),
    );
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

    // Reset history navigation to the "past-the-end" position so the first
    // Up press goes to the most recent entry (not where we left off last time).
    _historyIndex = _promptHistory.length;
    _historySavedInput = '';

    setState(() {
      _snapshotDocumentText = controller.text;
      _snapshotSelection = controller.selection;
      _aiPromptVisible = true;
    });
  }

  // ── Prompt history ───────────────────────────────────────────────────────────

  /// Called by [AiPromptPopup] when the user presses Up on the first line.
  /// Returns the text to display, or null to let the TextField handle the key.
  String? _historyUp(String currentText) {
    if (_promptHistory.isEmpty) return null;
    if (_historyIndex == _promptHistory.length) {
      _historySavedInput = currentText; // first Up — save current draft
    }
    if (_historyIndex > 0) {
      _historyIndex--;
      return _promptHistory[_historyIndex];
    }
    return null; // already at oldest — let TextField move cursor normally
  }

  /// Called by [AiPromptPopup] when the user presses Down on the last line.
  /// Returns the text to display, or null to let the TextField handle the key.
  String? _historyDown(String currentText) {
    if (_historyIndex >= _promptHistory.length) return null;
    _historyIndex++;
    return _historyIndex == _promptHistory.length
        ? _historySavedInput // past end — restore saved draft
        : _promptHistory[_historyIndex];
  }

  void _dismissAiPrompt() {
    setState(() => _aiPromptVisible = false);
    // _editorFocusNode is permanently attached to the TextField (no ValueKey,
    // no element recreation), so requestFocus() is safe to call synchronously
    // here — no post-frame callback needed, unlike _onEditorStateChanged where
    // focus may have been cleared by a pointer event before the rebuild runs.
    _editorFocusNode.requestFocus();
  }

  Future<void> _submitAiPrompt(String prompt) async {
    final sel = _snapshotSelection;
    final docText = _snapshotDocumentText;
    final editTarget = sel.isCollapsed ? docText : sel.textInside(docText);

    // Append to history; skip consecutive duplicates; cap at 50.
    if (_promptHistory.isEmpty || _promptHistory.last != prompt) {
      _promptHistory.add(prompt);
      if (_promptHistory.length > 50) _promptHistory.removeAt(0);
    }
    _historyIndex = _promptHistory.length;

    setState(() {
      _aiPromptVisible = false;
      _editorReadOnly =
          true; // locked until diff is accepted/rejected/cancelled
      _diffProposed = '';
      _errorBanner = null; // clear any previous error
    });

    bool diffOpened = false;

    try {
      await for (final chunk in _piRpcService.streamEdit(
        documentText: docText,
        editTarget: editTarget,
        userInstruction: prompt,
      )) {
        // Exit if the widget was disposed or the user cancelled (which sets
        // _editorReadOnly = false) before the diff was opened.
        if (!mounted || !_editorReadOnly) return;

        if (!diffOpened) {
          // First chunk: open the diff view and focus it.
          diffOpened = true;
          setState(() {
            _diffVisible = true;
            _diffEditTarget = editTarget;
            _diffProposed = chunk;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _diffFocusNode.requestFocus();
          });
        } else {
          // Subsequent chunks: append to the live "After" pane.
          setState(() => _diffProposed += chunk);
        }
      }
    } on PiRpcError catch (e) {
      if (!mounted) return;
      setState(() => _errorBanner = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorBanner = 'Unexpected error — $e');
    } finally {
      // Always unlock the editor, even on error or cancel.
      // If the diff is visible the editor was already locked; it stays locked
      // until the user accepts/rejects, so we only clear it here when the
      // diff did not open (error or pre-diff cancel).
      if (mounted && !_diffVisible) {
        setState(() => _editorReadOnly = false);
      }
    }
  }

  /// Aborts the in-flight Pi request and immediately unlocks the editor.
  /// Only valid while the loading state is active (before the diff opens).
  void _cancelAiRequest() {
    _piRpcService.abort();
    setState(() => _editorReadOnly = false);
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
    // See _dismissAiPrompt: synchronous requestFocus() is safe here because
    // _editorFocusNode is always in the tree.
    _editorFocusNode.requestFocus();
  }

  void _rejectDiff() {
    // Abort Pi if the stream is still running (e.g. user rejects while
    // tokens are still arriving). No-op if the stream has already finished.
    _piRpcService.abort();
    // Text is unchanged — no controller update needed.
    setState(() {
      _diffVisible = false;
      _editorReadOnly = false;
    });
    // See _dismissAiPrompt: synchronous requestFocus() is safe here because
    // _editorFocusNode is always in the tree.
    _editorFocusNode.requestFocus();
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
  }) => showDialog(
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
    // Shortcuts + Actions live here at EditorScreen level, not at MaterialApp
    // root. The two must stay together: Flutter's dispatch walks up from the
    // focused widget to find Shortcuts (intent), then continues up to find
    // Actions (handler). Separating them across a Navigator boundary (e.g.,
    // Shortcuts above MaterialApp, Actions here) breaks the lookup for any
    // route other than EditorScreen, because the parallel subtrees are not in
    // the same upward path. All shortcuts here are also editor-specific —
    // Ctrl+N creating a tab while a settings route is active would be wrong,
    // so EditorScreen scope is correct by design, not just by convenience.
    final colorScheme = Theme.of(context).colorScheme;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyN, control: true): NewTabIntent(),
        SingleActivator(LogicalKeyboardKey.keyW, control: true):
            CloseTabIntent(),
        SingleActivator(LogicalKeyboardKey.keyO, control: true):
            OpenFileIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
            SaveAsIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            OpenAiPromptIntent(),
        // Escape cancels the in-flight AI request before the diff opens.
        // When the diff IS open, AiDiffView's inner Shortcuts intercept Escape
        // first (for Reject), so this binding is only reachable during loading.
        SingleActivator(LogicalKeyboardKey.escape): CancelAiIntent(),
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
          CancelAiIntent: CallbackAction<CancelAiIntent>(
            onInvoke: (_) {
              if (_editorReadOnly && !_aiPromptVisible && !_diffVisible) {
                _cancelAiRequest();
              }
              return null;
            },
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

              // Error banner — shown after a Pi failure; dismissed by ×.
              if (_errorBanner != null)
                ColoredBox(
                  color: colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _errorBanner!,
                            style: TextStyle(
                              color: colorScheme.onErrorContainer,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => setState(() => _errorBanner = null),
                          icon: const Icon(Icons.close),
                          iconSize: 16,
                          color: colorScheme.onErrorContainer,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),

              // Progress stripe + cancel button: visible while Pi is
              // running and the diff view has not yet opened.
              if (_editorReadOnly && !_diffVisible) ...[
                const LinearProgressIndicator(minHeight: 2),
                ColoredBox(
                  color: colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _cancelAiRequest,
                          style: TextButton.styleFrom(
                            foregroundColor: colorScheme.onSurfaceVariant,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 2,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            'Cancel  (Esc)',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              // Editor area + overlays
              Expanded(
                child: Stack(
                  children: [
                    EditorArea(
                      tab: _state.activeTab,
                      readOnly: _editorReadOnly,
                      focusNode: _editorFocusNode,
                    ),

                    if (_aiPromptVisible)
                      AiPromptPopup(
                        onDismiss: _dismissAiPrompt,
                        onSubmit: _submitAiPrompt,
                        onHistoryUp: _historyUp,
                        onHistoryDown: _historyDown,
                      ),

                    if (_diffVisible)
                      AiDiffView(
                        focusNode: _diffFocusNode,
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
