import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/intents.dart';
import '../services/ai_service.dart';
import '../state/editor_state.dart';
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
  bool _editorReadOnly = false;

  // Snapshot captured the moment the Ctrl+K popup opens.
  // The AI call uses these frozen values so editing-while-waiting is irrelevant.
  String _snapshotDocumentText = '';
  TextSelection _snapshotSelection = const TextSelection.collapsed(offset: 0);

  // Guard against re-entrant close attempts while a dirty dialog is showing.
  bool _closingTab = false;

  // ── Convenience ─────────────────────────────────────────────────────────────

  EditorState get _state => widget.editorState;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _state.addListener(_onEditorStateChanged);
  }

  @override
  void dispose() {
    _state.removeListener(_onEditorStateChanged);
    super.dispose();
  }

  void _onEditorStateChanged() {
    // EditorState notifies only on structural changes (add/close/switch tab,
    // title change). Keystrokes never call notifyListeners() — they update
    // isDirtyNotifier directly, which each tab chip handles individually.
    setState(() {});
  }

  // ── AI prompt ───────────────────────────────────────────────────────────────

  void _openAiPrompt() {
    if (_aiPromptVisible) return;

    final controller = _state.activeTab.controller;
    final text = controller.text;
    final selection = controller.selection;

    setState(() {
      _snapshotDocumentText = text;
      _snapshotSelection = selection;
      _aiPromptVisible = true;
    });
  }

  void _dismissAiPrompt() {
    setState(() {
      _aiPromptVisible = false;
    });
  }

  Future<void> _submitAiPrompt(String prompt) async {
    final sel = _snapshotSelection;
    final docText = _snapshotDocumentText;

    setState(() {
      _aiPromptVisible = false;
      _editorReadOnly = true;
    });

    // editTarget is the selected text, or the full document if no selection.
    final editTarget =
        sel.isCollapsed ? docText : sel.textInside(docText);

    final result = await AiService().getCompletion(
      documentText: docText,
      editTarget: editTarget,
      prompt: prompt,
    );

    if (!mounted) return;

    // Apply result: replace the edit target range (or full content) with the
    // AI output, then place the cursor at the end of the inserted text.
    final String newText;
    final int newCursorPos;

    if (sel.isCollapsed) {
      // No selection — replace the entire document.
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
      _editorReadOnly = false;
    });
  }

  // ── Tab close ───────────────────────────────────────────────────────────────

  Future<void> _handleCloseTab(int index) async {
    if (_closingTab) return;
    _closingTab = true;

    try {
      final tab = _state.tabs[index];

      if (tab.isDirty) {
        final result = await _showDirtyCloseDialog(tab.title);
        if (result != _DirtyChoice.dontSave) return; // cancel → do nothing
      }

      _state.forceCloseTab(index);
    } finally {
      _closingTab = false;
    }
  }

  Future<_DirtyChoice> _showDirtyCloseDialog(String tabTitle) async {
    final choice = await showDialog<_DirtyChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: Text(
          '"$tabTitle" has unsaved changes. Close without saving?',
        ),
        actions: [
          // Phase 1: Save is not available yet (no file I/O).
          // Phase 2 will add a Save button here.
          TextButton(
            onPressed: () => Navigator.pop(ctx, _DirtyChoice.dontSave),
            child: const Text("Don't Save"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _DirtyChoice.cancel),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    // If the dialog is dismissed via the back key or barrier, treat as cancel.
    return choice ?? _DirtyChoice.cancel;
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Shortcuts + Actions are stable wrappers — they do not need to rebuild
    // when EditorState changes. Only the Scaffold body reacts to state.
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyN, control: true):
            NewTabIntent(),
        SingleActivator(LogicalKeyboardKey.keyW, control: true):
            CloseTabIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            OpenAiPromptIntent(),
        // Phase 2 will add: Ctrl+O, Ctrl+S, Ctrl+Shift+S
      },
      child: Actions(
        actions: {
          NewTabIntent: CallbackAction<NewTabIntent>(
            onInvoke: (_) => _state.newTab(),
          ),
          CloseTabIntent: CallbackAction<CloseTabIntent>(
            // activeTabIndex is read at invocation time, not at build time.
            onInvoke: (_) => _handleCloseTab(_state.activeTabIndex),
          ),
          OpenAiPromptIntent: CallbackAction<OpenAiPromptIntent>(
            onInvoke: (_) => _openAiPrompt(),
          ),
        },
        child: Scaffold(
          body: Column(
            children: [
              // ── Tab bar ──────────────────────────────────────────────────
              EditorTabBar(
                tabs: _state.tabs,
                activeTabIndex: _state.activeTabIndex,
                onTabTap: _state.switchTab,
                onTabClose: _handleCloseTab,
                onNewTab: _state.newTab,
              ),

              // ── AI request progress indicator ────────────────────────────
              // Shown as a 2-pixel stripe below the tab bar while waiting for
              // the AI response. Phase 1 stub returns instantly, so this is
              // barely visible — it's wired correctly for Phase 3+ latency.
              if (_editorReadOnly)
                const LinearProgressIndicator(minHeight: 2),

              // ── Editor area + AI popup overlay ───────────────────────────
              Expanded(
                child: Stack(
                  children: [
                    // Main text editor — fills the stack.
                    EditorArea(
                      tab: _state.activeTab,
                      readOnly: _editorReadOnly,
                    ),

                    // AI prompt popup — anchored to the top-center of the
                    // editor area via Align + Padding inside the Stack.
                    // Visible only while _aiPromptVisible is true.
                    if (_aiPromptVisible)
                      AiPromptPopup(
                        onDismiss: _dismissAiPrompt,
                        onSubmit: _submitAiPrompt,
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

// Result of the dirty-close confirmation dialog.
enum _DirtyChoice { dontSave, cancel }
