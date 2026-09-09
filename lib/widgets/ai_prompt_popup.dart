import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/intents.dart';
import '../services/ai_provider.dart';

const _thinkingLevels = ['off', 'low', 'medium', 'high'];

/// Snapshot of model/thinking state passed from EditorScreen to the popup.
/// Kept as a data class so the popup receives a single param instead of many.
class AiModelSettings {
  final List<AiModel> availableModels;
  final bool loading;
  final String? selectedProvider;
  final String? selectedModelId;
  final String thinkingLevel;

  const AiModelSettings({
    required this.availableModels,
    required this.loading,
    required this.selectedProvider,
    required this.selectedModelId,
    required this.thinkingLevel,
  });
}

class AiPromptPopup extends StatefulWidget {
  final VoidCallback onDismiss;
  final ValueChanged<String> onSubmit;

  /// Called when the user presses Up on the first line of the prompt field.
  /// Receives the current field text; returns the text to show, or null to
  /// let the TextField handle the key normally.
  final String? Function(String currentText)? onHistoryUp;

  /// Called when the user presses Down on the last line of the prompt field.
  /// Receives the current field text; returns the text to show, or null to
  /// let the TextField handle the key normally.
  final String? Function(String currentText)? onHistoryDown;

  /// Current model/thinking state shown in the footer toolbar.
  final AiModelSettings modelSettings;

  /// Called when the user picks a different model.
  final void Function(String provider, String modelId) onModelChanged;

  /// Called when the user picks a different thinking level.
  final void Function(String level) onThinkingLevelChanged;

  const AiPromptPopup({
    super.key,
    required this.onDismiss,
    required this.onSubmit,
    this.onHistoryUp,
    this.onHistoryDown,
    required this.modelSettings,
    required this.onModelChanged,
    required this.onThinkingLevelChanged,
  });

  @override
  State<AiPromptPopup> createState() => _AiPromptPopupState();
}

