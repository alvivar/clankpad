/// Joins hard-wrapped lines into one line per paragraph.
///
/// A paragraph is a maximal run of non-blank lines — matching
/// `_paragraphRangeAt` in editor_screen.dart. A whitespace-only line is blank
/// and separates paragraphs. Blank lines are preserved one-for-one so spacing
/// survives, but are emitted empty: the stray trailing spaces they carry are
/// the terminal artefact this feature exists to remove.
String joinLines(String text) {
  // Normalise line endings. The CRLF pass must run FIRST: the lone-CR pass
  // would otherwise turn each "\r\n" into two newlines, inventing a paragraph
  // break. Lone-CR documents are rare, but never split at all without it.
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
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
  return out.toString();
}
