import 'dart:math';

import 'package:clankpad/models/editor_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _base = TextStyle(fontSize: 14, color: Color(0xFF000000));

Future<BuildContext> _context(
  WidgetTester tester, [
  Brightness brightness = Brightness.light,
]) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    ),
  );
  await tester.pumpAndSettle(); // the theme animates
  return context;
}

HighlightingController _controller(String text) =>
    HighlightingController.fromValue(TextEditingValue(text: text));

/// The effective style of every UTF-16 code unit of [span].
List<TextStyle> _stylesByOffset(TextSpan span) {
  final styles = <TextStyle>[];
  void visit(TextSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    styles.addAll(List.filled(span.text?.length ?? 0, style));
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child as TextSpan, style);
    }
  }

  visit(span, const TextStyle());
  return styles;
}

List<TextStyle> _render(
  BuildContext context,
  HighlightingController controller, {
  bool withComposing = false,
}) => _stylesByOffset(
  controller.buildTextSpan(
    context: context,
    style: _base,
    withComposing: withComposing,
  ),
);

void main() {
  testWidgets('the span text is exactly the controller text', (tester) async {
    final context = await _context(tester);
    for (final text in [
      '# Title\r\n**bold** `code`\r\n',
      '```\ncode\n```\n',
      '😀 **b😀ld** [l😀nk](u) ~~x~~\n> q\n- [x] t\n',
    ]) {
      final controller = _controller(text)
        ..setMatches([2], 3, 0)
        ..setEditTarget(1, text.length - 1);
      var notified = false;
      controller.addListener(() => notified = true);
      final span = controller.buildTextSpan(
        context: context,
        style: _base,
        withComposing: true,
      );
      expect(span.toPlainText(), text);
      expect(notified, isFalse);
      controller.dispose();
    }
  });

  testWidgets('plain text keeps the base style unchanged', (tester) async {
    final context = await _context(tester);
    const text = 'plain text\r\nwith a_b and 2 * 3\n';
    final span = _controller(
      text,
    ).buildTextSpan(context: context, style: _base, withComposing: false);
    expect(span, const TextSpan(style: _base, text: text));
  });

  testWidgets('Find matches keep the Markdown style they cross', (
    tester,
  ) async {
    final context = await _context(tester);
    final scheme = Theme.of(context).colorScheme;
    // Matches: "ld** x" crosses bold text, its delimiter and plain text;
    // "abcdef" is inside a code span.
    const text = '**bold** x `abcdef`';
    final unmatched = _render(context, _controller(text));
    expect(unmatched[5].fontWeight, FontWeight.bold);
    expect(unmatched[6].color, isNot(_base.color)); // dimmed delimiter
    expect(unmatched[12].color, isNot(_base.color)); // code
    expect(unmatched[12].backgroundColor, isNotNull);

    final controller = _controller(text)..setMatches([4, 12], 6, -1);
    final styles = _render(context, controller);
    for (var i = 0; i < text.length; i++) {
      final matched = (i >= 4 && i < 10) || (i >= 12 && i < 18);
      expect(
        styles[i].backgroundColor,
        matched ? scheme.primaryContainer : unmatched[i].backgroundColor,
        reason: '$i',
      );
      expect(
        (styles[i].color, styles[i].fontWeight),
        (unmatched[i].color, unmatched[i].fontWeight),
        reason: '$i',
      );
    }
  });

  testWidgets('dark current-match text keeps readable contrast', (
    tester,
  ) async {
    final context = await _context(tester, Brightness.dark);
    const body = Color(0xFFCCCCCC);
    const text = '> see `code`';
    final controller = _controller(text)..setMatches([0], text.length, 0);
    final styles = _stylesByOffset(
      controller.buildTextSpan(
        context: context,
        style: const TextStyle(fontSize: 14, color: body),
        withComposing: false,
      ),
    );

    double contrast(Color a, Color b) {
      final (l1, l2) = (a.computeLuminance(), b.computeLuminance());
      return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05);
    }

    const delimiters = {0, 6, 11}; // >, `, `
    for (var i = 0; i < text.length; i++) {
      final style = styles[i];
      expect(style.backgroundColor, const Color(0xFF515C6A));
      expect(
        contrast(style.color!, style.backgroundColor!),
        greaterThanOrEqualTo(delimiters.contains(i) ? 3 : 4.2),
        reason: '$i',
      );
      expect(style.color == body, !delimiters.contains(i), reason: '$i');
    }
  });

  testWidgets('the AI edit target spans several styled runs', (tester) async {
    final context = await _context(tester);
    final scheme = Theme.of(context).colorScheme;
    const text = '# H *i* `c`\nplain';
    final controller = _controller(text)..setEditTarget(0, 13);
    final styles = _render(context, controller);

    for (var i = 0; i < 13; i++) {
      expect(styles[i].backgroundColor, scheme.tertiaryContainer);
    }
    expect(styles[13].backgroundColor, isNull);
    expect(styles[2].fontSize, 20);
    expect(styles[5].fontStyle, FontStyle.italic);
    expect(styles[9].color, isNot(styles[2].color)); // code, not heading
    expect(styles[12].fontSize, 14);
  });

  testWidgets('overlapping backgrounds follow their priority', (tester) async {
    final context = await _context(tester);
    final scheme = Theme.of(context).colorScheme;
    // A code span with the edit target inside it, holding one other match
    // (2–4) and the current match (7–9).
    final controller = _controller('`0123456789`')
      ..setEditTarget(1, 11)
      ..setMatches([2, 7], 3, 1);
    final codeBackground = _render(
      context,
      _controller('`x`'),
    )[1].backgroundColor;
    final other = scheme.primaryContainer;
    final current = scheme.primary.withValues(alpha: 0.35);
    final target = scheme.tertiaryContainer;

    expect(
      [for (final style in _render(context, controller)) style.backgroundColor],
      [
        codeBackground,
        target,
        other,
        other,
        other,
        target,
        target,
        current,
        current,
        current,
        target,
        codeBackground,
      ],
    );
  });

  testWidgets('the composing underline combines with strikethrough', (
    tester,
  ) async {
    final context = await _context(tester);
    final controller = HighlightingController.fromValue(
      const TextEditingValue(
        text: '~~abc~~ d',
        composing: TextRange(start: 3, end: 9),
      ),
    );

    final composing = _render(context, controller, withComposing: true);
    expect(
      composing[3].decoration,
      TextDecoration.combine([
        TextDecoration.lineThrough,
        TextDecoration.underline,
      ]),
    );
    expect(composing[2].decoration, TextDecoration.lineThrough);
    expect(composing[8].decoration, TextDecoration.underline);

    final plain = _render(context, controller);
    expect(plain[3].decoration, TextDecoration.lineThrough);
    expect(plain[8].decoration, isNull);
  });

  testWidgets('a theme change restyles unchanged text', (tester) async {
    final controller = _controller('# H');
    final light = _render(await _context(tester), controller)[2].color;
    final dark = _render(
      await _context(tester, Brightness.dark),
      controller,
    )[2].color;
    expect(light, isNot(_base.color));
    expect(dark, isNot(_base.color));
    expect(dark, isNot(light));
  });
}
