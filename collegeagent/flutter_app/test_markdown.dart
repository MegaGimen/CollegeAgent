import 'package:markdown/markdown.dart' as md;
import 'dart:core';

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

void main() {
  final raw = '''- **Berkeley Connect in PHILOS 首次小组合【今天】**:mentor Jennifer Marsh 通知首次小组会就在今天周三,两场可选:5-6pm 在 Dwinelle 262,或 6-7pm 在 Dwinelle 134。Berkeley Connect 是 Pass/Fail 只需考勤;若不能到需提前告知她以免被记缺勤 [11, 19-27]''';
  final document = md.Document(inlineSyntaxes: [CitationSyntax()]);
  final nodes = document.parseLines([raw]);
  
  // print the AST
  void printNode(md.Node node, String indent) {
    if (node is md.Text) {
      print('$indent- Text: "${node.text}"');
    } else if (node is md.Element) {
      print('$indent- Element: <${node.tag}>');
      for (final child in node.children ?? []) {
        printNode(child, indent + '  ');
      }
    }
  }
  
  for (final node in nodes) {
    printNode(node, '');
  }
}