class _AiPromptPopupState extends State<AiPromptPopup> {
  final _promptController = TextEditingController();
  final _textFieldFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFieldFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _promptController.dispose();
    _textFieldFocusNode.dispose();
    super.dispose();
  }

  // ── Cursor-position helpers ──────────────────────────────────────────────────

  bool _isOnFirstLine() {
    final offset = _promptController.selection.baseOffset;
    if (offset < 0) return false;
    return !_promptController.text.substring(0, offset).contains('\n');
  }

  bool _isOnLastLine() {
    final offset = _promptController.selection.baseOffset;
    if (offset < 0) return false;
    return !_promptController.text.substring(offset).contains('\n');
  }

  // ── Submit ───────────────────────────────────────────────────────────────────

  void _submit() {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      widget.onDismiss();
      return;
    }
    widget.onSubmit(prompt);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final settings = widget.modelSettings;
    final effectiveModel = _effectiveModelForUi(settings);
    final modelSupportsThinking = effectiveModel?.supportsReasoning ?? false;

    return Shortcuts(
      shortcuts: aiOverlayBlockedShortcuts,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(8),
              color: colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Prompt field ────────────────────────────────────────
                    Focus(
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent || event is KeyRepeatEvent) {
                          if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                              _isOnFirstLine()) {
                            final text = widget.onHistoryUp?.call(
                              _promptController.text,
                            );
                            if (text != null) {
                              _promptController.value = TextEditingValue(
                                text: text,
                                selection: TextSelection.collapsed(
                                  offset: text.length,
                                ),
                              );
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          }

                          if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowDown &&
                              _isOnLastLine()) {
                            final text = widget.onHistoryDown?.call(
                              _promptController.text,
                            );
                            if (text != null) {
                              _promptController.value = TextEditingValue(
                                text: text,
                                selection: TextSelection.collapsed(
                                  offset: text.length,
                                ),
                              );
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          }
                        }

                        if (event is! KeyDownEvent) {
                          return KeyEventResult.ignored;
                        }

                        // Ctrl+P — cycle model forward.
                        if (event.logicalKey == LogicalKeyboardKey.keyP &&
                            HardwareKeyboard.instance.isControlPressed) {
                          final models = settings.availableModels;
                          if (models.isNotEmpty) {
                            final current = _effectiveModelForUi(settings);
                            final cur = current == null
                                ? -1
                                : models.indexOf(current);
                            final next = (cur + 1) % models.length;
                            final m = models[next];
                            widget.onModelChanged(m.provider, m.id);
                          }
                          return KeyEventResult.handled;
                        }

                        // Shift+Tab — cycle thinking level forward (only when
                        // the effective model supports thinking).
                        if (event.logicalKey == LogicalKeyboardKey.tab &&
                            HardwareKeyboard.instance.isShiftPressed &&
                            modelSupportsThinking) {
                          const levels = _thinkingLevels;
                          final cur = levels.indexOf(settings.thinkingLevel);
                          final next = (cur + 1) % levels.length;
                          widget.onThinkingLevelChanged(levels[next]);
                          return KeyEventResult.handled;
                        }

                        if (event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          _submit();
                          return KeyEventResult.handled;
                        }

                        if (event.logicalKey == LogicalKeyboardKey.escape) {
                          widget.onDismiss();
                          return KeyEventResult.handled;
                        }

                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _promptController,
                        focusNode: _textFieldFocusNode,
                        maxLines: null,
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onSurface,
                        ),
                        decoration: InputDecoration(
                          hintText:
                              'Edit instruction… (Enter to submit, Shift+Enter for newline, Esc to dismiss)',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        cursorWidth: 1.5,
                      ),
                    ),

                    // ── Model / thinking footer ───────────────────────────────
                    const Divider(height: 1),
                    SizedBox(
                      height: 32,
                      child: Row(
                        children: [
                          _ModelPicker(
                            settings: settings,
                            onChanged: widget.onModelChanged,
                            onFocusBack: _textFieldFocusNode.requestFocus,
                          ),
                          const Spacer(),
                          if (modelSupportsThinking)
                            _ThinkingPicker(
                              level: settings.thinkingLevel,
                              levels: _thinkingLevels,
                              onChanged: widget.onThinkingLevelChanged,
                              onFocusBack: _textFieldFocusNode.requestFocus,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Private widgets ───────────────────────────────────────────────────────────

AiModel? _effectiveModelForUi(AiModelSettings settings) {
  if (settings.availableModels.isEmpty) return null;

  // No explicit selection yet: mirror the dropdown's visible fallback.
  if (settings.selectedProvider == null || settings.selectedModelId == null) {
    return settings.availableModels.first;
  }

  for (final m in settings.availableModels) {
    if (m.provider == settings.selectedProvider &&
        m.id == settings.selectedModelId) {
      return m;
    }
  }

  // If selected model is missing from the filtered list, fall back to first.
  return settings.availableModels.first;
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({
    required this.settings,
    required this.onChanged,
    this.onFocusBack,
  });

  final AiModelSettings settings;
  final void Function(String provider, String modelId) onChanged;
  final VoidCallback? onFocusBack;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (settings.loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '···',
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    if (settings.availableModels.isEmpty) return const SizedBox.shrink();

    // Keep dropdown selection aligned with the same effective model logic used
    // by the footer and keyboard shortcuts. AiModel == compares on (provider,
    // id) so the value matches across rebuilds even with fresh instances.
    final currentModel = _effectiveModelForUi(settings)!;

    return DropdownButton<AiModel>(
      value: currentModel,
      isDense: true,
      underline: const SizedBox.shrink(),
      style: TextStyle(fontSize: 12, color: colorScheme.onSurface),
      items: settings.availableModels.map((m) {
        return DropdownMenuItem<AiModel>(
          value: m,
          child: Text('${m.provider}  ·  ${m.name}'),
        );
      }).toList(),
      onChanged: (m) {
        if (m == null) return;
        onChanged(m.provider, m.id);
        onFocusBack?.call();
      },
    );
  }
}

class _ThinkingPicker extends StatelessWidget {
  const _ThinkingPicker({
    required this.level,
    required this.levels,
    required this.onChanged,
    this.onFocusBack,
  });

  final String level;
  final List<String> levels;
  final void Function(String level) onChanged;
  final VoidCallback? onFocusBack;

  static const _labels = {
    'off': 'Thinking off',
    'low': 'Low thinking',
    'medium': 'Medium thinking',
    'high': 'High thinking',
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // If the current level isn't in the supported list, clamp to first.
    final effectiveLevel = levels.contains(level) ? level : levels.first;
    return DropdownButton<String>(
      value: effectiveLevel,
      isDense: true,
      underline: const SizedBox.shrink(),
      style: TextStyle(fontSize: 12, color: colorScheme.onSurface),
      items: levels.map((l) {
        return DropdownMenuItem<String>(value: l, child: Text(_labels[l] ?? l));
      }).toList(),
      onChanged: (v) {
        onChanged(v ?? effectiveLevel);
        onFocusBack?.call();
      },
    );
  }
}
