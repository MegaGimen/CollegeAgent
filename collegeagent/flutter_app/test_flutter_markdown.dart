import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

class CitationSyntax extends md.InlineSyntax {
  CitationSyntax()
      : super(r'\[Source:\s*[^\]]+\]|\[\d+(?:\s*,\s*\d+(?:\s*[\-,]\s*\d+)?)?\]|\[\d+(?:[,\-]\s*\d+)*\]');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element('citation', [md.Text(match.group(0)!)]));
    return true;
  }
}

class CitationBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return const Text('BADGE', key: Key('badge'));
  }
}

void main() {
  testWidgets('Test Citation syntax in markdown', (WidgetTester tester) async {
    const raw = '''- **Berkeley Connect in PHILOS 首次小组合【今天】**:mentor Jennifer Marsh 通知首次小组会就在今天周三,两场可选:5-6pm 在 Dwinelle 262,或 6-7pm 在 Dwinelle 134。Berkeley Connect 是 Pass/Fail 只需考勤;若不能到需提前告知她以免被记缺勤 [11, 19-27]''';
    
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: raw,
            inlineSyntaxes: [CitationSyntax()],
            builders: {
              'citation': CitationBuilder(),
            },
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('badge')), findsOneWidget);
  });
}
