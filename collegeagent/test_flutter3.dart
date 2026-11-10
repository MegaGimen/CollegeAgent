import 'dart:core';

void main() {
  final raw = '[49, 28-42]';
  final regex = RegExp(r'\[Source:\s*[^\]]+\]|\[\d+(?:\s*,\s*\d+(?:\s*[\-,]\s*\d+)?)?\]|\[\d+(?:[,\-]\s*\d+)*\]');
  for (final m in regex.allMatches(raw)) {
    print('Match: ${m.group(0)}');
  }
}
