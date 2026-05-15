import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class NewTabIntent extends Intent {
  const NewTabIntent();
}

class CloseTabIntent extends Intent {
  const CloseTabIntent();
}

class SaveIntent extends Intent {
  const SaveIntent();
}

class SaveAsIntent extends Intent {
  const SaveAsIntent();
}

class OpenFileIntent extends Intent {
  const OpenFileIntent();
}

class OpenAiPromptIntent extends Intent {
  const OpenAiPromptIntent();
}

class AcceptDiffIntent extends Intent {
  const AcceptDiffIntent();
}

class RejectDiffIntent extends Intent {
  const RejectDiffIntent();
}

/// Fired by Escape while the AI request is in-flight (before the diff opens).
class CancelAiIntent extends Intent {
  const CancelAiIntent();
}

class OpenSearchIntent extends Intent {
  const OpenSearchIntent();
}

class MoveLineUpIntent extends Intent {
  const MoveLineUpIntent();
}

class MoveLineDownIntent extends Intent {
  const MoveLineDownIntent();
}

/// App-level Ctrl shortcuts blocked while an AI overlay is focused.
/// Add new app-level shortcuts here so prompt/diff interactions stay inert.
const Map<ShortcutActivator, Intent> aiOverlayBlockedShortcuts = {
  SingleActivator(LogicalKeyboardKey.keyN, control: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyW, control: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyO, control: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyS, control: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyK, control: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, control: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.tab, control: true):
      DoNothingAndStopPropagationIntent(),
};
