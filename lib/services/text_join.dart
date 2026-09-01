/// Joins hard-wrapped lines into one line per paragraph, preserving CRLF
/// line endings.
///
/// A paragraph is a maximal run of non-blank lines — matching
/// `_paragraphRangeAt` in editor_screen.dart. A whitespace-only line is blank
/// and separates paragraphs. Blank lines are preserved one-for-one so spacing
/// survives, but are emitted empty: the stray trailing spaces they carry are
/// the terminal artefact this feature exists to remove.
String joinLines(String text) {
  // One pass over every line-ending convention: `\r\n?` is greedy, so CRLF is
  // consumed whole rather than leaving a stray \n behind.
  final lines = text.split(RegExp(r'\r\n?|\n'));
  final out = StringBuffer();
  var inParagraph = false;

  for (final (i, line) in lines.indexed) {
    final content = line.trim();
    // Every line but the first gets a separator: a space continues the current
    // paragraph, a newline starts or ends one.
    if (i > 0) out.write(inParagraph && content.isNotEmpty ? ' ' : '\n');
    if (content.isEmpty) {
      inParagraph = false;
      continue;
    }
    // A paragraph's first line keeps its indentation; continuations go flush.
    if (!inParagraph) {
      out.write(line.substring(0, line.length - line.trimLeft().length));
      inParagraph = true;
    }
    out.write(content);
  }
  final joined = out.toString();
  // Restore CRLF if the input used it, so joining a Windows file neither
  // rewrites its endings nor defeats the caller's no-op comparison.
  return text.contains('\r\n') ? joined.replaceAll('\n', '\r\n') : joined;
}
