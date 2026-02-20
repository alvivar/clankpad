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
