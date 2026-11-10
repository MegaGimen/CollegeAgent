import 'dart:core';
void main() {
  final raw = '[11, 19-27]';
  final regex = RegExp(r'\[\s*(\d+)\s*(?:,\s*(\d+)(?:\s*[\-,]\s*(\d+))?)?\s*\]');
  final matches = regex.allMatches(raw);
  print('Matches: ${matches.length}');
  for (final m in matches) {
    print(m.group(0));
  }
}
