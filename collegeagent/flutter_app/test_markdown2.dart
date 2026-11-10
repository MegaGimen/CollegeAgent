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
  final raw = '''[11, 19-27]''';
  final document = md.Document(inlineSyntaxes: [CitationSyntax()]);
  final nodes = document.parseLines([raw]);
  
  void printNode(md.Node node, String indent) {
    if (node is md.Element) {
      print('$indent- Element: <${node.tag}> attrs: ${node.attributes}');
      for (final child in node.children ?? []) {
        printNode(child, indent + '  ');
      }
    }
  }
  
  for (final node in nodes) {
    printNode(node, '');
  }
}
