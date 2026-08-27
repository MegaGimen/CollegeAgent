import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:collegeagent_chat/models/message.dart';
import 'package:collegeagent_chat/widgets/citation_badge.dart';
import 'package:collegeagent_chat/widgets/message_bubble.dart';

class CitationSyntax extends md.InlineSyntax {
  int _counter = 0;

  CitationSyntax()
      : super(r'\[Source:\s*[^\]]+\]|\[\d+(?:\s*,\s*\d+(?:\s*[\-,]\s*\d+)?)?\]|\[\d+(?:[,\-]\s*\d+)*\]');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    _counter++;
    final raw = match.group(0)!;
    final el = md.Element('citation', [md.Text(raw)]);
    el.attributes['raw'] = raw;
    el.attributes['matchIdx'] = '$_counter';
    parser.addNode(el);
    return true;
  }
}

class CitationBuilder extends MarkdownElementBuilder {
  final List<Citation> citations;
  final void Function(Citation citation) onCitationTap;

  CitationBuilder({
    required this.citations,
    required this.onCitationTap,
  });

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final raw = element.attributes['raw'] ?? element.textContent;
    final matchIdx = int.tryParse(element.attributes['matchIdx'] ?? '') ?? 0;

    Citation? citation;
    try {
      citation = citations.firstWhere((c) => c.index == matchIdx);
    } catch (_) {}

    int? parsedSourceId;
    final numMatch = RegExp(r'\[(\d+)').firstMatch(raw);
    if (numMatch != null) {
      parsedSourceId = int.tryParse(numMatch.group(1)!);
    }

    if (citation == null && parsedSourceId != null) {
      try {
        citation = citations.firstWhere((c) => c.index == parsedSourceId);
      } catch (_) {}
    }

    citation ??= Citation(
      index: matchIdx > 0 ? matchIdx : (parsedSourceId ?? 1),
      title: parsedSourceId != null ? 'Source $parsedSourceId' : raw,
    );

    String label;
    if (raw.startsWith('[Source:')) {
      label = '[${citation.index}]';
    } else {
      label = raw.replaceAllMapped(
        RegExp(r'\[\s*(\d+)\s*(?:,\s*(\d+)(?:\s*[\-,]\s*(\d+))?)?\s*\]'),
        (m) {
          final id = m.group(1)!;
          if (m.group(2) != null) {
            final start = m.group(2)!;
            final end = m.group(3) != null ? '-${m.group(3)!}' : '';
            return '[$id, $start$end]';
          }
          return '[$id]';
        },
      );
      if (!label.startsWith('[')) label = '[$label]';
    }

    final targetCitation = citation;

    return Text.rich(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2.0),
          child: GestureDetector(
            onTap: () => onCitationTap(targetCitation),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF6C63FF).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: const Color(0xFF6C63FF).withValues(alpha: 0.35),
                  width: 0.8,
                ),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6C63FF),
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('Comprehensive inline citation test', (WidgetTester tester) async {
    final citations = [
      Citation(index: 1, title: 'Orientation Guide', snippet: 'Header excerpt'),
      Citation(index: 2, title: 'Orientation Guide', snippet: 'Guide excerpt 10-15'),
      Citation(index: 3, title: 'Course Syllabus', snippet: 'Syllabus excerpt 45-60'),
      Citation(index: 4, title: 'Campus Health Policy', snippet: 'Health form excerpt'),
      Citation(index: 5, title: 'Orientation Guide', snippet: 'Multiref 1'),
      Citation(index: 6, title: 'Course Syllabus', snippet: 'Multiref 2'),
    ];

    Citation? lastTapped;

    final markdownText = '''
# 伯克利入学指南[1]

根据官方说明[1, 10-15]，所有学生需按时到达。

主要要求如下：
- 完成在线测试[2, 45-60]
- 提交健康表单[3]

多重引用测试：相关规定见[1][2]。
''';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: MarkdownBody(
              data: markdownText,
              inlineSyntaxes: [CitationSyntax()],
              builders: {
                'citation': CitationBuilder(
                  citations: citations,
                  onCitationTap: (c) => lastTapped = c,
                ),
              },
            ),
          ),
        ),
      ),
    );

    // Verify all badges rendered inline
    expect(find.text('[1]'), findsNWidgets(2)); // in header and multiref
    expect(find.text('[1, 10-15]'), findsOneWidget);
    expect(find.text('[2, 45-60]'), findsOneWidget);
    expect(find.text('[3]'), findsOneWidget);
    expect(find.text('[2]'), findsOneWidget); // in multiref

    // Test tap on [2, 45-60] (occurrence 3)
    await tester.tap(find.text('[2, 45-60]'));
    expect(lastTapped?.index, 3);
    expect(lastTapped?.title, 'Course Syllabus');
    expect(lastTapped?.snippet, 'Syllabus excerpt 45-60');
  });

  testWidgets('MessageBubble renders citations inline', (WidgetTester tester) async {
    final message = MessageModel(
      id: 'msg-1',
      sessionId: 'sess-1',
      role: 'assistant',
      text: '根据选课指南[1, 15-20]，每学期最少修12学分[2]。',
      timestamp: DateTime.now().toUtc().toIso8601String(),
      citations: [
        Citation(index: 1, title: 'Enrollment Guide', snippet: 'Min 12 credits'),
        Citation(index: 2, title: 'Academic Regulations', snippet: 'Semester requirements'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: message),
        ),
      ),
    );

    expect(find.text('[1, 15-20]'), findsOneWidget);
    expect(find.text('[2]'), findsOneWidget);

    // Tap citation badge to open bottom sheet
    await tester.tap(find.text('[1, 15-20]'));
    await tester.pumpAndSettle();

    expect(find.text('Enrollment Guide'), findsOneWidget);
    expect(find.text('Min 12 credits'), findsOneWidget);
  });
}





