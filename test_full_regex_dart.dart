import 'dart:io';

void main() {
  final text = File('full_ai_text.txt').readAsStringSync();
  final regex = RegExp(r'\[Source:\s*[^\]]+\]|\[\d+(?:\s*,\s*\d+(?:\s*[\-,]\s*\d+)?)?\]|\[\d+(?:[,\-]\s*\d+)*\]');
  final matches = regex.allMatches(text);
  print('Total matches: ${matches.length}');
  int count = 0;
  for (final m in matches) {
    count++;
    print('Index $count: matched "${m.group(0)}"');
  }
}
