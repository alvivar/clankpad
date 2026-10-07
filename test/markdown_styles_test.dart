import 'package:clankpad/services/markdown_styles.dart';
import 'package:flutter_test/flutter_test.dart';

/// The runs of [text] as 'kind text', ordered by start, longest first.
List<String> _styled(String text) {
  final runs = scanMarkdown(text)
    ..sort(
      (a, b) => a.start != b.start
          ? a.start - b.start
          : a.end != b.end
          ? b.end - a.end
          : a.kind.index - b.kind.index,
    );
  return [
    for (final run in runs)
      '${run.kind.name} ${text.substring(run.start, run.end)}',
  ];
}

void main() {
  test('styles the supported forms', () {
    const cases = {
      '# H1': ['heading1 # H1', 'delimiter #'],
      '###### H6': ['heading6 ###### H6', 'delimiter ######'],
      '# Title **b**': [
        'heading1 # Title **b**',
        'delimiter #',
        'delimiter **',
        'bold b',
        'delimiter **',
      ],
      '**bold** __bold__': [
        'delimiter **',
        'bold bold',
        'delimiter **',
        'delimiter __',
        'bold bold',
        'delimiter __',
      ],
      '*it* _it_': [
        'delimiter *',
        'italic it',
        'delimiter *',
        'delimiter _',
        'italic it',
        'delimiter _',
      ],
      '~~gone~~': ['delimiter ~~', 'strikethrough gone', 'delimiter ~~'],
      '***both***': [
        'delimiter *',
        'italic **both**',
        'delimiter **',
        'bold both',
        'delimiter **',
        'delimiter *',
      ],
      '``a ` b``': ['code ``a ` b``', 'delimiter ``', 'delimiter ``'],
      '[text](http://x)': ['delimiter [', 'link text', 'delimiter ](http://x)'],
      // Images are not supported: the `!` stays plain.
      '![alt](u)': ['delimiter [', 'link alt', 'delimiter ](u)'],
      '> said **x**': [
        'delimiter >',
        'quote  said **x**',
        'delimiter **',
        'bold x',
        'delimiter **',
      ],
      '- item': ['listMarker -'],
      '* item': ['listMarker *'],
      '+ item': ['listMarker +'],
      '1. item': ['listMarker 1.'],
      '10) item': ['listMarker 10)'],
      '  - nested *x*': [
        'listMarker -',
        'delimiter *',
        'italic x',
        'delimiter *',
      ],
      '- [ ] todo': ['listMarker -', 'listMarker [ ]'],
      '- [x] done': ['listMarker -', 'listMarker [x]'],
      // Rules win over list items and emphasis.
      '---': ['delimiter ---'],
      '***': ['delimiter ***'],
      '___': ['delimiter ___'],
      '- - -': ['delimiter - - -'],
      '* * *': ['delimiter * * *'],
    };
    cases.forEach(
      (text, styled) => expect(_styled(text), styled, reason: text),
    );
  });

  test('leaves negatives, unfinished typing and escapes plain', () {
    const plain = [
      '#tag',
      '#',
      '####### seven',
      'a-b',
      '-item',
      '1.5 kg',
      '2 * 3 * 4',
      'a ** b',
      'snake_case_name',
      'path/to_file_name.txt',
      '~one~',
      '**open',
      '_open',
      '`open',
      '[x]',
      '[not a link] (x)',
      '[a](b',
      '--',
      '---x',
      r'\*not\*',
      r'\_x_',
      r'\`a`',
      r'\[a](b)',
    ];
    for (final text in plain) {
      expect(_styled(text), isEmpty, reason: text);
    }

    // An escaped backslash does not escape the delimiter after it.
    expect(_styled(r'\\*a*'), ['delimiter *', 'italic a', 'delimiter *']);
  });

  test('code spans and link destinations hide other inline syntax', () {
    expect(_styled('`a *b* [c](d)` *e*'), [
      'code `a *b* [c](d)`',
      'delimiter `',
      'delimiter `',
      'delimiter *',
      'italic e',
      'delimiter *',
    ]);
    // A backslash inside a code span is literal, as in Windows paths.
    expect(_styled(r'`C:\dir\` *e*'), [
      r'code `C:\dir\`',
      'delimiter `',
      'delimiter `',
      'delimiter *',
      'italic e',
      'delimiter *',
    ]);
    expect(_styled('[a](*x*)'), ['delimiter [', 'link a', 'delimiter ](*x*)']);
    // A line holding only ```code``` is a code span, not a fence.
    expect(_styled('```code```\n*e*'), [
      'code ```code```',
      'delimiter ```',
      'delimiter ```',
      'delimiter *',
      'italic e',
      'delimiter *',
    ]);
  });

  test('inline syntax does not span lines', () {
    expect(_styled('**a\nb**'), isEmpty);
    expect(_styled('`a\nb`'), isEmpty);
  });

  test('fenced code is styled before inline syntax, across lines', () {
    for (final newline in ['\n', '\r\n']) {
      String lines(List<String> lines) => lines.join(newline);

      // Closed fence with an info string; the trailing newline stays plain.
      expect(_styled(lines(['```dart', '# not *x*', '```', '*y*', ''])), [
        'code ${lines(['```dart', '# not *x*', '```'])}',
        'delimiter ```dart',
        'delimiter ```',
        'delimiter *',
        'italic y',
        'delimiter *',
      ], reason: newline);
      // A longer closing fence closes; a tilde fence ignores backticks.
      expect(_styled(lines(['  ~~~', '```', '  ~~~~ ', 'z'])), [
        'code ${lines(['~~~', '```', '  ~~~~ '])}',
        'delimiter ~~~',
        'delimiter ~~~~ ',
      ], reason: newline);
      // A shorter fence or one with text after it does not close; an
      // unclosed fence runs to the end of the text.
      for (final closer in ['```', '```` x']) {
        final text = lines(['````', closer, '*y*']);
        expect(_styled(text), [
          'code $text',
          'delimiter ````',
        ], reason: '$closer $newline');
      }
    }
  });

  test('offsets are UTF-16 code units', () {
    expect(
      scanMarkdown('😀 **b**'),
      contains((start: 5, end: 6, kind: MarkdownKind.bold)),
    );
  });
}
