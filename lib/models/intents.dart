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

/// Fired by Escape when no focused widget handles it: cancels a loading AI
/// request, or else closes the AI prompt and the Find bar. Does nothing while
/// the diff is visible.
class EscapeIntent extends Intent {
  const EscapeIntent();
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

class JoinLinesIntent extends Intent {
  const JoinLinesIntent();
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
  SingleActivator(LogicalKeyboardKey.keyJ, control: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.tab, control: true):
      DoNothingAndStopPropagationIntent(),
};
