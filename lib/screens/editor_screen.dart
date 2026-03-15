import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/editor_tab.dart';
import '../models/intents.dart';
import '../services/ai_provider.dart';
import '../services/claude_code_provider.dart';
import '../services/pi_provider.dart';
import '../state/editor_state.dart';
import '../widgets/ai_diff_view.dart';
import '../widgets/ai_prompt_popup.dart' show AiModelSettings, AiPromptPopup;
import '../widgets/editor_area.dart';
import '../widgets/editor_tab_bar.dart';
import '../widgets/find_bar.dart';

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
  int? _snapshotTabId; // safety-net: apply diff to the tab that was snapshotted

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

  // ── Find bar state ───────────────────────────────────────────────────────────

  bool _searchVisible = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<int> _searchMatches = const [];
  int _searchMatchIndex = -1; // 0-based; -1 = no matches

  // ── Misc ─────────────────────────────────────────────────────────────────────

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

  // ── AI providers ─────────────────────────────────────────────────────────────

  // All registered providers. Processes are killed if the screen is disposed
  // while a request is in-flight.
  final Map<String, AiProvider> _providers = {
    'pi': PiProvider(),
    'claude_code': ClaudeCodeProvider(),
  };

  late String _selectedProviderKey;

  AiProvider get _activeProvider => _providers[_selectedProviderKey]!;

  // ── Model / thinking state ──────────────────────────────────────────────────

  // Per-provider model cache — fetched once per provider, reused on switch-back.
  final Map<String, List<Map<String, dynamic>>> _modelCache = {};
  // Full fetch result (includes suggestions) — kept for switch-back seeding.
  final Map<String, AiProviderModels> _fetchResultCache = {};

  List<Map<String, dynamic>> _availableModels = [];
  bool _modelsLoading = false;
  String? _selectedProvider;
  String? _selectedModelId; // null = let provider use its configured default
  String _thinkingLevel = 'off';

  /// Maps Pi's full thinking-level range to the four values shown in the UI.
  static String _normaliseLevel(String level) => switch (level) {
    'low' || 'minimal' => 'low',
    'medium' => 'medium',
    'high' || 'xhigh' => 'high',
    _ => 'off', // 'off' and anything unknown
  };

  // ── Convenience ─────────────────────────────────────────────────────────────

  EditorState get _state => widget.editorState;

  /// True during every AI phase: prompt open, streaming, and diff visible.
  /// Used to guard structural actions (new/close/open/switch) that would
  /// invalidate the snapshot or apply the diff to the wrong tab.
  bool get _aiActive => _aiPromptVisible || _editorReadOnly || _diffVisible;

  // ── Paragraph helper ─────────────────────────────────────────────────────────

  /// Returns the [start, end) character range of the paragraph at [offset],
  /// or null if [offset] falls on a blank line.
  /// A paragraph is a maximal run of consecutive non-blank lines.
  static (int, int)? _paragraphRangeAt(String text, int offset) {
    final lineStart = offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
    final lineEndRaw = text.indexOf('\n', offset);
    final lineEnd = lineEndRaw == -1 ? text.length : lineEndRaw;

    if (text.substring(lineStart, lineEnd).trim().isEmpty) return null;

    // Walk backward to paragraph start.
    int paraStart = lineStart;
    while (paraStart > 0) {
      final prevEnd = paraStart - 1;
      final prevStart = text.lastIndexOf('\n', prevEnd - 1) + 1;
      if (text.substring(prevStart, prevEnd).trim().isEmpty) break;
      paraStart = prevStart;
    }

    // Walk forward to paragraph end.
    int paraEnd = lineEnd;
    while (paraEnd < text.length) {
      final nextStart = paraEnd + 1;
      final nextEndRaw = text.indexOf('\n', nextStart);
      final nextEnd = nextEndRaw == -1 ? text.length : nextEndRaw;
      if (text.substring(nextStart, nextEnd).trim().isEmpty) break;
      paraEnd = nextEnd;
    }

    return (paraStart, paraEnd);
  }

  // ── Move line ────────────────────────────────────────────────────────────────

  /// Moves the line(s) covered by the current selection up (-1) or down (+1)
  /// by swapping with the adjacent line. Multi-line selections move as a block.
  /// No-op when the editor is not focused, is read-only, or is already at the
  /// boundary.
  void _moveLines(int direction) {
    if (!_editorFocusNode.hasFocus || _editorReadOnly) return;
    final controller = _state.activeTab.controller;
    final text = controller.text;
    final selection = controller.selection;
    if (!selection.isValid || text.isEmpty) return;

    final lines = text.split('\n');
    final firstLine = text.substring(0, selection.start).split('\n').length - 1;
    final lastLine = text.substring(0, selection.end).split('\n').length - 1;

    if (direction == -1 && firstLine == 0) return;
    if (direction == 1 && lastLine == lines.length - 1) return;

    final int delta;
    if (direction == -1) {
      final above = lines.removeAt(firstLine - 1);
      lines.insert(lastLine, above);
      delta = -(above.length + 1);
    } else {
      final below = lines.removeAt(lastLine + 1);
      lines.insert(firstLine, below);
      delta = below.length + 1;
    }

    controller.value = TextEditingValue(
      text: lines.join('\n'),
      selection: TextSelection(
        baseOffset: selection.baseOffset + delta,
        extentOffset: selection.extentOffset + delta,
      ),
    );
  }

  // ── Find / search ────────────────────────────────────────────────────────────

  /// Returns the start offset of every non-overlapping case-insensitive match
  /// of [query] in [text].
  static List<int> _computeMatches(String text, String query) {
    if (query.isEmpty) return const [];
    final lower = text.toLowerCase();
    final qLower = query.toLowerCase();
    final matches = <int>[];
    var i = 0;
    while (true) {
      final idx = lower.indexOf(qLower, i);
      if (idx == -1) break;
      matches.add(idx);
      i = idx + qLower.length;
    }
    return matches;
  }

  void _openSearch() {
    if (_aiPromptVisible || _diffVisible) return;

    // If there's a non-collapsed, single-line selection, pre-fill it.
    final sel = _state.activeTab.controller.selection;
    final docText = _state.activeTab.controller.text;
    final selectedText = sel.isCollapsed
        ? null
        : docText.substring(sel.start, sel.end);
    final prefill = (selectedText != null && !selectedText.contains('\n'))
        ? selectedText
        : null;

    if (prefill != null) {
      _searchController.value = TextEditingValue(
        text: prefill,
        selection: TextSelection(baseOffset: 0, extentOffset: prefill.length),
      );
    }

    // If already open, update query (if prefilled) and re-focus.
    if (_searchVisible) {
      if (prefill != null) _onSearchQueryChanged(prefill);
      _searchFocusNode.requestFocus();
      return;
    }

    // Compute fresh matches for the current tab content.
    final query = prefill ?? _searchController.text;
    final matches = query.isEmpty
        ? const <int>[]
        : _computeMatches(docText, query);
    setState(() {
      _searchVisible = true;
      _searchMatches = matches;
      _searchMatchIndex = matches.isEmpty ? -1 : 0;
    });
    if (matches.isNotEmpty) {
      _jumpToMatch(0);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    }
  }

  void _closeSearch() {
    // Clear highlights on every tab (the user may have switched tabs while
    // the bar was open, leaving stale highlights on non-active controllers).
    for (final tab in _state.tabs) {
      tab.controller.clearMatches();
    }
    setState(() {
      _searchVisible = false;
      _searchMatches = const [];
      _searchMatchIndex = -1;
    });
    _editorFocusNode.requestFocus();
  }

  void _onSearchQueryChanged(String query) {
    final matches = _computeMatches(_state.activeTab.controller.text, query);
    setState(() {
      _searchMatches = matches;
      _searchMatchIndex = matches.isEmpty ? -1 : 0;
    });
    if (matches.isNotEmpty) {
      _jumpToMatch(0);
    } else {
      // Clear any highlights left from a previous query.
      _state.activeTab.controller.clearMatches();
      _searchFocusNode.requestFocus();
    }
  }

  void _nextMatch() {
    if (_searchMatches.isEmpty) return;
    final next = (_searchMatchIndex + 1) % _searchMatches.length;
    setState(() => _searchMatchIndex = next);
    _jumpToMatch(next);
  }

  void _prevMatch() {
    if (_searchMatches.isEmpty) return;
    final prev =
        (_searchMatchIndex - 1 + _searchMatches.length) % _searchMatches.length;
    setState(() => _searchMatchIndex = prev);
    _jumpToMatch(prev);
  }

  /// Updates the controller's match highlights, scrolls the editor to the
  /// match, then returns focus to the find bar.
  void _jumpToMatch(int index) {
    final controller = _state.activeTab.controller;
    // Paint all match highlights, marking [index] as the current one.
    controller.setMatches(_searchMatches, _searchController.text.length, index);
    // Collapsed selection at the match start — gives EditableText a caret
    // position to scroll to without adding a visible selection box on top of
    // the background-color highlight from buildTextSpan.
    controller.selection = TextSelection.collapsed(
      offset: _searchMatches[index],
    );
    // Briefly focus the editor so it scrolls to the caret, then return focus
    // to the find bar.
    _editorFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchVisible) _searchFocusNode.requestFocus();
    });
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _state.addListener(_onEditorStateChanged);

    // Seed provider selection from persisted state; fall back to 'pi'.
    final persisted = _state.lastProviderKey;
    _selectedProviderKey =
        (persisted != null && _providers.containsKey(persisted))
        ? persisted
        : 'pi';

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
    _searchController.dispose();
    _searchFocusNode.dispose();
    for (final p in _providers.values) {
      p.dispose();
    }
    super.dispose();
  }

  void _onEditorStateChanged() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_searchVisible) {
        // Re-run search against the new tab's content and keep focus in the
        // find bar. _jumpToMatch (called by _onSearchQueryChanged when matches
        // exist) handles the editor→search focus dance for scrolling.
        _onSearchQueryChanged(_searchController.text);
      } else if (!_aiPromptVisible && !_diffVisible) {
        // Restore focus to the editor after every structural change.
        // Mouse clicks on tab chips and buttons clear focus from the TextField
        // (Flutter desktop clears focus on clicks to non-focusable areas).
        // Safe for keyboard shortcuts too: without ValueKey, _editorFocusNode
        // stays attached to the same element the whole time, so calling
        // requestFocus on an already-focused node is a no-op.
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
      _snapshotTabId = _state.activeTab.id;
      _aiPromptVisible = true;
    });

    // Highlight the edit target in the editor so the user can see what will be
    // edited while they type their prompt (and later during streaming/diff).
    // For a collapsed cursor on a non-blank line, pre-expand to the paragraph
    // range — the same expansion _submitAiPrompt applies on submit.
    // Blank-line insert mode has no meaningful range to highlight.
    var highlight = _snapshotSelection;
    if (highlight.isCollapsed) {
      final range = _paragraphRangeAt(_snapshotDocumentText, highlight.start);
      if (range != null) {
        highlight = TextSelection(baseOffset: range.$1, extentOffset: range.$2);
      }
    }
    if (!highlight.isCollapsed) {
      controller.setEditTarget(highlight.start, highlight.end);
    }

    _fetchModelsForActiveProvider();
  }

  // ── Provider switching ───────────────────────────────────────────────────────

  void _onProviderChanged(String key) {
    if (key == _selectedProviderKey) return;
    setState(() {
      _selectedProviderKey = key;
      _selectedProvider = null;
      _selectedModelId = null;
      _thinkingLevel = 'off';
      // Clear models so _fetchModelsForActiveProvider goes through the
      // seeding path (_applyCachedModels) even when a cache entry exists.
      _availableModels = [];
      _modelsLoading = false;
    });
    _fetchModelsForActiveProvider();
  }

  // ── Model fetching ──────────────────────────────────────────────────────────

  /// Fetches models for the active provider if not already cached. Runs async
  /// and updates state when complete. Silent on error (submit still works).
  void _fetchModelsForActiveProvider() {
    final key = _selectedProviderKey;

    // Already cached — apply and seed.
    final cached = _modelCache[key];
    if (cached != null && _availableModels.isNotEmpty) return;
    if (cached != null) {
      _applyCachedModels(key, cached, _fetchResultCache[key]);
      return;
    }

    if (_modelsLoading) return;
    setState(() => _modelsLoading = true);

    _activeProvider
        .fetchModels()
        .then((result) {
          if (!mounted || _selectedProviderKey != key) return;
          _modelCache[key] = result.models;
          _fetchResultCache[key] = result;
          _applyCachedModels(key, result.models, result);
        })
        .catchError((_) {
          if (mounted && _selectedProviderKey == key) {
            setState(() => _modelsLoading = false);
          }
        });
  }

  /// Applies a model list and seeds selection from persisted prefs or provider
  /// suggestions.
  void _applyCachedModels(
    String providerKey,
    List<Map<String, dynamic>> models,
    AiProviderModels? fetchResult,
  ) {
    // Seed model + thinking level from per-provider prefs. Priority:
    //   1. Persisted preference for this provider (if model still exists)
    //   2. Provider's suggested model (e.g. Pi's live state)
    //   3. No selection — provider uses its configured default
    bool modelInList(String? provider, String? id) =>
        provider != null &&
        id != null &&
        models.any((m) => m['id'] == id && m['provider'] == provider);

    final prefs = _state.providerPrefs[providerKey];
    final prefProvider = prefs?['modelProvider'];
    final prefModelId = prefs?['modelId'];
    final prefThinking = prefs?['thinkingLevel'];

    String? seedProvider;
    String? seedModelId;
    if (modelInList(prefProvider, prefModelId)) {
      seedProvider = prefProvider;
      seedModelId = prefModelId;
    } else if (fetchResult != null &&
        modelInList(
          fetchResult.suggestedProvider,
          fetchResult.suggestedModelId,
        )) {
      seedProvider = fetchResult.suggestedProvider;
      seedModelId = fetchResult.suggestedModelId;
    }

    // Thinking level: persisted preference, then provider suggestion.
    final suggestedLevel = fetchResult?.suggestedThinkingLevel ?? 'off';
    final seedLevel = prefThinking != null
        ? _normaliseLevel(prefThinking)
        : _normaliseLevel(suggestedLevel);

    // If no seed was found, fall back to first model in the list so that
    // _selectedProvider/_selectedModelId are always populated when models exist.
    if (seedProvider == null && models.isNotEmpty) {
      seedProvider = models.first['provider'] as String?;
      seedModelId = models.first['id'] as String?;
    }

    setState(() {
      _availableModels = models;
      _modelsLoading = false;
      _thinkingLevel = seedLevel;
      _selectedProvider = seedProvider;
      _selectedModelId = seedModelId;
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

  /// Returns the tab that was active when the AI snapshot was taken.
  /// Falls back to [EditorState.activeTab] if the tab was closed in the
  /// interim (should not happen with the structural-action guards, but
  /// provides a safe fallback).
  EditorTab get _snapshotTab {
    if (_snapshotTabId != null) {
      for (final t in _state.tabs) {
        if (t.id == _snapshotTabId) return t;
      }
    }
    return _state.activeTab;
  }

  void _dismissAiPrompt() {
    _snapshotTab.controller.clearEditTarget();
    _snapshotTabId = null;
    setState(() => _aiPromptVisible = false);
    // _editorFocusNode is permanently attached to the TextField (no ValueKey,
    // no element recreation), so requestFocus() is safe to call synchronously
    // here — no post-frame callback needed, unlike _onEditorStateChanged where
    // focus may have been cleared by a pointer event before the rebuild runs.
    _editorFocusNode.requestFocus();
  }

  Future<void> _submitAiPrompt(String prompt) async {
    // Auto-select paragraph when cursor has no selection.
    if (_snapshotSelection.isCollapsed) {
      final range = _paragraphRangeAt(
        _snapshotDocumentText,
        _snapshotSelection.start,
      );
      if (range != null) {
        _snapshotSelection = TextSelection(
          baseOffset: range.$1,
          extentOffset: range.$2,
        );
      }
    }

    final sel = _snapshotSelection;
    final docText = _snapshotDocumentText;
    final editTarget = sel.isCollapsed ? '' : sel.textInside(docText);

    // Append to history; skip consecutive duplicates; cap at 50.
    if (_promptHistory.isEmpty || _promptHistory.last != prompt) {
      _promptHistory.add(prompt);
      if (_promptHistory.length > 50) _promptHistory.removeAt(0);
    }
    _historyIndex = _promptHistory.length;

    // Persist provider + model + thinking level so the next session starts
    // with the same selection. Written to EditorState fields; the debounced
    // session save picks them up automatically.
    _state.lastProviderKey = _selectedProviderKey;
    final prefs = <String, String>{'thinkingLevel': _thinkingLevel};
    if (_selectedProvider != null) {
      prefs['modelProvider'] = _selectedProvider!;
    }
    if (_selectedModelId != null) {
      prefs['modelId'] = _selectedModelId!;
    }
    _state.providerPrefs[_selectedProviderKey] = prefs;

    setState(() {
      _aiPromptVisible = false;
      _editorReadOnly =
          true; // locked until diff is accepted/rejected/cancelled
      _diffProposed = '';
      _errorBanner = null; // clear any previous error
    });

    bool diffOpened = false;

    try {
      await for (final chunk in _activeProvider.streamEdit(
        documentText: docText,
        editTarget: editTarget,
        userInstruction: prompt,
        modelProvider: _selectedProvider,
        modelId: _selectedModelId,
        thinkingLevel: _thinkingLevel,
        insertOffset: sel.isCollapsed ? sel.start : null,
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

      // If Pi completed without emitting any text_delta chunks, still open the
      // diff so the user can deterministically accept/reject an empty result.
      // Skip this when the user cancelled during loading (_editorReadOnly=false).
      if (!diffOpened && mounted && _editorReadOnly) {
        diffOpened = true;
        setState(() {
          _diffVisible = true;
          _diffEditTarget = editTarget;
          _diffProposed = '';
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _diffFocusNode.requestFocus();
        });
      }

      // Stream completed normally. Surface a non-fatal model-switch warning
      // if Pi rejected set_model / set_thinking_level (prompt still ran).
      final switchErr = _activeProvider.lastWarning;
      if (switchErr != null && mounted) {
        setState(() => _errorBanner = 'Model switch failed: $switchErr');
      }
    } on AiProviderError catch (e) {
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
    _activeProvider.abort();
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
      // Cursor is on a blank line (Phase 3.13 guarantees this for insert mode).
      // docText.substring(0, sel.start) ends with \n (the preceding line's newline).
      // docText.substring(sel.start) starts with \n (the blank line character).
      // Adding \n on each side → \n\n = blank-line separator on both sides.
      final trimmed = result.trim();
      newText =
          '${docText.substring(0, sel.start)}\n$trimmed\n${docText.substring(sel.start)}';
      newCursorPos = sel.start + 1 + trimmed.length;
    } else {
      newText = docText.replaceRange(sel.start, sel.end, result);
      newCursorPos = sel.start + result.length;
    }

    final controller = _snapshotTab.controller;
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );
    controller.clearEditTarget();
    _snapshotTabId = null;

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
    _activeProvider.abort();
    _snapshotTab.controller.clearEditTarget();
    _snapshotTabId = null;
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

  bool _shouldExitOnCloseTab(int index) {
    if (_state.tabs.length != 1) return false;
    final tab = _state.tabs[index];
    return tab.filePath == null && tab.controller.text.isEmpty && !tab.isDirty;
  }

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

      if (_shouldExitOnCloseTab(index)) {
        await ServicesBinding.instance.exitApplication(
          ui.AppExitType.cancelable,
        );
        return;
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
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            OpenSearchIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
            MoveLineUpIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
            MoveLineDownIntent(),
        // Escape cancels the in-flight AI request before the diff opens.
        // Once the diff is visible, this action is gated off by _diffVisible.
        SingleActivator(LogicalKeyboardKey.escape): CancelAiIntent(),
      },
      child: Actions(
        actions: {
          NewTabIntent: CallbackAction<NewTabIntent>(
            onInvoke: (_) => _aiActive ? null : _state.newTab(),
          ),
          CloseTabIntent: CallbackAction<CloseTabIntent>(
            onInvoke: (_) =>
                _aiActive ? null : _handleCloseTab(_state.activeTabIndex),
          ),
          OpenFileIntent: CallbackAction<OpenFileIntent>(
            onInvoke: (_) => _aiActive ? null : _openFile(),
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
          OpenSearchIntent: CallbackAction<OpenSearchIntent>(
            onInvoke: (_) => _openSearch(),
          ),
          MoveLineUpIntent: CallbackAction<MoveLineUpIntent>(
            onInvoke: (_) => _moveLines(-1),
          ),
          MoveLineDownIntent: CallbackAction<MoveLineDownIntent>(
            onInvoke: (_) => _moveLines(1),
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
                onTabTap: (i) {
                  if (!_aiActive) _state.switchTab(i);
                },
                onTabClose: (i) {
                  if (!_aiActive) _handleCloseTab(i);
                },
                onNewTab: () {
                  if (!_aiActive) _state.newTab();
                },
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

              // Find bar — shown between the sub-header area and the editor.
              if (_searchVisible)
                FindBar(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  matchCount: _searchMatches.length,
                  matchIndex: _searchMatchIndex,
                  onQueryChanged: _onSearchQueryChanged,
                  onNext: _nextMatch,
                  onPrev: _prevMatch,
                  onClose: _closeSearch,
                ),

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
                        modelSettings: AiModelSettings(
                          availableModels: _availableModels,
                          loading: _modelsLoading,
                          selectedProvider: _selectedProvider,
                          selectedModelId: _selectedModelId,
                          thinkingLevel: _thinkingLevel,
                          providerKey: _selectedProviderKey,
                          providerNames: {
                            for (final e in _providers.entries)
                              e.key: e.value.name,
                          },
                          supportedThinkingLevels:
                              _selectedProviderKey == 'claude_code'
                              ? const ['low', 'medium', 'high']
                              : const ['off', 'low', 'medium', 'high'],
                        ),
                        onModelChanged: (provider, modelId) => setState(() {
                          _selectedProvider = provider;
                          _selectedModelId = modelId;
                        }),
                        onThinkingLevelChanged: (level) =>
                            setState(() => _thinkingLevel = level),
                        onProviderChanged: _onProviderChanged,
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
